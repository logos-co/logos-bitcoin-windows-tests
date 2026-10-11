# logos-bitcoin-windows-tests

The Bitcoin wallet's Windows runs, reproducible: the wallet modules on a Windows machine under
the Windows `logosctl` bundle, the regtest chain on a Linux machine of the same LAN. No binaries
live here; every program is built with nix on the Linux machine and copied over.

```
chain-host/   on the Linux machine: chain.env, start.sh / stop.sh, chainctl.py (the chain's remote control)
winvm/        on the Windows machine, in its work dir (below): lib.ps1 and the run-*.ps1 scripts
mac/          on the machine that drives both over ssh: winrun.sh, stage.sh
```

## Why a remote control

Windows has no bitcoind or electrs of ours, and a daemon `logosctl` starts inside an ssh
session ends with it, so one run is one ssh session on Windows. The chain stays on Linux: its P2P
and Electrum ports listen on the LAN (`chain.sh`'s `LISTEN`, `HOST`, `WHITELIST`, from the wallet
core's 15ed97e), and `chainctl.py` answers the Windows machine only, running `chain.sh`
subcommands (`mine`, `fund`, `rpc`, `reorg`, ...), a fresh chain, and electrs stopped and started.
The wallet reaches the servers and peers directly, under its LAN rule.

## Layout on Windows

```
%USERPROFILE%\bw\           the work dir, unless BTC_WIN_DIR names another
  ctl\                      logos-logoscore-cli's packages.x86_64-windows.ctl-bundle-dir (portable)
  mods\<name>\modules|plugins\   each module's packages.x86_64-windows.install-portable
  tools\                    the wallet core's packages.x86_64-windows.test-bin (storage.exe, p2p_proxy.exe)
  lib.ps1, run-*.ps1, torrc
  results-<run>.txt, <run>\session, <run>\home   written by each run
```

`mac/stage.sh` copies a nix result from the Linux machine into `mods\<name>` (or another dir);
`mac/winrun.sh <script> [args]` runs one script in one ssh session. The machine's execution policy
refuses `.ps1` files, so `winrun.sh` and the scripts load each other as script blocks.

## The runs

| Script | What it runs |
|---|---|
| `run-flow.ps1 [-Authority electrum\|kyoto] [-Race]` | keystore side, wallet core: open (evm_keystore_cli), receive, send (evm_signer_cli), a fee bump, close, reopen |
| `run-spike3.ps1 [-Runs 20]` | spike 3: unloads while Kyoto syncs headers, downloads filters, idles (p2p_proxy.exe slows the peers) |
| `run-node.ps1 [-Runs 20]` | bitcoind_module: regtest -> signet (Tor) -> regtest in one host, unloads at the tip |
| `run-localnode.ps1` | the wallet core with bitcoind_module as its authority |
| `run-nodemod.ps1` | bitcoin_node_module: defaults, peer list, routes, a LAN server probed |
| `run-backend.ps1` | backend and CLI: open, a CLI send, unknown then rebroadcast, abandoned, a backend restart mid-send |
| `e2e-run.sh <spec>` (Git Bash) | the wallet app's full-Basecamp e2e, one spec's emitted Windows script (below) |

Spike 4 is the wallet core's `storage.exe --ignored --nocapture` from `tools\`.

## A run, end to end

```bash
# Linux machine: build the chain wrapper and start the chain with its remote control
nix build <logos-bitcoin-wallet-core-module>#regtest-chain -o ~/btc-win-out/regtest-chain
CHAIN=~/btc-win-out/regtest-chain HOST=192.0.2.10 CLIENT=192.0.2.20 chain-host/start.sh
# this machine: copy the builds and the scripts over, then run
mac/stage.sh ctl-bundle-dir ctl
mac/stage.sh core-install-portable mods/core     # and so on per module
scp winvm/*.ps1 winvm/torrc winvm:bw/
mac/winrun.sh run-flow.ps1 -Authority kyoto
ssh winvm 'type bw\results-flow-kyoto.txt'
# Linux machine, at the end
CHAIN=~/btc-win-out/regtest-chain HOST=192.0.2.10 chain-host/stop.sh
```

## The full-Basecamp e2e

The test lives with the wallet app (logos-bitcoin-wallet-ui, `doctests/basecamp-e2e*.test.yaml`
driven by `doctests/e2e/drive.py`); on Windows it takes the same chain through `E2E_CHAIN_URL`.
Under the work dir's `e2e\`:

```
repo\doctests\        the wallet app's doctests (drive.py)
work\e2e\build\<name>  the Windows builds the spec's Linux/macOS step builds with nix:
                      basecamp (bin-bundle-dir-inspector), keystore, manager, keys, signer,
                      backend, core, node, wallet (install-portable), and for the local-node
                      spec bitcoind and bitcoindui
<spec>.sh             doctest emit-smoke <spec>.test.yaml --platform windows -o <spec>.sh
```

`bash e2e-run.sh basecamp-e2e` (or `basecamp-e2e-kyoto`, `basecamp-e2e-node`) runs one script as
logos-windows-ci's native leg would, from a clean user dir, and prints the driver's PASS and
PHASE lines; `<spec>.log` and `<spec>.execs.json` hold the rest. It needs Git Bash, node and a
native Windows Python as `python3` (the Store's is a stub; `ui\shim\python3` points at MSYS2's).
