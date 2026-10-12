#!/bin/bash
# The full-Basecamp e2e's Windows leg (logos-bitcoin-wallet-ui's doctests): one spec's script from
# `doctest emit-smoke --platform windows`, run as logos-windows-ci's native leg runs it, under Git
# Bash, with the chain on the chain host behind chainctl.
#   bash e2e-run.sh basecamp-e2e | basecamp-e2e-kyoto | basecamp-e2e-node
# Layout under <work dir>\e2e: repo\ (the app's repo; drive.py), work\e2e\build\<name>
# (the staged Windows builds drive.py lays out), <spec>.sh (the emitted script).
set -u
spec="${1:?which spec}"
# The work dir: BTC_WIN_DIR, else %USERPROFILE%\bw, as lib.ps1 reads it.
BW="$(cygpath -u "${BTC_WIN_DIR:-$USERPROFILE\\bw}")"
W="$BW/e2e/work"
export E2E_REPO="$BW/e2e/repo" E2E_WORK="$W"
# The chain host's chainctl: E2E_CHAIN_URL, else bw/chainctl.url; the wallet dials the URL's host.
E2E_CHAIN_URL="${E2E_CHAIN_URL:-$(tr -d '\r\n' < "$BW/chainctl.url" 2>/dev/null)}"
[ -n "$E2E_CHAIN_URL" ] || { echo "set E2E_CHAIN_URL or write bw/chainctl.url" >&2; exit 2; }
host="${E2E_CHAIN_URL#*://}"; host="${host%%[:/]*}"
export E2E_CHAIN_URL E2E_CHAIN_HOST="${E2E_CHAIN_HOST:-$host}"
export E2E_INSPECTOR_PORT="${E2E_INSPECTOR_PORT:-3791}" EXECS_OUT="$BW/e2e/$spec.execs.json"
# python3: a shim to MSYS2's native Windows Python (the Store's python3 is a stub).
export PATH="$BW/ui/shim:$PATH"
command -v python3 node > /dev/null || { echo "python3 and node must be on PATH" >&2; exit 2; }
# A run starts from the builds alone: the users, state, secrets and shots of the last one go.
rm -rf "$W/e2e/userA" "$W/e2e/userB" "$W/e2e/state.json" "$W/e2e/secrets" "$W/e2e/shots" "$W/e2e/drive.log" "$W"/e2e/basecamp-*.log
cd "$W" || exit 2
t0=$(date +%s)
bash -euo pipefail "$BW/e2e/$spec.sh" > "$BW/e2e/$spec.log" 2>&1
rc=$?
python3 "$E2E_REPO/doctests/e2e/drive.py" cleanup > /dev/null 2>&1
echo "$spec: exit $rc after $(( $(date +%s) - t0 )) s"
grep -E "^(PASS|FAIL|NOTE) |^PHASE " "$W/e2e/drive.log" | tail -80
