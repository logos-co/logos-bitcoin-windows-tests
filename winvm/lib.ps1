# Shared by the Bitcoin wallet runs on Windows: logosctl, the keystore side, jobs, and the regtest
# chain on a Linux host through its chainctl (chain-host/). Dot-source it after setting $RUN.
# The service is $env:BTC_CHAINCTL, else the URL in bw\chainctl.url (http://<chain host>:28600);
# $env:BTC_CHAIN_NAME, if set, is a name of the chain host, for the core's LAN rule on names.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# logosctl writes UTF-8; PowerShell would decode it with the OEM code page.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$B = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
$CTL = "$B\ctl\bin\logosctl.exe"
$CORE = 'bitcoin_wallet_core_module'
$CHAINCTL = if ($env:BTC_CHAINCTL) { $env:BTC_CHAINCTL } elseif (Test-Path "$B\chainctl.url") { [IO.File]::ReadAllText("$B\chainctl.url").Trim() } else { throw 'no chain host: set BTC_CHAINCTL or write bw\chainctl.url' }
$FW = ([Uri]$CHAINCTL).Host
$FWNAME = $env:BTC_CHAIN_NAME
$SESS = "$B\$RUN\session"
$OUT = "$B\results-$RUN.txt"
$PDIR = "$B\$RUN\p"

function Log([string]$m) { Add-Content -Path $OUT -Value ((Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + ' ' + $m) }
function Cut([string]$s, [int]$n = 400) { $s = $s -replace "`r?`n", ' '; if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }
function Ctl { (& $CTL --config-dir $SESS @args 2>&1 | Out-String).Trim() }
function Call { (& $CTL --config-dir $SESS call @args --human 2>&1 | Out-String).Trim() }
function J([string]$s) { try { $s | ConvertFrom-Json } catch { $null } }
# A JSON or text argument through a file: PowerShell 5.1 mangles quotes in native arguments.
function F([string]$name, [string]$text) { $f = "$PDIR\$name"; [IO.File]::WriteAllText($f, $text); return "@$f" }
function Ms([scriptblock]$block) { [int](Measure-Command $block).TotalMilliseconds }

# Polls `Call @call` until $test (a scriptblock over the parsed reply) holds, for up to $secs.
function Until([int]$secs, [scriptblock]$test, [object[]]$call) {
    $end = (Get-Date).AddSeconds($secs)
    $r = ''
    while ((Get-Date) -lt $end) {
        $r = Call @call
        $v = J $r
        if ($v -ne $null) { try { if (& $test $v) { return $r } } catch {} }
        Start-Sleep -Milliseconds 250
    }
    Log "TIMEOUT ($secs s) $($call -join ' '): $(Cut $r 300)"
    return $null
}

# The chain, through chainctl: chain.sh's subcommands, a fresh chain, electrs stopped and started.
function ChainPost([string]$path, [hashtable]$body = @{}) {
    $json = ConvertTo-Json -InputObject $body -Compress -Depth 5
    try { Invoke-RestMethod -Uri "$CHAINCTL$path" -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 900 }
    catch { [pscustomobject]@{ code = -1; stdout = ''; stderr = "chainctl ${path}: $($_.Exception.Message) $($_.ErrorDetails.Message)" } }
}
function Chain {
    $r = ChainPost '/run' @{ args = [string[]]$args }
    if ($r.code -ne 0) { Log "chain $($args -join ' '): exit $($r.code): $(Cut "$($r.stdout) $($r.stderr)" 300)" }
    return "$($r.stdout)".Trim()
}
function Rpc([string]$method, [string]$params = '[]', [string]$wallet = '') {
    $a = @('rpc', $method, $params) + $(if ($wallet) { @($wallet) } else { @() })
    $reply = Chain @a
    try { $j = $reply | ConvertFrom-Json } catch { return "RPC ERROR ${method}: $reply" }
    if ($j.error) { return "RPC ERROR ${method}: $($j.error | ConvertTo-Json -Compress)" }
    return $j.result
}
function FreshChain { $r = ChainPost '/fresh'; Log "fresh chain: $(Cut "$($r.stdout)$($r.stderr)" 120)"; $script:MINER = $null }
function ElectrsStop { $r = ChainPost '/electrs-stop'; Log "electrs stop: $(Cut "$($r.stdout) $($r.stderr)" 160)"; return $r.code -eq 0 }
function ElectrsStart { $r = ChainPost '/electrs-start'; Log "electrs start: $(Cut "$($r.stdout) $($r.stderr)" 160)"; return $r.code -eq 0 }
# What the chain host prints for its servers and its filter-serving peers.
function ElectrumUrls { (Chain electrum) -replace '^electrum: ', '' -split ',' }
function FilterPeers { (Chain peers) -split ',' }
function Miner { if (-not $script:MINER) { $script:MINER = Rpc getnewaddress '["miner","bech32"]' miner }; return $script:MINER }
function Mine([int]$n, [string]$to = '') { if (-not $to) { $to = Miner }; Rpc generatetoaddress "[$n,`"$to`"]" | Out-Null; Rpc getblockcount }
function Fund([string]$addr, [string]$btc) { Rpc sendtoaddress "[`"$addr`",$btc]" '' miner }
# Waits until the mining node's mempool holds $txid (Kyoto hands a transaction to one random peer,
# which relays it on); returns the seconds it took, or -1.
function WaitPool([string]$txid, [int]$secs = 60) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $secs) { if ((Rpc getrawmempool) -contains $txid) { return [math]::Round(((Get-Date) - $t0).TotalSeconds, 1) }; Start-Sleep -Milliseconds 250 }
    return -1
}
function Rows([string]$history) { ((J $history).rows | ForEach-Object { "$($_.txid.Substring(0,8)) $($_.intent) $($_.state) fee $($_.feeSat)$(if ($_.replaces) { ' replaces ' + $_.replaces.Substring(0,8) })$(if ($_.replacedBy) { ' replacedBy ' + $_.replacedBy.Substring(0,8) })" }) -join '; ' }

