#!/bin/bash
# A fresh regtest chain on this Linux host, and chainctl serving it to one Windows machine.
#   CHAIN=<regtest-chain> HOST=<this address> CLIENT=<Windows address> chain-host/start.sh
# CHAIN: `nix build <logos-bitcoin-wallet-core-module>#regtest-chain`, from 15ed97e on (LISTEN).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/chain.env"
CHAIN="$(readlink -f "${CHAIN:?CHAIN: the regtest-chain wrapper}")/bin/regtest-chain"
CTL_DIR="${CTL_DIR:-$HOME/btc-win-chainctl}"; mkdir -p "$CTL_DIR"
[ -f "$CTL_DIR/chainctl.pid" ] && { echo "chainctl already runs (pid $(cat "$CTL_DIR/chainctl.pid")); stop.sh first" >&2; exit 1; }
"$CHAIN" stop > /dev/null 2>&1 || true
rm -rf "$CHAIN_DIR"
"$CHAIN" prepare
"$CHAIN" electrum; "$CHAIN" peers
setsid nohup python3 "$HERE/chainctl.py" --chain "$CHAIN" --listen "$HOST:${CTL_PORT:-28600}" --client "${CLIENT:?CLIENT: the Windows address}" \
  > "$CTL_DIR/chainctl.log" 2>&1 < /dev/null &
echo $! > "$CTL_DIR/chainctl.pid"
echo "chainctl on $HOST:${CTL_PORT:-28600} for $CLIENT (pid $(cat "$CTL_DIR/chainctl.pid"))"
