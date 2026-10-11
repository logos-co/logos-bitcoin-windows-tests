#!/bin/bash
# stage.sh <result under ~/btc-win-out on the Linux machine> <dir under the Windows work dir>
# Replaces the Windows dir with a dereferenced copy of the result; store copies are read-only,
# so their attributes are cleared first.
set -euo pipefail
# BTC_WIN_DIR: the Windows work dir; unless set, bw under the ssh user's home, where sessions start.
src="$1"; dst="$2"; win="${BTC_WIN_DIR:-bw}/$dst"
clear="\$d = '$win'; if (Test-Path \$d) { Get-ChildItem -Recurse -File \$d | ForEach-Object { \$_.IsReadOnly = \$false }; Remove-Item -Recurse -Force \$d }; New-Item -ItemType Directory -Force \$d | Out-Null"
ssh winvm "powershell -NoProfile -EncodedCommand $(printf '%s' "$clear" | iconv -f UTF-8 -t UTF-16LE | base64)" > /dev/null 2>&1
ssh "${LINUX_HOST:-chain-host}" "tar -C ~/btc-win-out/$src -chf - ." | ssh winvm "tar -xf - -C $win"
echo "staged $src -> $win"
