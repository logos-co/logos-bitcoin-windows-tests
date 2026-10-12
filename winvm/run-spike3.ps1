# Spike 3 on Windows: the core unloaded from its logos_host while Kyoto syncs headers, while it
# downloads filters, and idle; $Runs times each. Each cycle loads the core, reopens the wallet (no
# reset, the first payment there), waits for the state, then unloads. Kyoto's three peers are the
# chain host's nodes behind p2p_proxy.exe here, slowed per state through its mode files.
param([int]$Runs = 20)
$RUN = 'spike3'
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "Spike 3 on Windows, $Runs runs per state, $(Get-Date -Format o)"
$proxies = @()

function Modes([string]$json) { foreach ($i in 0..2) { [IO.File]::WriteAllText("$PDIR\mode$i.json", $json) }; Start-Sleep -Milliseconds 500 }

try {
    LayOut @('keystore', 'manager', 'kcli', 'scli', 'core')
    FreshChain
    Modes '{"mode":"forward"}'
    $upstream = FilterPeers
    foreach ($i in 0..2) {
        $listen = "127.0.0.1:$(19544 + 10 * $i)"
        $proxies += Start-Process -FilePath "$B\tools\p2p_proxy.exe" -ArgumentList $listen, $upstream[$i], "$PDIR\mode$i.json" -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput "$PDIR\proxy$i.out" -RedirectStandardError "$PDIR\proxy$i.err"
    }
    Log "proxies: $(($proxies | ForEach-Object { "$($_.Id)/$($_.ProcessName)" }) -join ', ')"
    $regtest = '{"kyoto":["127.0.0.1:19544","127.0.0.1:19554","127.0.0.1:19564"],"pollSecs":1,"kyotoRequired":2}'
    KeystoreSide
    LoadCore $regtest
    $o = OpenApproved '{"network":"regtest","family":"bitcoin"}'
    Log "first open: $(Cut $o 200)"
    Until 180 { param($v) $v.synced -eq $true -and $v.authority.kind -eq 'kyoto' } @($CORE, 'status') | Out-Null
    $addr = (J (Call $CORE next_address)).address
    $FUNDED = Fund $addr '1.0'
    Mine 1 | Out-Null
    Until 180 { param($v) $v.confirmed -eq '100000000' } @($CORE, 'balance') | Out-Null
    Log "funded $FUNDED"

    $summary = @()
    foreach ($state in 'headers', 'filters', 'idle') {
        $times = @(); $inside = @()
        foreach ($iter in 1..$Runs) {
            switch ($state) {
                'headers' { Modes '{"mode":"delay","ms":{"headers":8000}}'; Mine 3 | Out-Null }
                'filters' { Modes '{"mode":"delay","ms":{"cfilter":1000}}'; Mine 25 | Out-Null }
                'idle' { Modes '{"mode":"forward"}' }
            }
            Ctl module load $CORE --json | Out-Null; Start-Sleep -Seconds 1
            $o = J (OpenApproved "{`"network`":`"regtest`",`"group`":`"$GROUP`"}")
            if (-not $o.result -or $o.result.reset -ne $false -or $o.result.created -ne $false) { throw "the database did not reopen intact: $($o | ConvertTo-Json -Compress -Depth 5)" }
            if (-not (Until 60 { param($v) @($v.rows | Where-Object { $_.txid -eq $FUNDED }).Count -ge 1 } @($CORE, 'history', '0'))) { throw 'the first payment is missing after a reopen' }
            # Kyoto counts progress by batches: below the node's tip headers sync; at it, unsynced, filters do.
            $tip = Rpc getblockcount
            $want = switch ($state) {
                'headers' { { param($v) $v.kyoto -and $v.kyoto.running -and $v.kyoto.connected -ge 1 -and $v.kyoto.headers -lt $tip } }
                'filters' { { param($v) $v.kyoto -and $v.kyoto.running -and $v.kyoto.connected -ge 1 -and $v.kyoto.headers -eq $tip -and $v.synced -eq $false } }
                'idle' { { param($v) $v.synced -eq $true -and $v.kyoto.phase -eq 'synced' } }
            }
            if (-not (Until 90 $want @($CORE, 'status'))) { throw "never reached the $state state" }
            if ($state -eq 'idle') { Start-Sleep -Seconds 2 }
            $ms = Ms { Ctl module unload $CORE | Out-Null }
            $in = (Get-Content "$PERSIST\core.log" | Select-String 'unloaded in (\d+) ms' | Select-Object -Last 1).Matches.Groups[1].Value
            $times += $ms; $inside += $in
            Log "  $state #${n}: logosctl unload $ms ms, in module $in ms"
        }
        $sorted = $times | Sort-Object
        $ok = @($times | Where-Object { $_ -lt 2000 }).Count
        $line = "SPIKE $state : $ok/$($times.Count) within 2 s; median $($sorted[[int]($sorted.Count / 2)]) ms, max $($sorted[-1]) ms; in module max $(($inside | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum) ms"
        Log $line; $summary += $line
    }

    Modes '{"mode":"forward"}'
    Ctl module load $CORE --json | Out-Null; Start-Sleep -Seconds 1
    $o = OpenApproved "{`"network`":`"regtest`",`"group`":`"$GROUP`"}"
    $st = Until 120 { param($v) $v.synced -eq $true } @($CORE, 'status')
    Log "LAST REOPEN: $(Cut $o 200); height $((J $st).authority.height), kyoto $((J $st).kyoto.phase); confirmed $((J (Call $CORE balance)).confirmed)"
    Job close_wallet '{}' | Out-Null
    Ctl module unload $CORE | Out-Null
    $crash = @(Get-ChildItem -Recurse -File "$SESS\logs" -ErrorAction SilentlyContinue | Select-String -Pattern 'crash|abort|segmentation|access violation|0xc0000005|exited with code [1-9]' -List)
    Log "crash lines in the session logs: $($crash.Count)$(if ($crash.Count) { ': ' + (Cut (($crash | Select-Object -First 3) -join ' | ') 400) })"
    $summary | ForEach-Object { Log $_ }
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    StopDaemon
    foreach ($px in $proxies) { if (-not $px.HasExited) { $px.Kill(); Log "stopped proxy $($px.Id)" } }
    Log 'END'
}
