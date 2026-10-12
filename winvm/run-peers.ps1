# The Kyoto peer book on Windows, as the wallet core's tools/e2e/peers.sh runs it on Linux and macOS:
# bitcoin_node_module with Kyoto direct on regtest and one own peer, a gossiping p2p_proxy.exe front
# for the chain host's follower. The core reports the peers it hears of; back on the book, Kyoto
# dials them and the core reports how each did; the node module keeps it in kyoto_peers_regtest.json.
$RUN = 'peers'
# Script blocks from the files' text: this machine's execution policy refuses .ps1 files.
$BW = if ($env:BTC_WIN_DIR) { $env:BTC_WIN_DIR } else { "$env:USERPROFILE\bw" }
. ([ScriptBlock]::Create([IO.File]::ReadAllText("$BW\lib.ps1")))
Set-Content -Path $OUT -Value "The Kyoto peer book on Windows, $(Get-Date -Format o)"
$NM = 'bitcoin_node_module'
$fronts = @()
# Returns the front's process: the caller keeps it (a script block has no script scope to add to).
function Front([string]$name, [string]$listen, [string]$upstream, [string]$mode) {
    [IO.File]::WriteAllText("$PDIR\mode-$name.json", $mode)
    Start-Process -FilePath "$B\tools\p2p_proxy.exe" -ArgumentList $listen, $upstream, "$PDIR\mode-$name.json" -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$PDIR\front-$name.out" -RedirectStandardError "$PDIR\front-$name.err"
}
function Lan([int]$port) { '{"host":"127.0.0.1","port":' + $port + ',"services":73,"age":60}' }

try {
    LayOut @('keystore', 'manager', 'kcli', 'scli', 'core', 'node')
    FreshChain
    $main, $null, $follower = FilterPeers
    # Good forwards to the main node; nothing listens on the refusing port.
    $GOOD = 19601; $GOSSIP = 19602; $REFUSING = 19603
    $fronts += Front good "127.0.0.1:$GOOD" $main '{"mode":"forward"}'
    $fronts += Front gossip "127.0.0.1:$GOSSIP" $follower ('{"mode":"gossip","services":64,"extra":[' + (Lan $GOOD) + ',' + (Lan $REFUSING) + ']}')
    Log "fronts $(($fronts | ForEach-Object { $_.Id }) -join ', '): good :$GOOD -> $main, gossip :$GOSSIP -> $follower, refusing :$REFUSING"
    KeystoreSide
    Log "load node module: $(Cut (Ctl module load $NM --json) 160)"
    Start-Sleep -Seconds 2
    $nd = (Get-ChildItem -Directory "$SESS\data\$NM" | Select-Object -First 1).FullName
    [IO.File]::WriteAllText("$nd\regtest.json", '{}')
    [IO.File]::WriteAllText("$nd\callers.json", '{"modules":[],"allowHost":true}')
    Ctl module unload $NM | Out-Null; Start-Sleep -Seconds 1
    Log "reload node module: $(Cut (Ctl module load $NM --json) 160)"
    Start-Sleep -Seconds 1
    Log "init_defaults: $(Cut (Call $NM init_defaults) 120)"
    Log "kyoto direct: $(Cut (Call $NM set_source regtest kyoto (F 'kyoto.json' '{"tor":false}')) 160)"
    Log "own peer, the gossiping front: $(Cut (Call $NM set_own_peers regtest (F 'own.json' ('["127.0.0.1:' + $GOSSIP + '"]'))) 160)"

    # The core, quorum 1, its regtest.json naming no peer: Kyoto's come from the node module.
    LoadCore '{"pollSecs":1,"kyotoRequired":1}'
    Log "OPEN: $(Cut (OpenApproved '{"network":"regtest","family":"bitcoin"}') 200)"
    Log "synced: $(Cut (Until 180 { param($v) $v.synced -eq $true -and $v.authority.kind -eq 'kyoto' } @($CORE, 'status')) 160)"
    $l = J (Until 120 { param($v) $v.counts.learned -ge 2 } @($NM, 'peer_list', 'regtest'))
    Log "LEARNED: $($l.counts | ConvertTo-Json -Compress)"

    # Back to the book: Kyoto dials what it learned, and the core reports how each did.
    Log "own peers cleared: $(Cut (Call $NM set_own_peers regtest (F 'none.json' '[]')) 160)"
    # The own peer's front goes down, so Kyoto starts again on the book.
    [IO.File]::WriteAllText("$PDIR\mode-gossip.json", '{"mode":"down"}')
    $rt = J (Until 240 { param($v) @($v.peers | Where-Object { $_.peer -eq "127.0.0.1:$GOOD" -and $_.ok -eq $true }).Count -eq 1 } @($NM, 'route_table', 'regtest'))
    Log "ROUTE peers: $($rt.peers | ConvertTo-Json -Compress)"
    Log "close: $(Cut (Job close_wallet '{}') 100)"
    Start-Sleep -Seconds 2
    $book = "$nd\kyoto_peers_regtest.json"
    Log "BOOK: $(if (Test-Path $book) { Cut ([IO.File]::ReadAllText($book)) 1500 } else { 'MISSING' })"
    Log "reports: $((Get-Content "$PERSIST\core.log" | Select-String 'kyoto: reported' | ForEach-Object { $_.Line.Substring(28) }) -join ' | ')"
} catch {
    Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    foreach ($p in $fronts) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    StopDaemon
    Log 'END'
}