# A fresh session and HOME; the daemon reads the module dirs from config.yaml.
function LayOut([string[]]$mods) {
    Remove-Item -Recurse -Force "$B\$RUN" -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force "$SESS\daemon", "$B\$RUN\home", $PDIR | Out-Null
    $env:HOME = "$B\$RUN\home"
    $env:USERPROFILE_ORIG = $env:USERPROFILE
    $lines = @('modules_dirs:') + ($mods | ForEach-Object { "  - $($B -replace '\\','/')/mods/$_/modules" }) + @('version: 2')
    $lines -join "`n" | Set-Content -Path "$SESS\daemon\config.yaml" -Encoding ascii
}

# The daemon, the keystore side configured, and the test phrase's wallet imported: sets $GROUP.
function KeystoreSide {
    Log "daemon start: $(Cut (Ctl daemon start --detach) 160)"
    Start-Sleep -Seconds 3
    foreach ($m in 'keystore_module', 'signer_manager_module', 'evm_keystore_cli', 'evm_signer_cli') { Log "load ${m}: $(Cut (Ctl module load $m --json) 200)" }
    Start-Sleep -Seconds 2
    Log "keystore configure: $(Cut (Call keystore_module configure (F 'ks.json' '{"approvers":["evm_signer_ui","evm_signer_cli"],"custodians":["evm_keystore_ui","evm_keystore_cli"],"managers":["signer_manager_module"]}')) 120)"
    Log "manager configure: $(Cut (Call signer_manager_module configure (F 'sm.json' '{"approvers":["evm_signer_ui","evm_signer_cli"],"custodians":["evm_keystore_ui","evm_keystore_cli"],"signers":["keystore_module"]}')) 120)"
    [IO.File]::WriteAllText("$PDIR\pw.txt", 'btc-pw')
    $imp = Call evm_keystore_cli import_bitcoin (F 'btc.json' '{"phrase":"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about","family":"bitcoin","chain":"test","password":"btc-pw","label":"Regtest wallet"}')
    $script:GROUP = (J $imp).group
    Log "imported: group $GROUP"
}

