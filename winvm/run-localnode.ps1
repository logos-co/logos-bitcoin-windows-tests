# The local node as the chain authority on Windows: bitcoind_module running Core in-process on
# regtest, the core following it over Logos IPC (a backlog by block filters, then the Emitter) and
# broadcasting through its sendrawtransaction; then set_birthday's rescan of the node's filters.
$RUN = 'localnode'
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "The local-node route on Windows, $(Get-Date -Format o)"
$BTCD = 'bitcoind_module'
$PAYEE = 'bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080'
function NodeRpc([string]$m, [string]$params) { Call $BTCD rpc $m (F "rpc-$m.json" $params) }
function NodeMine([int]$count, [string]$to) { NodeRpc generatetoaddress "[$count,`"$to`"]" | Out-Null }

try {
    LayOut @('keystore', 'manager', 'kcli', 'scli', 'core', 'bitcoind')
    [IO.File]::WriteAllText("$PDIR\empty", '')
    KeystoreSide
    Log "load ${N}: $(Cut (Ctl module load $BTCD --json) 160)"
    $INST = (Get-ChildItem -Directory "$SESS\data\$BTCD" | Select-Object -First 1).FullName
    [IO.File]::WriteAllText("$INST\callers.json", '{"modules":["bitcoin_wallet_core_module","bitcoin_node_module"],"allowHost":true}')
    Ctl module unload $BTCD | Out-Null; Ctl module load $BTCD --json | Out-Null
    Log "start regtest: $(Cut (Call $BTCD start regtest) 100)"
    Until 60 { param($v) $v.state -eq 'running' } @($BTCD, 'status') | Out-Null
    # A fresh regtest chain is in initial sync until a block carries today's time.
    NodeMine 1 $PAYEE
    $ns = Until 60 { param($v) $v.blocks -ge 1 -and $v.initialSync -eq $false } @($BTCD, 'status')
    Log "node: $(Cut $ns 200)"

    LoadCore '{"local":true,"pollSecs":1}'
    $t0 = Get-Date
    Log "OPEN: $(Cut (OpenApproved '{"network":"regtest","family":"bitcoin"}') 260)"
    $st = Until 120 { param($v) $v.synced -eq $true -and $v.authority.kind -eq 'local_node' } @($CORE, 'status')
    Log "SYNCED on the local node in $([int]((Get-Date) - $t0).TotalMilliseconds) ms: $(Cut (((J $st).authority | ConvertTo-Json -Compress), ((J $st).node | ConvertTo-Json -Compress) -join ' ') 300)"

    $addr = (J (Call $CORE next_address)).address
    NodeMine 1 $addr
    NodeMine 100 $PAYEE
    Log "RECEIVED (coinbase, matured): $(Cut (Until 120 { param($v) $v.confirmed -eq '5000000000' } @($CORE, 'balance')) 200)"

    $prev = (J (Job build_send "{`"recipients`":[{`"address`":`"$PAYEE`",`"amountSat`":`"1000000000`"}],`"feeRate`":2}")).result
    $sent = J (SignApproved $prev.previewId)
    $txid = $sent.result.txid
    Log "SENT via $($sent.result.via): $txid broadcast $($sent.result.broadcast)"
    $entry = J (NodeRpc getmempoolentry ('["' + $txid + '"]'))
    Log "in the node's mempool: $(if ($entry.error -eq $null -and $entry.result) { 'yes' } else { "NO: $($entry | ConvertTo-Json -Compress)" })"
    NodeMine 1 $PAYEE
    $h = Until 120 { param($v) @($v.rows | Where-Object { $_.txid -eq $txid -and $_.state -eq 'confirmed' }).Count -eq 1 } @($CORE, 'history', '0')
    Log "CONFIRMED: $(Cut ((J $h).rows | Where-Object { $_.txid -eq $txid } | ConvertTo-Json -Compress) 300)"
    Log "sources: $(Cut ((J (Call $CORE sources_status)) | Select-Object chainBy, local | ConvertTo-Json -Compress) 200)"

    Log "set_birthday: $(Cut ((J (Job set_birthday '{"height":2}')).result | ConvertTo-Json -Compress) 200)"
    $st = Until 120 { param($v) $v.rescanFrom -eq $null -and $v.synced -eq $true -and $v.node.filters -eq $true -and $v.node.matched -ge 2 } @($CORE, 'status')
    Log "RESCAN by filters: $(Cut ((J $st).node | ConvertTo-Json -Compress) 300)"
    Log "balance: $(Cut (Call $CORE balance) 200)"

    Log "close: $(Cut (Job close_wallet '{}') 100)"
    $ms = Ms { $script:u = Ctl module unload $CORE --json }
    Log "UNLOAD core: $ms ms"
    Log "stop node: $(Cut (Call $BTCD stop) 100)"
    $ms = Ms { Ctl module unload $BTCD | Out-Null }
    Log "UNLOAD bitcoind_module: $ms ms"
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    StopDaemon
    Log 'END'
}
