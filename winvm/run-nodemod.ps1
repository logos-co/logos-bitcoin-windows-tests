# bitcoin_node_module on Windows under logosctl: defaults, the signed peer list verified, routes,
# a server of your own on the LAN (the chain host's electrs) probed directly, then an unload.
$RUN = 'nodemod'
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "bitcoin_node_module on Windows, $(Get-Date -Format o)"
$NM = 'bitcoin_node_module'

try {
    LayOut @('node')
    Log "daemon start: $(Cut (Ctl daemon start --detach) 120)"
    Start-Sleep -Seconds 3
    Log "load: $(Cut (Ctl module load $NM --json) 160)"
    $INST = (Get-ChildItem -Directory "$SESS\data\$NM" | Select-Object -First 1).FullName
    [IO.File]::WriteAllText("$INST\regtest.json", '{}')
    [IO.File]::WriteAllText("$INST\callers.json", '{"modules":["bitcoin_wallet_backend"],"allowHost":true}')
    Ctl module unload $NM | Out-Null
    Log "reload: $(Cut (Ctl module load $NM --json) 160)"
    Log "list_networks: $(Cut (Call $NM list_networks) 200)"
    Log "init_defaults: $(Cut (Call $NM init_defaults) 160)"
    Log "get_sources mainnet: $(Cut (Call $NM get_sources mainnet) 300)"
    $pl = J (Call $NM peer_list mainnet)
    Log "peer_list mainnet: $(Cut ($pl | ConvertTo-Json -Compress -Depth 3) 300)"
    $rt = J (Call $NM route_table signet)
    Log "route_table signet: proxy $($rt.proxy); kyoto peers $(@($rt.peers).Count); fees $(Cut (($rt.fees | ConvertTo-Json -Compress -Depth 4)) 200)"
    $byName = if ($FWNAME) { (ElectrumUrls)[0] -replace [regex]::Escape($FW), $FWNAME } else { (ElectrumUrls)[0] }
    $own = "[{`"id`":`"fw`",`"kind`":`"electrum`",`"url`":`"$byName`",`"use`":true,`"history`":true,`"tor`":false}]"
    Log "set_sources regtest (own LAN server): $(Cut (Call $NM set_sources regtest (F 'own.json' $own)) 400)"
    Log "set_sources regtest (a public host in plain text, refused): $(Cut (Call $NM set_sources regtest (F 'pub.json' '[{"id":"pub","kind":"electrum","url":"tcp://electrum.blockstream.info:50001","use":true,"history":false,"tor":false}]')) 200)"
    $t0 = Get-Date
    Log "probe fw: $(Cut (Call $NM probe regtest fw) 400) in $([int]((Get-Date) - $t0).TotalMilliseconds) ms"
    Log "route_table regtest: $(Cut (Call $NM route_table regtest) 400)"
    $ms = Ms { $script:u = Ctl module unload $NM --json }
    Log "UNLOAD: $(Cut $u 120) in $ms ms"
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    StopDaemon
    Log 'END'
}
