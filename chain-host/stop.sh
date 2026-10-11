#!/bin/bash
# Stops the chain and chainctl, each by its PID file.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/chain.env"
CTL_DIR="${CTL_DIR:-$HOME/btc-win-chainctl}"
[ -n "${CHAIN:-}" ] && "$(readlink -f "$CHAIN")/bin/regtest-chain" stop
if [ -f "$CTL_DIR/chainctl.pid" ]; then
  pid=$(cat "$CTL_DIR/chainctl.pid")
  kill "$pid" 2>/dev/null && echo "stopped chainctl $pid"
  rm -f "$CTL_DIR/chainctl.pid"
fi
