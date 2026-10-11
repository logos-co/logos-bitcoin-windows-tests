#!/bin/bash
# winrun.sh <script.ps1> [args...]: runs <script> from the Windows work dir on winvm in one ssh session.
s="$1"; shift
cmd="\$ProgressPreference = 'SilentlyContinue'; \$bw = if (\$env:BTC_WIN_DIR) { \$env:BTC_WIN_DIR } else { \"\$env:USERPROFILE\\bw\" }; try { & ([ScriptBlock]::Create([IO.File]::ReadAllText(\"\$bw\\$s\"))) $* } catch { 'LAUNCH ERROR: ' + \$_.Exception.Message }"
ssh winvm "powershell -NoProfile -EncodedCommand $(printf '%s' "$cmd" | iconv -f UTF-8 -t UTF-16LE | base64)" 2>&1 | tr -d '\r' | grep -v "quantum\|store now\|upgraded\|CLIXML\|^<Objs"
