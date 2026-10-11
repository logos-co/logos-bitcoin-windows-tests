# bitcoind_module on Windows in a real logos_host under logosctl, HOME isolated: start, stop and a
# regtest -> signet -> regtest switch in one process (signet through a Tor started here), then
# $Runs unloads at the tip on regtest, half of them with connects to blackholed addNodes in flight.
param([int]$Runs = 20)
$RUN = 'node'
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "bitcoind_module on Windows, $(Get-Date -Format o)"
$BTCD = 'bitcoind_module'
$tor = $null

function NCall { $r = Call $BTCD @args; $v = J $r; if ($v -and $v.PSObject.Properties.Name -contains 'value') { return ($v.value | ConvertTo-Json -Compress -Depth 20) }; return $r }
# This session's host for the module only: other sessions on this machine run logos_host too.
function NodeHost { Get-CimInstance Win32_Process -Filter "Name LIKE 'logos_host%'" | Where-Object { $_.CommandLine -like "*--name $BTCD *" -and ($_.CommandLine -replace '/', '\') -like "*\$(Split-Path -Leaf $B)\$RUN\*" } | Select-Object -First 1 }
function WaitState([string]$want, [int]$secs = 60) {
    $end = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $end) { $ns = J (Call $BTCD status); if ($ns.state -eq $want) { return $ns }; Start-Sleep -Milliseconds 100 }
    return $null
}
function Chain { $r = J (Call $BTCD rpc getblockchaininfo "@$PDIR\empty"); return "$($r.result.chain) blocks $($r.result.blocks)" }

try {
    LayOut @('bitcoind')
    [IO.File]::WriteAllText("$PDIR\empty", '')
    New-Item -ItemType Directory -Force "$B\tordata" | Out-Null
    Remove-Item "$B\tor.log" -ErrorAction SilentlyContinue
    $tor = Start-Process -FilePath 'C:\tor\tor\tor.exe' -ArgumentList '-f', "$B\torrc" -WorkingDirectory $B -WindowStyle Hidden -PassThru
    Log "daemon start: $(Cut (Ctl daemon start --detach) 120)"
    Start-Sleep -Seconds 3
    Log "load: $(Cut (Ctl module load $BTCD --json) 160)"
    $INST = (Get-ChildItem -Directory "$SESS\data\$BTCD" | Select-Object -First 1).FullName
    [IO.File]::WriteAllText("$INST\callers.json", '{"modules":["bitcoin_wallet_core_module","bitcoin_node_module"],"allowHost":true}')
    Ctl module unload $BTCD | Out-Null
    Log "reload: $(Cut (Ctl module load $BTCD --json) 160)"
    Log "configure signet (Tor): $(Cut (Call $BTCD configure signet "json:$(F 'signet.json' '{"proxy":"127.0.0.1:19150"}')") 160)"
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 120 -and -not (Select-String -Path "$B\tor.log" -Pattern 'Bootstrapped 100%' -Quiet -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 1 }
    Log "tor (pid $($tor.Id)): $((Select-String -Path "$B\tor.log" -Pattern 'Bootstrapped' | Select-Object -Last 1).Line)"

    # One logos_host: regtest, signet, regtest.
    $h0 = NodeHost
    Log "logos_host for ${BTCD}: pid $($h0.ProcessId)"
    foreach ($leg in 'regtest', 'signet', 'regtest') {
        $t0 = Get-Date
        $r = Call $BTCD start $leg
        $ns = WaitState running 60
        Log "START $leg : running after $([int]((Get-Date) - $t0).TotalMilliseconds) ms ($(Cut $r 80))"
        if ($leg -eq 'regtest') {
            if ((J (Call $BTCD rpc getblockcount "@$PDIR\empty")).result -lt 101) { Call $BTCD rpc generatetoaddress (F 'gen.json' '[101,"bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"]') | Out-Null }
            Log "  $(Chain)"
        } else {
            $t1 = Get-Date
            while (((Get-Date) - $t1).TotalSeconds -lt 180) { $ns = J (Call $BTCD status); if ($ns.peersOut -ge 1) { break }; Start-Sleep -Seconds 2 }
            Log "  $(Chain); peersOut $($ns.peersOut) after $([int]((Get-Date) - $t1).TotalSeconds) s; headers $($ns.headers)"
        }
        $t0 = Get-Date; $r = Call $BTCD stop
        Log "STOP $leg : $([int]((Get-Date) - $t0).TotalMilliseconds) ms ($(Cut $r 80))"
    }
    $h1 = NodeHost
    Log "SAME PROCESS: $(if ($h1.ProcessId -eq $h0.ProcessId) { "yes, pid $($h1.ProcessId)" } else { "NO: $($h0.ProcessId) -> $($h1.ProcessId)" })"

    # Unloads at the tip: a block mined just before; odd runs keep eight blackholed connects in flight.
    $black = '{"addNodes":["192.0.2.1:18444","192.0.2.2:18444","192.0.2.3:18444","192.0.2.4:18444","198.51.100.1:18444","198.51.100.2:18444","203.0.113.1:18444","203.0.113.2:18444"]}'
    $times = @(); $stops = @()
    foreach ($iter in 1..$Runs) {
        $withBlack = ($iter % 2) -eq 1
        Call $BTCD configure regtest "json:$(F 'rt.json' $(if ($withBlack) { $black } else { '{"addNodes":[]}' }))" | Out-Null
        if ($iter -gt 1) { Ctl module load $BTCD --json | Out-Null }
        Call $BTCD start regtest | Out-Null
        if (-not (WaitState running 60)) { throw "run ${iter}: never running" }
        Call $BTCD rpc generatetoaddress (F 'gen1.json' '[1,"bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"]') | Out-Null
        Start-Sleep -Milliseconds 1500
        $ms = Ms { Ctl module unload $BTCD | Out-Null }
        Start-Sleep -Milliseconds 300
        $line = Get-Content "$INST\unload.log" -ErrorAction SilentlyContinue | Select-String 'node stopped in (\d+) ms' | Select-Object -Last 1
        $stop = if ($line) { $line.Matches.Groups[1].Value } else { '?' }
        $times += $ms; $stops += $stop
        Log "  unload #$iter$(if ($withBlack) { ' (blackholed connects)' }): $ms ms, node stop $stop ms"
    }
    $sorted = $times | Sort-Object
    Log "UNLOADS AT THE TIP: $(@($times | Where-Object { $_ -lt 2000 }).Count)/$($times.Count) within 2 s; median $($sorted[[int]($sorted.Count / 2)]) ms, max $($sorted[-1]) ms"
    $crash = @(Get-ChildItem -Recurse -File "$SESS\logs" -ErrorAction SilentlyContinue | Select-String -Pattern 'crash|abort|access violation|0xc0000005|exited with code [1-9]' -List)
    Log "crash lines in the session logs: $($crash.Count)"
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    StopDaemon
    if ($tor -and -not $tor.HasExited) { $tor.Kill(); Log "stopped tor $($tor.Id)" }
    Log 'END'
}
