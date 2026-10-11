# The wallet on Windows under logosctl, against the regtest chain on framework, reached directly
# under the LAN rule: open (evm_keystore_cli), receive, send (evm_signer_cli), confirm, a fee bump,
# close and reopen. -Authority electrum: the Electrum header chain; kyoto: Kyoto, electrs only checks.
# -Race mines right after the bump's broadcast, so the original may confirm first.
param([ValidateSet('electrum', 'kyoto')][string]$Authority = 'electrum', [switch]$Race)
$RUN = "flow-$Authority$(if ($Race) { '-race' })"
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "Bitcoin wallet regtest flow on Windows, authority $Authority, $(Get-Date -Format o)"
$kind = @{ electrum = 'electrum_headers'; kyoto = 'kyoto' }[$Authority]
FreshChain
# One server by the chain host's .lan name, so the core's LAN rule for names runs too.
$urls = ElectrumUrls
$byName = $urls[0] -replace [regex]::Escape($FW), 'framework.lan'
$peers = (FilterPeers | ForEach-Object { "`"$_`"" }) -join ','
$regtest = @{
    electrum = "{`"electrum`":[`"$byName`",`"$($urls[1])`"],`"pollSecs`":1}"
    kyoto    = "{`"kyoto`":[$peers],`"electrum`":[`"$byName`"],`"checkOnly`":true,`"kyotoRequired`":2,`"pollSecs`":1}"
}[$Authority]
# BIP173's regtest vector: a payee that is nobody's wallet here.
$PAYEE = 'bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080'

try {
    LayOut @('keystore', 'manager', 'kcli', 'scli', 'core')
    Log "chain height: $(Rpc getblockcount); regtest.json $regtest"
    KeystoreSide
    LoadCore $regtest
    Log "persistence: $PERSIST"

    $t0 = Get-Date
    $o = OpenApproved '{"network":"regtest","family":"bitcoin"}'
    Log "OPEN: $(Cut $o 300)"
    $st = Until 180 { param($v) $v.synced -eq $true -and $v.authority.kind -eq $kind } @($CORE, 'status')
    Log "SYNCED on $kind in $([int]((Get-Date) - $t0).TotalMilliseconds) ms: $(Cut ((J $st).authority | ConvertTo-Json -Compress) 200)"

    $addr = (J (Call $CORE next_address)).address
    $funded = Fund $addr '1.0'
    Log "receive: $addr funded by $funded; height $(Mine 1)"
    $bal = Until 180 { param($v) $v.confirmed -eq '100000000' } @($CORE, 'balance')
    Log "RECEIVED: $(Cut $bal 200)"

    $pv = Job build_send "{`"recipients`":[{`"address`":`"$PAYEE`",`"amountSat`":`"25000000`"}],`"feeRate`":2}"
    $prev = (J $pv).result
    Log "preview: $($prev.previewId) fee $($prev.feeSat) sat at $($prev.feeRate) sat/vB, txid $($prev.txid)"
    $sent = SignApproved $prev.previewId
    $txid = (J $sent).result.txid
    Log "SENT: $(Cut $sent 300)"
    Log "in the mining node's mempool after $(WaitPool $txid) s"

    $bp = Job bump_fee "{`"txid`":`"$txid`",`"feeRate`":10}"
    $bump = (J $bp).result
    Log "bump preview: $($bump.previewId) kind $($bump.kind) fee $($bump.feeSat) sat at $($bump.feeRate) sat/vB, replaces $($bump.replaces)"
    $bumped = SignApproved $bump.previewId
    $btxid = (J $bumped).result.txid
    Log "BUMPED: $(Cut $bumped 300)"
    $waited = if ($Race) { 'not waited' } else { WaitPool $btxid }
    $pool = Rpc getrawmempool
    Log "mining node's mempool: bump $(if ($pool -contains $btxid) { "in after $waited s" } else { 'MISSING' }), original $(if ($pool -contains $txid) { 'STILL IN' } else { 'replaced' })"

    Log "mined: height $(Mine 1)"
    $h = Until 180 { param($v) @($v.rows | Where-Object { $_.txid -in @($btxid, $txid) -and $_.state -eq 'confirmed' }).Count -eq 1 } @($CORE, 'history', '0')
    Log "history after the block: $(Rows $h)"
    $rows = (J $h).rows
    $brow = $rows | Where-Object { $_.txid -eq $btxid } | Select-Object -First 1
    $o0 = $rows | Where-Object { $_.txid -eq $txid } | Select-Object -First 1
    Log "CONFIRMED: bump $($brow.state) intent $($brow.intent) fee $($brow.feeSat) replaces $($brow.replaces); original $($o0.state) replacedBy $($o0.replacedBy)"
    $bal1 = Call $CORE balance
    Log "balance: $(Cut $bal1 200)"

    Log "CLOSE: $(Cut (Job close_wallet '{}') 160)"
    Log "status after close: $(Cut ((J (Call $CORE status)).state) 40)"

    $t0 = Get-Date
    $o = OpenApproved "{`"network`":`"regtest`",`"group`":`"$GROUP`"}"
    Log "REOPEN: $(Cut $o 300)"
    $st = Until 180 { param($v) $v.synced -eq $true -and $v.authority.kind -eq $kind } @($CORE, 'status')
    Log "synced again in $([int]((Get-Date) - $t0).TotalMilliseconds) ms"
    $bal2 = Call $CORE balance
    $h2 = J (Call $CORE history 0)
    Log "after reopen: balance $(if ($bal2 -eq $bal1) { 'unchanged' } else { "CHANGED: $(Cut $bal2 200)" }); $(@($h2.rows).Count) history rows; bump $((@($h2.rows) | Where-Object { $_.txid -eq $btxid }).state)"
    Log "history: $(Rows (Call $CORE history 0))"
    Log "sources: $(Cut (Call $CORE sources_status) 500)"

    Log "close: $(Cut (Job close_wallet '{}') 100)"
    $ms = Ms { $script:u = Ctl module unload $CORE --json }
    Log "UNLOAD: $(Cut $u 120) in $ms ms; $(Get-Content "$PERSIST\core.log" | Select-String 'unloaded in' | Select-Object -Last 1)"
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    StopDaemon
    Log 'END'
}