# Loads the core with `$regtest` as regtest.json and admits logosctl as the backend: sets $PERSIST.
function LoadCore([string]$regtest) {
    Log "load core: $(Cut (Ctl module load $CORE --json) 200)"
    Start-Sleep -Seconds 2
    $log = Get-ChildItem -Recurse -Filter core.log -Path "$SESS\data", "$B\$RUN\home" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match $CORE } | Select-Object -First 1
    $script:PERSIST = $log.DirectoryName
    Log "gate (logosctl is not the backend): $(Cut (Call $CORE descriptors) 160)"
    [IO.File]::WriteAllText("$PERSIST\regtest.json", $regtest)
    [IO.File]::WriteAllText("$PERSIST\callers.json", '{"modules":["bitcoin_wallet_backend"],"allowHost":true}')
    Ctl module unload $CORE | Out-Null; Start-Sleep -Seconds 1
    Log "reload core: $(Cut (Ctl module load $CORE --json) 200)"
    Start-Sleep -Seconds 1
}

# A job, waited for: returns job_result's reply.
function Job([string]$kind, [string]$json, [int]$secs = 120) {
    $r = J (Call $CORE start_job $kind (F "job-$kind.json" $json))
    if (-not $r.jobId) { return "start_job $kind refused: $r" }
    Until $secs { param($v) $v.state -in 'done', 'failed', 'cancelled' } @($CORE, 'job_status', $r.jobId, "str:$($r.receipt)") | Out-Null
    return (Call $CORE job_result $r.jobId "str:$($r.receipt)")
}

# Opens with the custodian approving in evm_keystore_cli; returns job_result's reply.
function OpenApproved([string]$params) {
    $r = J (Call $CORE start_job open_wallet (F 'open.json' $params))
    $st = Until 60 { param($v) $v.openHandle } @($CORE, 'status')
    $h = (J $st).openHandle
    $shown = J (Call evm_keystore_cli show_access $h)
    $d = @{ handle = $shown.handle; bundle_id = $shown.bundle_id; group = $GROUP; password = 'btc-pw' } | ConvertTo-Json -Compress
    $a = Call evm_keystore_cli approve_access (F 'decision.json' $d)
    if ($a -notmatch '"ok"\s*:\s*true' -and $a -notmatch 'approved') { Log "approve_access: $(Cut $a 200)" }
    Until 120 { param($v) $v.state -in 'done', 'failed', 'cancelled' } @($CORE, 'job_status', $r.jobId, "str:$($r.receipt)") | Out-Null
    return (Call $CORE job_result $r.jobId "str:$($r.receipt)")
}

# Signs a preview through the approver (evm_signer_cli); returns job_result's reply.
function SignApproved([string]$previewId) {
    $r = J (Call $CORE start_job sign_and_broadcast (F 'sign.json' "{`"previewId`":`"$previewId`"}"))
    $st = Until 60 { param($v) $v.approvalHandle } @($CORE, 'status')
    $ah = (J $st).approvalHandle
    $rendered = Until 60 { param($v) $v.rendered -and $v.rendered.handle -eq $ah } @('evm_signer_cli', 'status')
    $bundle = (J $rendered).rendered.bundle_id
    $shown = J (Call evm_signer_cli show $ah)
    Log "signer shows: $(Cut $shown.text 300)"
    Log "approve: $(Cut (Call evm_signer_cli approve $ah "str:$bundle" "@$PDIR\pw.txt") 160)"
    Until 120 { param($v) $v.state -in 'done', 'failed', 'cancelled' } @($CORE, 'job_status', $r.jobId, "str:$($r.receipt)") | Out-Null
    return (Call $CORE job_result $r.jobId "str:$($r.receipt)")
}

function StopDaemon { Log "daemon stop: $(Cut (Ctl daemon stop) 120)" }
