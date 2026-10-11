#!/usr/bin/env python3
"""The regtest chain's remote control, for a wallet on another machine of the LAN.

Runs on the Linux host that runs the wallet core's tools/regtest/chain.sh (its `regtest-chain`
wrapper). A Windows machine has no bitcoind or electrs of its own, and the Windows harness and
drive.py run inside one session there, so they ask this service to mine, fund, reorg, stop and
start electrs. It answers one client address only and runs the chain script with an argument
list, never a shell.

  chainctl.py --chain <regtest-chain> --listen <this host's LAN address>:28600 --client <Windows address>

The chain's settings come from the environment, as chain.sh reads them (CHAIN_DIR, the ports,
LISTEN, HOST, WHITELIST). POST, JSON in and out:
  /run {"args": [...]}  chain.sh <args>          -> {code, stdout, stderr}
  /fresh                stop, wipe CHAIN_DIR, prepare
  /electrs-stop         both electrs, by their PID files
  /electrs-start        both electrs again, with chain.sh's flags
"""
import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SUBCOMMANDS = {"start", "prepare", "mine", "fund", "reorg", "rpc", "electrum", "peers", "stop",
               "pruned", "prune", "pruned-rpc", "esplora"}


def env_int(name, default):
    return int(os.environ.get(name, default))


class Chain:
    def __init__(self, script):
        self.script = script
        self.dir = os.environ.get("CHAIN_DIR", os.path.join(os.getcwd(), "chain"))
        self.ports = [int(p) for p in os.environ.get("ELECTRUM_PORTS", "60601,60611").split(",")]
        self.listen = os.environ.get("LISTEN", "127.0.0.1")

    def run(self, args, timeout=600):
        r = subprocess.run([self.script, *args], capture_output=True, text=True, timeout=timeout)
        return {"code": r.returncode, "stdout": r.stdout, "stderr": r.stderr}

    def fresh(self):
        self.run(["stop"])
        shutil.rmtree(self.dir, ignore_errors=True)
        return self.run(["prepare"])

    # The wrapper sets ELECTRS to a store path unless the environment names one.
    def electrs(self):
        if os.environ.get("ELECTRS"):
            return os.environ["ELECTRS"]
        with open(os.path.realpath(self.script)) as f:
            m = re.search(r"ELECTRS=\$\{ELECTRS-'([^']+)'\}", f.read())
        if not m:
            raise RuntimeError("no ELECTRS in %s" % self.script)
        return m.group(1)

    def listening(self, port):
        with socket.socket() as s:
            s.settimeout(0.5)
            return s.connect_ex(("127.0.0.1", port)) == 0

    def electrs_stop(self):
        stopped = []
        for i in range(len(self.ports)):
            f = os.path.join(self.dir, "electrs%d.pid" % i)
            if not os.path.exists(f):
                continue
            pid = int(open(f).read().strip())
            try:
                os.kill(pid, signal.SIGTERM)
                for _ in range(300):
                    os.kill(pid, 0)
                    time.sleep(0.1)
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.remove(f)
            stopped.append(pid)
        still = [p for p in self.ports if self.listening(p)]
        return {"code": 1 if still else 0, "stdout": "stopped electrs %s" % stopped,
                "stderr": "still listening on %s" % still if still else ""}

    # chain.sh's start_electrs, which the script runs only together with bitcoind.
    def electrs_start(self):
        if all(self.listening(p) for p in self.ports):
            return {"code": 0, "stdout": "electrs already listening on %s" % self.ports, "stderr": ""}
        data = os.path.join(self.dir, "bitcoind")
        rpc_port, p2p_port = env_int("RPC_PORT", 18543), env_int("P2P_PORT", 18544)
        for i, port in enumerate(self.ports):
            log = open(os.path.join(self.dir, "electrs%d.log" % i), "ab")
            p = subprocess.Popen(
                [self.electrs(), "--skip-default-conf-files", "--network", "regtest",
                 "--db-dir", os.path.join(self.dir, "electrs%d" % i), "--daemon-dir", data,
                 "--cookie-file", os.path.join(data, "regtest", ".cookie"),
                 "--daemon-rpc-addr", "127.0.0.1:%d" % rpc_port, "--daemon-p2p-addr", "127.0.0.1:%d" % p2p_port,
                 "--electrum-rpc-addr", "%s:%d" % (self.listen, port), "--monitoring-addr", "127.0.0.1:%d" % (port + 1),
                 "--wait-duration-secs", "1"],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            with open(os.path.join(self.dir, "electrs%d.pid" % i), "w") as f:
                f.write(str(p.pid))
        end = time.time() + 60
        while not all(self.listening(p) for p in self.ports):
            if time.time() > end:
                return {"code": 1, "stdout": "", "stderr": "electrs did not come back"}
            time.sleep(0.2)
        return {"code": 0, "stdout": "electrs listening on %s" % self.ports, "stderr": ""}


def serve(chain, listen, client):
    class Handler(BaseHTTPRequestHandler):
        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.client_address[0] != client:
                return self.reply(403, {"error": "not the client this service answers"})
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                if self.path == "/run":
                    args = body.get("args")
                    if not (isinstance(args, list) and args and all(isinstance(a, str) for a in args)
                            and args[0] in SUBCOMMANDS):
                        return self.reply(400, {"error": "args: a chain.sh subcommand and its arguments"})
                    return self.reply(200, chain.run(args))
                handler = {"/fresh": chain.fresh, "/electrs-stop": chain.electrs_stop,
                           "/electrs-start": chain.electrs_start}.get(self.path)
                if handler is None:
                    return self.reply(404, {"error": "unknown path"})
                return self.reply(200, handler())
            except Exception as e:  # The client reads the reason; the service keeps running.
                return self.reply(500, {"error": str(e)})

        def log_message(self, fmt, *args):
            print("%s %s" % (time.strftime("%H:%M:%S"), fmt % args), flush=True)

    host, port = listen.rsplit(":", 1)
    HTTPServer((host, int(port)), Handler).serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--chain", required=True, help="the regtest-chain wrapper or chain.sh")
    ap.add_argument("--listen", required=True, help="address:port to serve on")
    ap.add_argument("--client", required=True, help="the only address answered")
    a = ap.parse_args()
    serve(Chain(a.chain), a.listen, a.client)


if __name__ == "__main__":
    main()
