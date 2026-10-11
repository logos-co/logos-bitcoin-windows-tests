# The wallet on Windows through bitcoin_wallet_backend and bitcoin_wallet_cli under logosctl, the
# chain on the Linux host: an open decided in evm_keystore_cli; a send relayed by the CLI and
# approved in evm_signer_cli; a send whose outcome is unknown (both electrs down at the approval),
# then rebroadcast; another one abandoned; and a backend restart with a send awaiting approval.
$RUN = 'backend'
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "Bitcoin wallet backend and CLI on Windows, $(Get-Date -Format o)"
$CLI = 'bitcoin_wallet_cli'
$BACKEND = 'bitcoin_wallet_backend'
# BIP173's regtest vector: a payee that is nobody's wallet here.
$PAYEE = 'bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080'

# Not "Cli": that is PowerShell's alias for Clear-Item, and aliases win over functions.
function BtcCli { Call $CLI @args }
function Inst([string]$module) { (Get-ChildItem -Directory "$SESS\data\$module" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
function SendStatus([string]$id) { J (BtcCli send_status $id) }
function WaitSend([string]$id, [string[]]$states, [int]$secs = 120) {
    $st = Until $secs { param($v) $v.state -in $states } @($CLI, 'send_status', $id)
    return (J $st)
}
# A send asked for through the CLI, up to its approval handle: returns the request id.
function Ask([string]$btc) {
    $r = J (BtcCli send $PAYEE "str:$btc")
    if (-not $r.requestId) { throw "send refused: $($r | ConvertTo-Json -Compress)" }
    $s = WaitSend $r.requestId @('awaiting_approval', 'failed', 'cancelled') 60
    if ($s.state -ne 'awaiting_approval') { throw "send $($r.requestId): $($s | ConvertTo-Json -Compress -Depth 5)" }
    Log "asked $btc BTC: $($r.requestId) awaiting approval $($s.approvalHandle)"
    return $r.requestId
}
# Approves request $id in evm_signer_cli, as a person reading its lines would.
function Approve([string]$id) {
    $ah = (SendStatus $id).approvalHandle
    $rendered = Until 60 { param($v) $v.rendered -and $v.rendered.handle -eq $ah } @('evm_signer_cli', 'status')
    $bundle = (J $rendered).rendered.bundle_id
    Log "signer shows: $(Cut ((J (Call evm_signer_cli show $ah)).text) 200)"
    Log "approve ${ah}: $(Cut (Call evm_signer_cli approve $ah "str:$bundle" "@$PDIR\pw.txt") 120)"
}
function Confirmed([string]$txid, [int]$secs = 120) {
    Until $secs { param($v) @($v.rows | Where-Object { $_.txid -eq $txid -and $_.state -eq 'confirmed' }).Count -eq 1 } @($CLI, 'history', '0') | Out-Null
}

try {
    LayOut @('keystore', 'manager', 'kcli', 'scli', 'core00d', 'node', 'backend', 'cli')
    FreshChain
    $urls = ElectrumUrls
    $regtest = "{`"electrum`":[`"$($urls[0])`",`"$($urls[1])`"],`"pollSecs`":1}"
    KeystoreSide
    Log "load cli (and the backend, core and node module it needs): $(Cut (Ctl module load $CLI --json) 300)"
    Start-Sleep -Seconds 2
    # Test-only files: regtest for the three, the core's servers, the CLI as a custodian.
    [IO.File]::WriteAllText("$(Inst $CORE)\regtest.json", $regtest)
    [IO.File]::WriteAllText("$(Inst 'bitcoin_node_module')\regtest.json", '{}')
    [IO.File]::WriteAllText("$(Inst $BACKEND)\regtest.json", '{}')
    [IO.File]::WriteAllText("$(Inst $BACKEND)\roles.json", '{"custodians":["bitcoin_wallet_ui","bitcoin_wallet_cli"]}')
    foreach ($m in $CLI, $BACKEND, 'bitcoin_node_module', $CORE) { Ctl module unload $m | Out-Null }
    Log "reload cli: $(Cut (Ctl module load $CLI --json) 300)"
    Start-Sleep -Seconds 2
    Log "cli status: $(Cut (BtcCli status) 200)"
    Log "network: $(Cut (BtcCli set_active_network regtest) 120)"

    # Open: the core asks the manager; evm_keystore_cli decides.
    $t0 = Get-Date
    $o = J (BtcCli open_wallet (F 'open.json' '{"family":"bitcoin"}'))
    Log "open_wallet: job $($o.jobId), handle $($o.openHandle); next: $(Cut $o.next 160)"
    $shown = J (Call evm_keystore_cli show_access $o.openHandle)
    $d = @{ handle = $shown.handle; bundle_id = $shown.bundle_id; group = $GROUP; password = 'btc-pw' } | ConvertTo-Json -Compress
    Log "approve_access: $(Cut (Call evm_keystore_cli approve_access (F 'decision.json' $d)) 120)"
    $ws = Until 120 { param($v) $v.state -eq 'ready' -and $v.synced -eq $true } @($CLI, 'wallet_status')
    Log "OPEN: ready and synced in $([int]((Get-Date) - $t0).TotalMilliseconds) ms; $(Cut $ws 220)"

    $addr = (J (BtcCli receive_address)).address
    Log "receive: $addr funded by $(Fund $addr '1.0'); height $(Mine 1)"
    Log "RECEIVED: $(Cut (Until 120 { param($v) $v.confirmed -eq '100000000' } @($CLI, 'balances')) 220)"

    # A send relayed by the CLI, approved in evm_signer_cli.
    $s1 = Ask '0.25'
    Log "cli show: $(Cut ((J (BtcCli show $s1)).text) 300)"
    Approve $s1
    $st = WaitSend $s1 @('sent', 'failed', 'unknown', 'cancelled')
    Log "SENT ${s1}: state $($st.state), txid $($st.txid), broadcast $($st.broadcast)"
    Log "in the mining node's mempool after $(WaitPool $st.txid) s; height $(Mine 1)"
    Confirmed $st.txid
    Log "CONFIRMED $($st.txid.Substring(0, 12)) in the CLI's history"

    # Unknown: both electrs down when the person approves; rebroadcast once they are back.
    $s2 = Ask '0.04'
    $null = ElectrsStop
    Approve $s2
    $st = WaitSend $s2 @('sent', 'failed', 'unknown', 'cancelled') 180
    $inPool = (Rpc getrawmempool) -contains $st.txid
    Log "UNKNOWN ${s2}: state $($st.state), broadcast $($st.broadcast), txid $($st.txid); in the node's mempool: $inPool"
    $null = ElectrsStart
    Log "rebroadcast: $(Cut (BtcCli rebroadcast $s2) 200)"
    $st = WaitSend $s2 @('sent') 120
    Log "REBROADCAST ${s2}: state $($st.state); in the mining node's mempool after $(WaitPool $st.txid) s; height $(Mine 1)"
    Confirmed $st.txid

    # Abandoned: unknown again, then forgotten; its coins come back and it never leaves.
    Start-Sleep -Seconds 3
    $before = (J (BtcCli balances)).confirmed
    $s3 = Ask '0.03'
    $null = ElectrsStop
    Approve $s3
    $st = WaitSend $s3 @('sent', 'failed', 'unknown', 'cancelled') 180
    Log "unknown ${s3}: state $($st.state), txid $($st.txid)"
    # Built outside the log string: an escaped quote nested in $() in a string cuts the inner one.
    $doc = F 'abandon.json' ('{"txid":"' + $st.txid + '"}')
    Log "abandon_send: $(Cut (BtcCli abandon_send $doc) 200)"
    $ab = J (Until 60 { param($v) $v.abandoned -eq $true } @($CLI, 'send_status', $s3))
    Log "ABANDONED ${s3}: state $($ab.state), abandoned $($ab.abandoned), offer $(@($ab.offer).Count)"
    $null = ElectrsStart
    Log "height $(Mine 1); in the node's mempool: $((Rpc getrawmempool) -contains $st.txid)"
    $bal = Until 90 { param($v) $v.confirmed -eq $before } @($CLI, 'balances')
    Log "coins back: confirmed $((J $bal).confirmed) (was $before)"

    # A backend restart with a send awaiting approval.
    $s4 = Ask '0.02'
    $ms = Ms { $script:rl = Ctl module reload $BACKEND --json }
    Log "RESTART backend: $(Cut $rl 160) in $ms ms"
    $st = WaitSend $s4 @('awaiting_approval', 'failed', 'cancelled', 'unknown', 'sent') 60
    Log "after the restart ${s4}: state $($st.state), handle $($st.approvalHandle)"
    Approve $s4
    $st = WaitSend $s4 @('sent', 'failed', 'unknown', 'cancelled')
    Log "SENT AFTER RESTART ${s4}: state $($st.state), txid $($st.txid); in the mining node's mempool after $(WaitPool $st.txid) s; height $(Mine 1)"
    Confirmed $st.txid
    $sends = ((J (BtcCli list_sends)).sends | ForEach-Object { "$($_.requestId) $($_.state)" }) -join ', '
    Log "sends: $sends"
    Log "wallet: $(Cut (BtcCli wallet_status) 200)"

    Log "close: $(Cut (BtcCli close_wallet) 120)"
    $ms = Ms { $script:u = Ctl module unload $CLI --json }
    Log "UNLOAD cli: $(Cut $u 120) in $ms ms"
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    $null = ElectrsStart
    StopDaemon
    Log 'END'
}
