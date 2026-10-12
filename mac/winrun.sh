#!/bin/bash
# winrun.sh <script.ps1> [args...]: runs <script> from the Windows work dir on winvm in one ssh session.
# WIN_SSH is the ssh command for it ("ssh winvm" unless set); BTC_CHAINCTL, BTC_CHAIN_NAME and
# BTC_WIN_DIR, when set, reach the script's environment (lib.ps1).
read -r -a WIN <<< "${WIN_SSH:-ssh winvm}"
s="$1"; shift
env=""
[ -n "${BTC_CHAINCTL:-}" ] && env="\$env:BTC_CHAINCTL = '$BTC_CHAINCTL'; "
[ -n "${BTC_CHAIN_NAME:-}" ] && env="$env\$env:BTC_CHAIN_NAME = '$BTC_CHAIN_NAME'; "
[ -n "${BTC_WIN_DIR:-}" ] && env="$env\$env:BTC_WIN_DIR = '$BTC_WIN_DIR'; "
cmd="$env\$ProgressPreference = 'SilentlyContinue'; \$bw = if (\$env:BTC_WIN_DIR) { \$env:BTC_WIN_DIR } else { \"\$env:USERPROFILE\\bw\" }; try { & ([ScriptBlock]::Create([IO.File]::ReadAllText(\"\$bw\\$s\"))) $* } catch { 'LAUNCH ERROR: ' + \$_.Exception.Message }"
"${WIN[@]}" "powershell -NoProfile -EncodedCommand $(printf '%s' "$cmd" | iconv -f UTF-8 -t UTF-16LE | base64)" 2>&1 | tr -d '\r' | grep -v "quantum\|store now\|upgraded\|CLIXML\|^<Objs"
