#!/bin/bash
# stage.sh <result under ~/btc-win-out on the Linux machine> <dir under the Windows work dir>
# Replaces the Windows dir with a dereferenced copy of the result; store copies are read-only,
# so their attributes are cleared first. WIN_SSH and LINUX_SSH are the ssh commands for the two
# machines ("ssh winvm" and "ssh chain-host" unless set; e.g. with -i and an address).
set -euo pipefail
read -r -a WIN <<< "${WIN_SSH:-ssh winvm}"
read -r -a LIN <<< "${LINUX_SSH:-ssh chain-host}"
# BTC_WIN_DIR: the Windows work dir; unless set, bw under the ssh user's home, where sessions start.
src="$1"; dst="$2"; win="${BTC_WIN_DIR:-bw}/$dst"
clear="\$d = '$win'; if (Test-Path \$d) { Get-ChildItem -Recurse -File \$d | ForEach-Object { \$_.IsReadOnly = \$false }; Remove-Item -Recurse -Force \$d }; New-Item -ItemType Directory -Force \$d | Out-Null"
"${WIN[@]}" "powershell -NoProfile -EncodedCommand $(printf '%s' "$clear" | iconv -f UTF-8 -t UTF-16LE | base64)" > /dev/null 2>&1
"${LIN[@]}" "tar -C ~/btc-win-out/$src -chf - ." | "${WIN[@]}" "tar -xf - -C $win"
echo "staged $src -> $win"
