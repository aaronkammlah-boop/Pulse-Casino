# Pulse: now playing + Steam games + app usage, served to a local page opened in Edge app mode.
param([int]$Port = 5577, [switch]$NoWindow)  # -NoWindow: Pulse.exe starting with Windows, stay in the tray
$ErrorActionPreference = 'Stop'
$usageFile = Join-Path $PSScriptRoot 'usage.json'
$namesFile = Join-Path $PSScriptRoot 'names.json'
$modesFile = Join-Path $PSScriptRoot 'modes.json'
$songsFile = Join-Path $PSScriptRoot 'songs.json'
$appsFile = Join-Path $PSScriptRoot 'apps.json'
$dealsSeenFile = Join-Path $PSScriptRoot 'deals-seen.json'
$bansFile = Join-Path $PSScriptRoot 'bans.json'
$dailyFile = Join-Path $PSScriptRoot 'daily.json'              # date -> app -> seconds, for the heatmap
$soundtrackFile = Join-Path $PSScriptRoot 'soundtracks.json'   # appid -> "title|artist" -> seconds heard while playing it
$bingoFile = Join-Path $PSScriptRoot 'bingo.json'
$contractFile = Join-Path $PSScriptRoot 'contract.json'
$trophyFile = Join-Path $PSScriptRoot 'trophies.json'
$pricesFile = Join-Path $PSScriptRoot 'prices.json'            # appid -> lowest price + daily prices, for the best-price badges
$watchFile = Join-Path $PSScriptRoot 'watch.json'
$settingsFile = Join-Path $PSScriptRoot 'settings.json'
$storeFile = Join-Path $PSScriptRoot 'store.json'              # backup of the page's own saved data (chips, perks, streaks), so any window gets it back
$inboxFile = Join-Path $PSScriptRoot 'inbox.json'              # the last 100 notifications, for the page's bell
$popsFile = Join-Path $PSScriptRoot 'pops.json'                # achievements already announced live

# what a Pulse backup holds (Settings > Backup); youtube.json is left out on purpose: it holds your Google sign-in
$backupFiles = [ordered]@{ usage = $usageFile; daily = $dailyFile; songs = $songsFile; soundtracks = $soundtrackFile; bans = $bansFile; bingo = $bingoFile
  contract = $contractFile; trophies = $trophyFile; watch = $watchFile; settings = $settingsFile; store = $storeFile; inbox = $inboxFile; pops = $popsFile }
# a restore is written as <file>.restore and swapped in here, before anything is loaded, so the running copy can't save over it
foreach ($f in $backupFiles.Values) { if (Test-Path "$f.restore") { Move-Item "$f.restore" $f -Force } }
$steam = (Get-ItemProperty HKCU:\Software\Valve\Steam -ErrorAction SilentlyContinue).SteamPath

function Read-JsonFile([string]$path) {
  # a file cut off mid-save (PC shut down while writing) must not stop Pulse: move it aside, log it, and start that data fresh
  if (-not (Test-Path $path)) { return $null }
  $raw = [IO.File]::ReadAllText($path)
  if ($raw.Trim([char]0, ' ', "`r", "`n", "`t")) { try { return ConvertFrom-Json $raw } catch {} }
  $bad = "$path.broken-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Move-Item $path $bad -Force
  Add-Content (Join-Path $PSScriptRoot 'pulse.log') "$(Get-Date -Format s) $([IO.Path]::GetFileName($path)) was unreadable (cut off mid-save?); kept it as $([IO.Path]::GetFileName($bad)) and started fresh"
  $null
}
function Read-JsonHash([string]$path) {
  $h = @{}
  $o = Read-JsonFile $path
  if ($o) { $o.psobject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
  $h
}
function ConvertTo-Hash($o) { $h = @{}; if ($o) { $o.psobject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }; $h }
function Save-Json($value, [string]$path, [int]$depth = 6) {
  # write a temp file, force it onto the disk, then swap it in: a crash mid-save leaves the old file instead of a blank one
  $bytes = (New-Object Text.UTF8Encoding $true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Depth $depth -Compress))
  $tmp = "$path.tmp"
  $fs = [IO.File]::Create($tmp)
  try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
  # [NullString]::Value, not $null: PowerShell turns $null into "" for a string argument, which Replace rejects
  if (Test-Path $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}
function Read-Body($ctx) {
  # every legit body is tiny; refuse big or unsized ones before reading them into memory
  if ($ctx.Request.ContentLength64 -lt 0 -or $ctx.Request.ContentLength64 -gt 65536) { throw "request body too large ($($ctx.Request.ContentLength64) bytes)" }
  (New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
}
function Read-SteamXml([string]$text) {
  # Steam's XML, parsed with DTDs refused: no entity tricks even if the response were tampered with
  $s = New-Object Xml.XmlReaderSettings; $s.DtdProcessing = 'Prohibit'; $s.XmlResolver = $null
  $doc = New-Object Xml.XmlDocument; $doc.XmlResolver = $null
  $doc.Load([Xml.XmlReader]::Create((New-Object IO.StringReader $text), $s)); $doc
}

# --- settings (the Settings page edits these) ---
$settings = @{ currency = '$'; salesMinutes = 30; volume = 0.6; notifyDeals = $true; notifyFree = $true; notifyPrice = $true; notifyJackpot = $true; notifySession = $true }
(Read-JsonHash $settingsFile).GetEnumerator() | Where-Object { $settings.ContainsKey($_.Key) } | ForEach-Object { $settings[$_.Key] = $_.Value }
function Set-Settings($body) {
  # trust boundary: only known keys, each clamped to a sane type/range
  foreach ($p in $body.psobject.Properties) {
    switch ($p.Name) {
      'currency' { $c = "$($p.Value)" -replace '[<>"&]', ''; $settings.currency = $c.Substring(0, [Math]::Min(3, $c.Length)) }
      'salesMinutes' { $settings.salesMinutes = [Math]::Max(10, [Math]::Min(1440, [int]$p.Value)) }
      'volume' { $settings.volume = [Math]::Max(0.0, [Math]::Min(1.0, [double]$p.Value)) }  # 0.0/1.0, not 0/1: integer literals make Max round to a whole number
      { $_ -like 'notify*' -and $settings.ContainsKey($_) } { $settings[$p.Name] = [bool]$p.Value }
    }
  }
  Save-Json $settings $settingsFile
}

# --- Windows notifications (shown under PowerShell's name, since Pulse runs its engine) ---
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
function Show-Toast([string]$kind, [string]$title, [string]$body) {
  if (-not $settings["notify$kind"]) { return }
  try {
    $x = New-Object Windows.Data.Xml.Dom.XmlDocument
    $e = { param($s) [Security.SecurityElement]::Escape($s) }
    $x.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$(& $e $title)</text><text>$(& $e $body)</text></binding></visual></toast>")
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new($x))
  } catch {}  # notifications are a nicety; never let them break the server
}

# --- Steam ---------------------------------------------------------------

# one VDF entry: "key" "value", or "key" { ... } nested to any depth (balancing groups; braces inside quoted strings don't count)
$vdfItem = '\s*"(?:[^"\\]|\\.)*"\s*(?:"(?:[^"\\]|\\.)*"|\{(?>"(?:[^"\\]|\\.)*"|[^{}"]+|\{(?<d>)|\}(?<-d>))*(?(d)(?!))\})'
function Read-SteamPlaytime([string]$vdf, [string]$key = 'Playtime') {
  # an app's block can hold nested blocks (cloud, autocloud...) before $key; on some accounts every game does
  $h = @{}
  foreach ($m in [regex]::Matches($vdf, '"(\d+)"\s*\{(?:' + $vdfItem + ')*?\s*"' + $key + '"\s*"(\d+)"')) {
    $h[$m.Groups[1].Value] = [int64]$m.Groups[2].Value
  }
  $h
}

function Read-Achievements([string]$json) {
  $a = (ConvertFrom-Json $json) | Where-Object { $_[0] -eq 'achievements' } | Select-Object -First 1
  if (-not $a -or -not $a[1].data.nTotal) { return $null }
  $d = $a[1].data
  @{
    got = $d.nAchieved; total = $d.nTotal
    recent = @($d.vecHighlight | Where-Object bAchieved | Sort-Object rtUnlocked -Descending | Select-Object -First 5 |
      ForEach-Object { @{ name = $_.strName; desc = $_.strDescription; img = $_.strImage } })
  }
}

function Get-SteamLibs {
  [regex]::Matches("$(Get-Content "$steam/steamapps/libraryfolders.vdf" -Raw -ErrorAction SilentlyContinue)", '"path"\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } |
    Where-Object { Test-Path -LiteralPath $_ }  # Steam keeps listing libraries on unplugged drives; Join-Path on a missing drive letter throws
}

$bans = New-Object 'Collections.Generic.HashSet[string]'  # house rules: games taken off the roulette
if (Test-Path $bansFile) { foreach ($b in (Read-JsonFile $bansFile)) { [void]$bans.Add($b) } }
$modes = Read-JsonHash $modesFile
function Get-GameModes([string]$id) {
  # Steam keeps store categories only online; look each game up once and cache it in modes.json
  if (-not $modes[$id]) {
    try { $cats = @((Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$id&filters=categories" -TimeoutSec 5).$id.data.categories.id) }
    catch { return [pscustomobject]@{ single = $true; multi = $true } }  # offline: put it on both tables, retry next time
    $multi = @($cats | Where-Object { $_ -in 1, 9, 24, 27, 36, 37, 38, 39, 47, 48, 49 }).Count -gt 0  # multi-player, co-op, PvP, split screen, LAN
    $modes[$id] = [pscustomobject]@{ single = ($cats -contains 2) -or -not $multi; multi = $multi }
  }
  $modes[$id]
}

function Get-InstalledGames {
  if (-not $steam) { return @() }
  $known = $modes.Count
  $games = @(Get-SteamLibs | ForEach-Object { Get-ChildItem (Join-Path $_ 'steamapps/appmanifest_*.acf') -ErrorAction SilentlyContinue } | ForEach-Object {
    $t = Get-Content $_.FullName -Raw -Encoding UTF8
    if ($t -match '"appid"\s*"(\d+)"') { $id = $Matches[1]; if ($t -match '"name"\s*"([^"]+)"') { @{ id = $id; name = $Matches[1] } } }
  } | Where-Object { $_.name -notmatch 'Redistributable|Steamworks|Proton|Steam Linux Runtime|SteamVR|Wallpaper Engine' } | Sort-Object { $_.name })
  $cfg = Get-SteamConfig
  $last = if ($cfg) { Read-SteamPlaytime (Get-Content $cfg.FullName -Raw -Encoding UTF8) 'LastPlayed' } else { @{} }
  foreach ($g in $games) { $m = Get-GameModes $g.id; $g.single = $m.single; $g.multi = $m.multi; $g.banned = $bans.Contains($g.id); $g.lastPlayed = [int64]$last[$g.id] }
  if ($modes.Count -ne $known) { Save-Json $modes $modesFile }
  $games
}

$names = Read-JsonHash $namesFile
function Get-GameName([string]$id) {
  if (-not $names[$id] -and $steam) {
    # installed games: name from appmanifest; otherwise ask the Steam store once and cache it
    foreach ($lib in Get-SteamLibs) {
      $acf = Join-Path $lib "steamapps/appmanifest_$id.acf"
      if ((Test-Path $acf) -and ((Get-Content $acf -Raw -Encoding UTF8) -match '"name"\s*"([^"]+)"')) { $names[$id] = $Matches[1] }  # UTF8: or "Overwatch®" reads as "OverwatchÂ®"
    }
    if (-not $names[$id]) {
      try { $names[$id] = (Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$id&filters=basic" -TimeoutSec 5).$id.data.name } catch {}
    }
    if ($names[$id]) { Save-Json $names $namesFile }
  }
  if ($names[$id]) { $names[$id] } else { "App $id" }
}

function Read-PrivateApps([string]$vdf, [string]$account) {
  # games you set to Private in Steam (kept off your profile); Steam stores them in localconfig as "PrivateApps_<account>" "[id,id,...]"
  if ($vdf -match ('"PrivateApps_' + $account + '"\s*"\[([^\]]*)\]"')) { @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
}

function Get-SteamConfig {
  # the most recently written localconfig is the account that's signed in
  if ($steam) { Get-ChildItem "$steam/userdata/*/config/localconfig.vdf" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
}

function Get-SteamStats {
  # top 40 played games are the Higher-or-Lower deck; the first 12 are also the lobby cards
  $cfg = Get-SteamConfig
  if (-not $cfg) { return @{ games = @(); deck = @() } }
  $vdf = Get-Content $cfg.FullName -Raw -Encoding UTF8
  $play = Read-SteamPlaytime $vdf
  foreach ($id in Read-PrivateApps $vdf $cfg.Directory.Parent.Name) { $play.Remove($id) }
  $cache = Join-Path $cfg.DirectoryName 'librarycache'
  $deck = @($play.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 40 | ForEach-Object { @{ id = $_.Key; name = (Get-GameName $_.Key); minutes = $_.Value } })
  $games = @($deck | Select-Object -First 12 | ForEach-Object {
    $g = $_; $f = Join-Path $cache "$($g.id).json"
    # one unreadable cache file (PowerShell 5's JSON reader chokes on huge files and on keys differing only in case) loses that game's achievements, not the whole list
    $ach = if (Test-Path $f) { try { Read-Achievements (Get-Content $f -Raw -Encoding UTF8) } catch { Write-Warning "achievements for $($g.id) unreadable: $($_.Exception.Message)" } }
    @{ id = $g.id; name = $g.name; minutes = $g.minutes; ach = $ach }
  })
  @{ games = $games; deck = $deck }
}

$appInfo = Read-JsonHash $appsFile  # id -> { name, type, desc, header } from the Steam store, so we only ask once
function Get-AppInfo([string]$id) {
  if (-not $appInfo[$id] -or -not $appInfo[$id].psobject.Properties['desc']) {  # entries cached before descriptions existed get refreshed once
    try { $d = (Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$id&filters=basic&l=english" -TimeoutSec 5).$id } catch { return $null }  # offline: ask again next time
    $appInfo[$id] = [pscustomobject]@{ name = $d.data.name; type = $(if ($d.success) { $d.data.type } else { 'gone' })
      desc = [Net.WebUtility]::HtmlDecode("$($d.data.short_description)"); header = $d.data.header_image }  # header_image is the exact banner URL; newer games have no standard one
    Save-Json $appInfo $appsFile
  }
  $appInfo[$id]
}

# Steam keeps a librarycache/<appid>.json for every app in your library, so its file names are your owned list
function Get-LibraryIds($cfg) { @(Get-ChildItem (Join-Path $cfg.DirectoryName 'librarycache') -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object BaseName | Where-Object { $_ -match '^\d+$' }) }

function Get-ScratchCard {
  # three random games you own but haven't installed (skipping soundtracks, tools and delisted apps)
  $cfg = Get-SteamConfig
  if (-not $cfg) { return @{ owned = 0; cards = @() } }
  $installed = @(Get-SteamLibs | ForEach-Object { Get-ChildItem (Join-Path $_ 'steamapps/appmanifest_*.acf') -ErrorAction SilentlyContinue } | ForEach-Object { $_.BaseName -replace '^appmanifest_' })
  $vdf = Get-Content $cfg.FullName -Raw -Encoding UTF8
  $play = Read-SteamPlaytime $vdf; $last = Read-SteamPlaytime $vdf 'LastPlayed'
  $pool = @(Get-LibraryIds $cfg | Where-Object { $installed -notcontains $_ } | Sort-Object { Get-Random })
  $cards = @()
  foreach ($id in $pool) {
    $i = Get-AppInfo $id
    if ($i -and $i.type -eq 'game') { $cards += @{ id = $id; name = $i.name; minutes = [int64]$play[$id]; lastPlayed = [int64]$last[$id] } }
    if ($cards.Count -eq 3) { break }
  }
  @{ owned = $pool.Count; cards = $cards }
}

function Read-SalesPage([string]$html) {
  # one page of Steam's store search results (HTML) -> discounted single games
  foreach ($row in ($html -split '<a href=' | Select-Object -Skip 1)) {
    # bundles/packages carry a package or bundle id (or a comma list of apps): skip them, keep single games
    if ($row -match 'data-ds-(packageid|bundleid)=' -or $row -notmatch 'data-ds-appid="(\d+)"') { continue }
    $id = $Matches[1]
    $pick = { param($re) if ($row -match $re) { [Net.WebUtility]::HtmlDecode($Matches[1].Trim()) } }
    $pct = [int](& $pick 'data-discount="(\d+)"')
    if (-not $pct) { continue }
    $cents = [int](& $pick 'data-price-final="(\d+)"')  # sale price, for the price filter
    [pscustomobject]@{ id = $id; name = (& $pick '<span class="title">(.*?)</span>'); pct = $pct; cents = $cents; free = ($pct -eq 100 -and $cents -eq 0)  # 100% off = free to keep
      was = (& $pick 'discount_original_price">([^<]+)<'); now = (& $pick 'discount_final_price">([^<]+)<')
      review = (& $pick 'search_review_summary[^"]*" data-tooltip-html="([^&"]+)'); released = (& $pick 'search_released[^>]*>([^<]*)<')
      img = (& $pick 'search_capsule"><img src="([^"]+)"') }  # small, but always there; newer games have no standard header.jpg
  }
}

function Get-DealDropTime([datetime]$now = (Get-Date)) {
  # Steam's daily deals switch at 10:00 Pacific; 10:05 gives the store a moment to settle. Returns the latest one at or before $now, in local time (DST-aware).
  $pt = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
  $nowPt = [TimeZoneInfo]::ConvertTime($now, $pt)
  $drop = $nowPt.Date.AddHours(10).AddMinutes(5)
  if ($nowPt -lt $drop) { $drop = $drop.AddDays(-1) }
  [TimeZoneInfo]::ConvertTime($drop, $pt, [TimeZoneInfo]::Local)
}

function Add-WishlistDeals($items, $cfg, $owned) {
  # flags deals on your Steam wishlist, and adds wishlist games on sale that weren't in the top ~600
  if (-not $cfg) { return $items }
  try { $wish = @((Invoke-RestMethod "https://api.steampowered.com/IWishlistService/GetWishlist/v1/?steamid=$(Get-SteamId $cfg)" -TimeoutSec 10).response.items | ForEach-Object { "$($_.appid)" }) } catch { return $items }
  foreach ($i in $items) { $i | Add-Member wish ($wish -contains $i.id) -Force }
  $missing = @($wish | Where-Object { $_ -notin $items.id -and $owned -notcontains $_ })
  for ($k = 0; $k -lt $missing.Count; $k += 50) {
    $chunk = $missing[$k..([Math]::Min($k + 49, $missing.Count - 1))]
    try { $r = Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$($chunk -join ',')&filters=price_overview" -TimeoutSec 15 } catch { continue }
    foreach ($id in $chunk) {
      $po = $r.$id.data.price_overview
      if (-not $po -or -not $po.discount_percent) { continue }
      $info = Get-AppInfo $id
      $items += [pscustomobject]@{ id = $id; name = $info.name; pct = [int]$po.discount_percent; cents = [int]$po.final; free = ([int]$po.final -eq 0)
        was = $po.initial_formatted; now = $po.final_formatted; review = $null; released = $null; img = $info.header; wish = $true }
    }
  }
  $items
}

$prices = Read-JsonHash $pricesFile; foreach ($k in @($prices.Keys)) { $prices[$k] = ConvertTo-Hash $prices[$k] }
function Add-PriceHistory($items) {
  # keeps each deal's lowest price per day (60 days), then badges: a new lowest price, or "was cheaper last week"
  $today = (Get-Date).ToString('yyyy-MM-dd'); $weekAgo = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd'); $cut = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')
  foreach ($i in $items) {
    if (-not $prices[$i.id]) { $prices[$i.id] = @{} }
    $h = $prices[$i.id]
    $before = @($h.GetEnumerator() | Where-Object { $_.Key -lt $today } | ForEach-Object { [int]$_.Value })
    $lastWeek = @($h.GetEnumerator() | Where-Object { $_.Key -lt $today -and $_.Key -ge $weekAgo } | ForEach-Object { [int]$_.Value })
    $h[$today] = if ($h.ContainsKey($today)) { [Math]::Min([int]$h[$today], $i.cents) } else { $i.cents }
    $i | Add-Member lowest ($before.Count -gt 0 -and $i.cents -lt ($before | Measure-Object -Minimum).Minimum) -Force
    $i | Add-Member cheaperWeek $(if ($lastWeek.Count -and ($lastWeek | Measure-Object -Minimum).Minimum -lt $i.cents) { [int]($lastWeek | Measure-Object -Minimum).Minimum }) -Force
  }
  foreach ($id in @($prices.Keys)) {
    foreach ($d in @($prices[$id].Keys)) { if ($d -lt $cut) { $prices[$id].Remove($d) } }
    if (-not $prices[$id].Count) { $prices.Remove($id) }
  }
  Save-Json $prices $pricesFile 3
}

$sales = @{ at = [datetime]::MinValue; tried = [datetime]::MinValue; items = @(); job = $null }
function Get-Sales {
  # ~600 games from Steam's live sale search (prices in your region's currency), minus bundles and games you own.
  # Downloading 6 pages takes a few seconds, so a background job fetches them and we parse once it's done.
  # Refreshed every 30 min and right after each 10:05 AM PT deal drop; the server loop calls this every minute so it happens with no window open.
  if ($sales.job -and $sales.job.State -ne 'Running') {
    $pages = @(Receive-Job $sales.job -ErrorAction SilentlyContinue); Remove-Job $sales.job -Force; $sales.job = $null
    $cfg = Get-SteamConfig
    $owned = if ($cfg) { Get-LibraryIds $cfg } else { @() }
    $dupe = @{}
    $items = @($pages | ForEach-Object { Read-SalesPage $_ } | Where-Object { -not $dupe[$_.id] -and $owned -notcontains $_.id } | ForEach-Object { $dupe[$_.id] = 1; $_ })
    if ($items.Count) {  # a failed fetch keeps the last list
      $items = Add-WishlistDeals $items $cfg $owned
      Add-PriceHistory $items
      # remember when each deal first appeared; ones first seen since today's drop are "new". Deals that ended simply aren't in the new list.
      $first = -not (Test-Path $dealsSeenFile)
      $old = Read-JsonHash $dealsSeenFile
      $seenAt = @{}; $now = [DateTimeOffset]::Now.ToUnixTimeSeconds(); $drop = ([DateTimeOffset](Get-DealDropTime)).ToUnixTimeSeconds()
      foreach ($i in $items) {
        $t = if ($old.ContainsKey($i.id)) { [int64]$old[$i.id] } elseif ($first) { 0 } else { $now }  # very first run: nothing counts as new (stored as 0)
        $seenAt[$i.id] = $t
        $i | Add-Member -NotePropertyName new -NotePropertyValue ($t -ge $drop) -Force
        if ($i.free -and $t -eq $now) { Show-Toast 'Free' 'Free to keep on Steam!' "$($i.name) is free right now. Grab it before the promo ends." }
      }
      Save-Json $seenAt $dealsSeenFile
      # the first refresh after the 10 AM PT drop announces how many deals are new (not on Pulse's first-ever run)
      $fresh = @($items | Where-Object new).Count
      if (-not $first -and $sales.at -lt (Get-DealDropTime) -and $sales.items.Count -and $fresh) { Show-Toast 'Deals' "$fresh new Steam deals" 'Today''s deals just dropped. They''re waiting in the Spotlight.' }
      # free games first, then wishlist deals, then Steam's order
      $sales.items = @($items | Where-Object free) + @($items | Where-Object { -not $_.free -and $_.wish }) + @($items | Where-Object { -not $_.free -and -not $_.wish })
      $sales.at = Get-Date
    }
  }
  $stale = ((Get-Date) - $sales.at).TotalMinutes -gt $settings.salesMinutes -or $sales.at -lt (Get-DealDropTime)
  if (-not $sales.job -and $stale -and ((Get-Date) - $sales.tried).TotalMinutes -gt 2) {
    $sales.tried = Get-Date
    $sales.job = Start-Job {
      # page 1: games that are 100% off (free to keep); then ~600 discounted games
      try { (Invoke-RestMethod 'https://store.steampowered.com/search/results/?maxprice=free&specials=1&category1=998&infinite=1&count=50&l=english' -TimeoutSec 20).results_html } catch {}
      foreach ($start in 0, 100, 200, 300, 400, 500) {
        try { (Invoke-RestMethod "https://store.steampowered.com/search/results/?specials=1&category1=998&infinite=1&start=$start&count=100&l=english" -TimeoutSec 20).results_html } catch {}
      }
    }
  }
  @{ loading = ($null -ne $sales.job) -and -not $sales.items.Count; items = $sales.items
     updated = $(if ($sales.items.Count) { $sales.at.ToString('o') }); nextDrop = (Get-DealDropTime).AddDays(1).ToString('o') }
}

function Get-GameDetails([string]$id) {
  $cfg = Get-SteamConfig
  if (-not $cfg) { return $null }
  $info = @{}
  # the app's own block (the one holding Playtime), not other sections that reuse the id as a key; only its top-level pairs, not nested ones
  $block = [regex]::Matches((Get-Content $cfg.FullName -Raw -Encoding UTF8), '"' + $id + '"\s*\{((?:' + $vdfItem + ')*)') | Where-Object { $_.Groups[1].Value -match '"Playtime"' } | Select-Object -First 1
  if ($block) { [regex]::Matches($block.Groups[1].Value, $vdfItem) | ForEach-Object { if ($_.Value -match '^\s*"([^"]*)"\s*"([^"]*)"$') { $info[$Matches[1]] = $Matches[2] } } }

  $pct = @{}
  try { (Invoke-RestMethod "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v0002/?gameid=$id" -TimeoutSec 5).achievementpercentages.achievements | ForEach-Object { $pct[$_.name] = [double]$_.percent } } catch {}

  # full list from the public community profile; falls back to the local preview (≤12 unlocked + 12 locked) if private/offline
  $partial = $false
  $ach = @(try {
    $sid = 76561197960265728 + [int64]$cfg.Directory.Parent.Name
    $x = Read-SteamXml (Invoke-WebRequest "https://steamcommunity.com/profiles/$sid/stats/$id/?xml=1" -UseBasicParsing -TimeoutSec 8).Content
    $x.playerstats.achievements.achievement | ForEach-Object {
      $got = $_.GetAttribute('closed') -eq '1'
      @{ name = $_['name'].InnerText; desc = $_['description'].InnerText; got = $got; pct = $pct[$_['apiname'].InnerText]
         img = $(if ($got) { $_['iconClosed'].InnerText } else { $_['iconOpen'].InnerText })
         at = $(if ($_['unlockTimestamp']) { [int64]$_['unlockTimestamp'].InnerText } else { 0 }) }
    }
  } catch {})
  if (-not $ach.Count) {
    $f = Join-Path $cfg.DirectoryName "librarycache/$id.json"
    $a = if (Test-Path $f) { (ConvertFrom-Json (Get-Content $f -Raw -Encoding UTF8)) | Where-Object { $_[0] -eq 'achievements' } | Select-Object -First 1 }
    if ($a) {
      $partial = $true
      $ach = @(@($a[1].data.vecHighlight) + @($a[1].data.vecUnachieved) | Where-Object { $_ } | ForEach-Object {
        @{ name = $_.strName; desc = $_.strDescription; got = [bool]$_.bAchieved; pct = $_.flAchieved; img = $_.strImage; at = [int64]$_.rtUnlocked } })
    }
  }
  $st = $soundtracks[$id]
  $soundtrack = @(if ($st) { $st.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { $t, $a = $_.Key -split '\|', 2; @{ title = $t; artist = $a; seconds = [int]$_.Value } } })
  @{ id = $id; name = (Get-GameName $id); minutes = [int]$info['Playtime']; twoWeeks = [int]$info['Playtime2wks']; lastPlayed = [int64]$info['LastPlayed']
     achievements = $ach; partial = $partial; soundtrack = $soundtrack }
}

function Get-SteamId($cfg) { 76561197960265728 + [int64]$cfg.Directory.Parent.Name }

function Read-LibraryAchievements([string]$file) {
  # the achievements block of a librarycache file: counts plus up to 12 locked ones with their global unlock %
  # unreadable file (see Get-SteamStats): that game just has no achievement details
  $a = try { (ConvertFrom-Json ([IO.File]::ReadAllText($file))) | Where-Object { $_[0] -eq 'achievements' } | Select-Object -First 1 } catch { Write-Warning "$file unreadable: $($_.Exception.Message)" }
  if ($a) { $a[1].data }
}

$chase = @{ at = [datetime]::MinValue; items = @() }
function Get-CompletionChase {
  # the started games closest to 100%, nearest first; reads ~500 small cache files, so the answer is kept for 10 minutes
  if (((Get-Date) - $chase.at).TotalMinutes -lt 10) { return $chase.items }
  $cfg = Get-SteamConfig
  if (-not $cfg) { return @() }
  $near = foreach ($f in Get-ChildItem (Join-Path $cfg.DirectoryName 'librarycache') -Filter *.json -ErrorAction SilentlyContinue) {
    if ([IO.File]::ReadAllText($f.FullName) -match '"nTotal":(\d+),"nAchieved":(\d+)') {
      $left = [int]$Matches[1] - [int]$Matches[2]
      # got >= 1: you've actually started it (0 of 1 isn't "almost done"); the nearest 12 are shown, 1-3 left get flagged on the page
      if ($left -ge 1 -and [int]$Matches[2] -ge 1) { [pscustomobject]@{ id = $f.BaseName; total = [int]$Matches[1]; got = [int]$Matches[2]; left = $left; file = $f.FullName } }
    }
  }
  $chase.items = @($near | Sort-Object left, @{ e = 'total'; Descending = $true } | Select-Object -First 12 | ForEach-Object {
    $d = Read-LibraryAchievements $_.file
    @{ id = $_.id; name = (Get-GameName $_.id); got = $_.got; total = $_.total; left = $_.left
       missing = @($d.vecUnachieved | Select-Object -First 3 | ForEach-Object { @{ name = $_.strName; desc = $_.strDescription; img = $_.strImage; pct = $_.flAchieved } }) }
  })
  $chase.at = Get-Date
  $chase.items
}

function Get-Contract([switch]$Check) {
  # today's achievement contract: one of the 15 easiest locked achievements (most players have it) in games you've played, a new one each day
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $c = Read-JsonFile $contractFile
  $cfg = Get-SteamConfig
  if (-not $cfg) { return $null }
  if (-not $c -or $c.date -ne $today) {
    $played = Read-SteamPlaytime (Get-Content $cfg.FullName -Raw -Encoding UTF8)
    $cands = foreach ($id in $played.Keys) {
      $f = Join-Path $cfg.DirectoryName "librarycache/$id.json"
      if ((Test-Path $f) -and [IO.File]::ReadAllText($f) -match '"vecUnachieved":\[\{') {
        foreach ($u in (Read-LibraryAchievements $f).vecUnachieved) { [pscustomobject]@{ id = $id; apiname = $u.strID; name = $u.strName; desc = $u.strDescription; img = $u.strImage; pct = [double]$u.flAchieved } }
      }
    }
    $top = @($cands | Sort-Object pct -Descending | Select-Object -First 15)
    if (-not $top.Count) { return $null }
    $pick = $top[(Get-Date).DayOfYear % $top.Count]
    $c = [pscustomobject]@{ date = $today; id = $pick.id; game = (Get-GameName $pick.id); apiname = $pick.apiname; name = $pick.name; desc = $pick.desc; img = $pick.img
      pct = [Math]::Round($pick.pct, 1); reward = 150 + [int]((100 - $pick.pct) * 5); done = $false; claimed = $false; checkedAt = '' }
    Save-Json $c $contractFile
  }
  if ($Check -and -not $c.done) {
    # verified against your public Steam profile, the same source as the game stats popup
    try {
      $x = Read-SteamXml (Invoke-WebRequest "https://steamcommunity.com/profiles/$(Get-SteamId $cfg)/stats/$($c.id)/?xml=1" -UseBasicParsing -TimeoutSec 8).Content
      $hit = $x.playerstats.achievements.achievement | Where-Object { $_['apiname'].InnerText -eq $c.apiname -and $_.GetAttribute('closed') -eq '1' }
      if ($hit) { $c.done = $true; Show-Toast 'Jackpot' 'Contract complete!' "$($c.name) in $($c.game): open Pulse to collect $($c.reward) chips." }
    } catch {}
    $c.checkedAt = (Get-Date).ToString('o')
    Save-Json $c $contractFile
  }
  $c
}

# --- trophy room: every achievement you've unlocked that under 10% of players have ---
$trophies = @{ job = $null; at = [datetime]::MinValue; scanned = @{}; list = @() }
if ($t = Read-JsonFile $trophyFile) { $trophies.scanned = ConvertTo-Hash $t.scanned; $trophies.list = @($t.list) }
function Update-Trophies {
  # a background job checks each game you've unlocked achievements in (2 Steam requests per game, spaced out), then only games played since their last check
  if ($trophies.job -and $trophies.job.State -ne 'Running') {
    $res = @(Receive-Job $trophies.job -ErrorAction SilentlyContinue | Where-Object ok); Remove-Job $trophies.job -Force; $trophies.job = $null
    $ids = @($res | ForEach-Object { "$($_.id)" })
    $trophies.list = @($trophies.list | Where-Object { $ids -notcontains "$($_.id)" }) + @($res | ForEach-Object { $_.items } | Where-Object { $_ })
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds(); foreach ($i in $ids) { $trophies.scanned[$i] = $now }
    Save-Json @{ scanned = $trophies.scanned; list = $trophies.list } $trophyFile
  }
  if (-not $trophies.job -and ((Get-Date) - $trophies.at).TotalHours -gt 6) {
    $trophies.at = Get-Date
    $cfg = Get-SteamConfig
    if (-not $cfg) { return }
    $last = Read-SteamPlaytime (Get-Content $cfg.FullName -Raw -Encoding UTF8) 'LastPlayed'
    $ids = @(foreach ($f in Get-ChildItem (Join-Path $cfg.DirectoryName 'librarycache') -Filter *.json -ErrorAction SilentlyContinue) {
      if ([IO.File]::ReadAllText($f.FullName) -match '"nAchieved":[1-9]' -and (-not $trophies.scanned[$f.BaseName] -or [int64]$last[$f.BaseName] -gt [int64]$trophies.scanned[$f.BaseName])) { $f.BaseName }
    })
    if ($ids.Count) {
      $trophies.job = Start-Job -ArgumentList (Get-SteamId $cfg), $ids {
        param($sid, $ids)
        foreach ($id in $ids) {
          try {
            $pct = @{}
            (Invoke-RestMethod "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v0002/?gameid=$id" -TimeoutSec 10).achievementpercentages.achievements | ForEach-Object { $pct[$_.name] = [double]$_.percent }
            # same as Read-SteamXml (jobs can't see the main script's functions): no DTDs
            $xs = New-Object Xml.XmlReaderSettings; $xs.DtdProcessing = 'Prohibit'; $xs.XmlResolver = $null
            $x = New-Object Xml.XmlDocument; $x.XmlResolver = $null
            $x.Load([Xml.XmlReader]::Create((New-Object IO.StringReader (Invoke-WebRequest "https://steamcommunity.com/profiles/$sid/stats/$id/?xml=1" -UseBasicParsing -TimeoutSec 10).Content), $xs))
            $game = $x.playerstats.game.gameName
            $items = @($x.playerstats.achievements.achievement | Where-Object { $_.GetAttribute('closed') -eq '1' -and $pct.ContainsKey($_['apiname'].InnerText) -and $pct[$_['apiname'].InnerText] -lt 10 } | ForEach-Object {
              [pscustomobject]@{ id = $id; game = $game; name = $_['name'].InnerText; desc = $_['description'].InnerText; img = $_['iconClosed'].InnerText; pct = [Math]::Round($pct[$_['apiname'].InnerText], 1)
                at = $(if ($_['unlockTimestamp']) { [int64]$_['unlockTimestamp'].InnerText } else { 0 }) } })
            [pscustomobject]@{ id = $id; ok = $true; items = $items }
          } catch { [pscustomobject]@{ id = $id; ok = $false } }  # failed games get retried on the next scan
          Start-Sleep -Milliseconds 400  # be polite to Steam
        }
      }
    }
  }
}

# --- price watch: games you're waiting on, checked hourly against the Steam store ---
$watch = @{ at = [datetime]::MinValue; list = New-Object Collections.ArrayList }
# foreach over the parsed array (PS 5 hands "[]" back as one empty item otherwise); entries without an id are skipped
if (Test-Path $watchFile) { foreach ($w in (Read-JsonFile $watchFile)) { if ($w.id) { [void]$watch.list.Add($w) } } }
function Update-Watch([switch]$Force) {
  if (-not $Force -and ((Get-Date) - $watch.at).TotalMinutes -lt 60) { return }
  $watch.at = Get-Date
  if (-not $watch.list.Count) { return }
  try { $r = Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$(($watch.list | ForEach-Object id) -join ',')&filters=price_overview" -TimeoutSec 15 } catch { return }
  foreach ($w in $watch.list) {
    $po = $r."$($w.id)".data.price_overview
    if (-not $po) { continue }  # free or unavailable right now
    $w | Add-Member now ([int]$po.final) -Force; $w | Add-Member nowText $po.final_formatted -Force; $w | Add-Member pct ([int]$po.discount_percent) -Force
    if ($w.now -le $w.target -and -not $w.notified) { Show-Toast 'Price' "Price drop: $($w.name)" "Now $($w.nowText). You were waiting for $($settings.currency)$('{0:0.00}' -f ($w.target / 100))."; $w | Add-Member notified $true -Force }
    elseif ($w.now -gt $w.target) { $w | Add-Member notified $false -Force }  # re-arm once the price climbs back
  }
  Save-Json @($watch.list) $watchFile
}

# Steam's store search returns nothing without a country, so use the country set in Windows (Settings > Time & language > Region).
# Two capital letters only (it goes into a URL); anything else falls back to the US store.
$storeCountry = try { [Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName } catch { 'US' }
if ($storeCountry -cnotmatch '^[A-Z]{2}$') { $storeCountry = 'US' }
function Find-StoreGames([string]$q) {
  try { $r = Invoke-RestMethod "https://store.steampowered.com/api/storesearch/?term=$([uri]::EscapeDataString($q))&l=english&cc=$storeCountry" -TimeoutSec 10 } catch { return @() }
  @($r.items | Where-Object { $_.type -eq 'app' } | Select-Object -First 8 | ForEach-Object { @{ id = "$($_.id)"; name = $_.name; cents = [int]$_.price.final; img = $_.tiny_image } })
}

# --- Now playing (Windows media session, same source as the volume flyout) ---

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); [void]$task.Wait(3000); $task.Result }
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$mediaMgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

function Read-Thumbnail($ref) {
  if (-not $ref) { return $null }
  try {
    $s = Await ($ref.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    $ms = New-Object IO.MemoryStream
    # PowerShell can't bind the WinRT COM stream to IInputStream itself; reflection's Invoke does the cast
    [IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [type[]]@([Windows.Storage.Streams.IInputStream])).Invoke($null, @($s)).CopyTo($ms)
    "data:image/png;base64," + [Convert]::ToBase64String($ms.ToArray())
  } catch { $null }
}

$songs = Read-JsonHash $songsFile  # "title|artist" -> plays, for the jukebox's heavy rotation
$art = @{ key = $null; url = $null; song = $null }
$nowSong = @{ key = $null; playing = $false; artist = $null }  # what's playing right now (read by app tracking for soundtracks); artist = the last counted song's

# --- song bingo: 24 squares + a free centre, marked by the songs you play (even with Pulse's window closed) ---
$bingoState = @{ card = (Read-JsonFile $bingoFile) }
function New-BingoCard {
  # your most-played artists, topped up with song challenges so a card works even with a short listening history
  $artists = @($songs.Values | Where-Object artist | Group-Object artist | Sort-Object { ($_.Group | Measure-Object plays -Sum).Sum } -Descending | Select-Object -First 12 | ForEach-Object Name)
  $challenges = @(
    @{ kind = 'long'; label = 'A song 5+ minutes long' }, @{ kind = 'short'; label = 'A song under 2:30' }, @{ kind = 'new'; label = 'A song you have never played' },
    @{ kind = 'repeat'; label = 'Same artist twice in a row' }, @{ kind = 'feat'; label = 'A song with a feature (feat.)' }, @{ kind = 'game'; label = 'A song while a game is running' },
    @{ kind = 'morning'; label = 'A song before noon' }, @{ kind = 'late'; label = 'A song after 10 PM' }, @{ kind = 'weekend'; label = 'A song on the weekend' },
    @{ kind = 'titletrack'; label = 'A title track (song = album name)' }
  ) + @('love', 'night', 'heart', 'fire', 'dance', 'dream', 'rain', 'summer', 'blue', 'star', 'girl', 'time', 'sun', 'home' | ForEach-Object { @{ kind = 'word'; value = $_; label = "'$_' in the title" } })
  $pool = @($artists | ForEach-Object { @{ kind = 'artist'; value = $_; label = $_ } }) + @($challenges | Sort-Object { Get-Random })
  $sq = @($pool | Select-Object -First 24 | Sort-Object { Get-Random })
  $sq = @($sq[0..11]) + @(@{ kind = 'free'; label = 'FREE' }) + @($sq[12..23])
  foreach ($s in $sq) { $s.marked = $s.kind -eq 'free' }
  $bingoState.card = [pscustomobject]@{ created = (Get-Date).ToString('o'); squares = $sq; paid = @() }
  Save-Json $bingoState.card $bingoFile
}
function Update-Bingo([string]$title, [string]$artist, [bool]$isNew, [double]$dur, [string]$prevArtist, [string]$album, [datetime]$when = (Get-Date)) {
  $c = $bingoState.card
  if (-not $c) { return }
  $hit = $false
  foreach ($s in $c.squares) {
    if ($s.marked) { continue }
    $ok = switch ($s.kind) {
      'artist' { $artist -eq $s.value }
      'long' { $dur -ge 300 }
      'short' { $dur -gt 0 -and $dur -lt 150 }
      'new' { $isNew }
      'repeat' { $prevArtist -and $artist -eq $prevArtist }
      'feat' { $title -match '\b(feat|ft)\.?\s' }
      'game' { [bool]$session.gid }
      'word' { $title -match "\b$([regex]::Escape($s.value))\b" }
      'morning' { $when.Hour -lt 12 }
      'late' { $when.Hour -ge 22 -or $when.Hour -lt 4 }
      'weekend' { $when.DayOfWeek -in 'Saturday', 'Sunday' }
      'titletrack' { $album -and $title -eq $album }
      default { $false }
    }
    if ($ok) { $s.marked = $true; $hit = $true }
  }
  if ($hit) { Save-Json $c $bingoFile }
}

function Update-NowSong {
  # called every few seconds by the server loop and by /api/now: counts plays, feeds soundtracks and bingo
  $s = $mediaMgr.GetCurrentSession()
  if (-not $s) { $nowSong.playing = $false; return $null }
  $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
  $key = "$($p.Title)|$($p.Artist)"
  $playing = ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') -and [bool]$p.Title
  $nowSong.key = $key; $nowSong.playing = $playing
  # shortcut: a play = the track showing up while playing; pause/resume doesn't recount, but restarting Pulse recounts the current song once
  if ($playing -and $key -ne $art.song) {
    $art.song = $key
    $isNew = -not $songs[$key]
    if ($isNew) { $songs[$key] = [pscustomobject]@{ title = $p.Title; artist = $p.Artist; plays = 0 } }
    $songs[$key].plays++
    Save-Json $songs $songsFile
    Update-Bingo $p.Title $p.Artist $isNew $s.GetTimelineProperties().EndTime.TotalSeconds $nowSong.artist $p.AlbumTitle
    $nowSong.artist = $p.Artist
  }
  @{ s = $s; p = $p; key = $key; playing = $playing }
}

function Get-NowPlaying {
  $r = Update-NowSong
  if (-not $r) { return @{ title = $null } }
  $p = $r.p
  if ($r.key -ne $art.key -or -not $art.url) { $art.url = Read-Thumbnail $p.Thumbnail; $art.key = $r.key }
  $tl = $r.s.GetTimelineProperties()
  @{
    title = $p.Title; artist = $p.Artist; album = $p.AlbumTitle; app = $r.s.SourceAppUserModelId; art = $art.url
    playing = $r.playing
    pos = $tl.Position.TotalSeconds; dur = $tl.EndTime.TotalSeconds; at = $tl.LastUpdatedTime.ToUnixTimeMilliseconds()
  }
}

# --- App usage (Windows keeps no usable per-app time, so we sample the focused window while Pulse runs) ---

Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII i);
  public static uint IdleMs() { var i = new LII(); i.cbSize = 8; GetLastInputInfo(ref i); return (uint)Environment.TickCount - i.dwTime; }
}
'@
Add-Type -AssemblyName System.Drawing

$usage = Read-JsonHash $usageFile
$daily = Read-JsonHash $dailyFile; foreach ($k in @($daily.Keys)) { $daily[$k] = ConvertTo-Hash $daily[$k] }
$soundtracks = Read-JsonHash $soundtrackFile; foreach ($k in @($soundtracks.Keys)) { $soundtracks[$k] = ConvertTo-Hash $soundtracks[$k] }
$session = @{ gid = $null }  # the Steam game you're playing right now, for the "session over" notification
$gameMap = @{ dirs = @{}; at = [datetime]::MinValue }

function Get-GameIdForPath([string]$path) {
  # a program running from <library>\steamapps\common\<installdir>\ is that Steam game; appmanifests map installdir -> appid
  if ($path -notmatch '\\steamapps\\common\\([^\\]+)\\') { return $null }
  $dir = $Matches[1]
  if (-not $gameMap.dirs.ContainsKey($dir) -and ((Get-Date) - $gameMap.at).TotalMinutes -gt 5) {  # rescan for newly installed games, at most every 5 min
    $gameMap.at = Get-Date
    foreach ($m in (Get-SteamLibs | ForEach-Object { Get-ChildItem (Join-Path $_ 'steamapps/appmanifest_*.acf') -ErrorAction SilentlyContinue })) {
      $t = Get-Content $m.FullName -Raw
      if ($t -match '"installdir"\s*"([^"]+)"') { $gameMap.dirs[$Matches[1]] = $m.BaseName -replace '^appmanifest_' }
    }
  }
  $gameMap.dirs[$dir]
}

function Add-Usage([double]$seconds) {
  # shortcut: gamepad input doesn't reset Windows' idle timer, so 5+ min of controller-only play isn't counted; use XInput polling if that matters.
  if ([Win]::IdleMs() -gt 300000) { return }
  [uint32]$procId = 0
  [void][Win]::GetWindowThreadProcessId([Win]::GetForegroundWindow(), [ref]$procId)
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $p -or $procId -eq 0) { return }
  $n = $p.ProcessName
  if (-not $usage[$n]) {
    $label = try { $p.MainModule.FileVersionInfo.FileDescription } catch { $null }
    $usage[$n] = [pscustomobject]@{ label = $(if ($label) { $label } else { $n }); path = $p.Path; seconds = 0.0 }
  }
  $u = $usage[$n]
  $u.seconds += $seconds
  $day = (Get-Date).ToString('yyyy-MM-dd')
  if (-not $daily[$day]) { $daily[$day] = @{} }
  $daily[$day][$u.label] = [double]$daily[$day][$u.label] + $seconds
  $gid = Get-GameIdForPath $u.path
  if ($gid) {
    if ($nowSong.playing) {  # this song is part of the game's soundtrack
      if (-not $soundtracks[$gid]) { $soundtracks[$gid] = @{} }
      $soundtracks[$gid][$nowSong.key] = [double]$soundtracks[$gid][$nowSong.key] + $seconds
    }
    if ($session.gid -ne $gid) { $session.gid = $gid; $session.name = Get-GameName $gid; $session.pid = $p.Id; $session.seconds = 0 }
    $session.seconds += $seconds
  }
}

function Watch-Session {
  # a game session ends when the game's process exits; sessions of 10+ minutes get a "session over" notification
  if ($session.gid -and -not (Get-Process -Id $session.pid -ErrorAction SilentlyContinue)) {
    $m = [int]($session.seconds / 60)
    if ($m -ge 10) { Show-Toast 'Session' 'Session over' "$(if ($m -ge 60) { '{0} h {1} min' -f [int][Math]::Floor($m / 60), ($m % 60) } else { "$m min" }) of $($session.name). Good game!" }
    $session.gid = $null
  }
}

function Get-Heatmap {
  # last 12 weeks: hours on the PC each day and that day's top app
  @(83..0 | ForEach-Object {
    $day = (Get-Date).Date.AddDays(-$_).ToString('yyyy-MM-dd'); $d = $daily[$day]
    $top = if ($d) { ($d.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { '' }  # '' not $null: a bare empty if becomes {} in JSON
    @{ date = $day; seconds = $(if ($d) { [int]($d.Values | Measure-Object -Sum).Sum } else { 0 }); top = $top }
  })
}

function Get-UsageSplit {
  # games (anything running from a Steam library) vs everything else, all time
  $g = 0.0; $o = 0.0
  foreach ($u in $usage.Values) { if (Get-GameIdForPath $u.path) { $g += $u.seconds } else { $o += $u.seconds } }
  @{ games = [int]$g; other = [int]$o }
}

$icons = @{}
function Get-Icon([string]$path) {
  if (-not $path) { return $null }
  if (-not $icons.ContainsKey($path)) {
    $icons[$path] = try {
      $ms = New-Object IO.MemoryStream
      [Drawing.Icon]::ExtractAssociatedIcon($path).ToBitmap().Save($ms, [Drawing.Imaging.ImageFormat]::Png)
      "data:image/png;base64," + [Convert]::ToBase64String($ms.ToArray())
    } catch { $null }
  }
  $icons[$path]
}

function Get-AppStats {
  @($usage.GetEnumerator() | Sort-Object { $_.Value.seconds } -Descending | Select-Object -First 10 | ForEach-Object {
    @{ name = $_.Value.label; seconds = [int]$_.Value.seconds; icon = (Get-Icon $_.Value.path); game = [bool](Get-GameIdForPath $_.Value.path) } })
}

function Save-Usage {
  Save-Json $usage $usageFile
  $cut = (Get-Date).AddDays(-400).ToString('yyyy-MM-dd')
  foreach ($k in @($daily.Keys)) { if ($k -lt $cut) { $daily.Remove($k) } }  # keep about a year of heatmap history
  Save-Json $daily $dailyFile 3
  Save-Json $soundtracks $soundtrackFile 3
}

# --- Movie theater: your own Google OAuth client (Desktop app) reads your YouTube; the tokens never leave this process and youtube.json ---
$ytFile = Join-Path $PSScriptRoot 'youtube.json'   # clientId, clientSecret, refresh token
$yt = Read-JsonHash $ytFile
$ytAuth = @{ state = ''; verifier = ''; access = ''; expires = [datetime]::MinValue }
$ytRedirect = "http://localhost:$Port/oauth/callback"
function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function New-RandomToken { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ConvertTo-B64Url $b }
function Get-YtStatus { @{ keys = [bool]($yt.clientId -and $yt.clientSecret); signedIn = [bool]$yt.refresh } }
function Set-YtKeys($b) {
  # trust boundary: only what a Google Desktop client id/secret looks like goes into the sign-in URL and token requests
  $id = "$($b.clientId)".Trim(); $sec = "$($b.clientSecret)".Trim()
  if ($id -notmatch '^[\w-]{5,150}\.apps\.googleusercontent\.com$' -or $sec -notmatch '^[\w-]{10,100}$') { throw 'not a Google client id/secret' }
  $yt.clientId = $id; $yt.clientSecret = $sec; $yt.Remove('refresh'); $ytAuth.access = ''
  Save-Json $yt $ytFile
}
function Start-YtLogin {
  # PKCE + a one-time state, so only the sign-in this Pulse started can complete
  $ytAuth.state = New-RandomToken; $ytAuth.verifier = New-RandomToken
  $challenge = ConvertTo-B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($ytAuth.verifier)))
  $q = [ordered]@{ client_id = $yt.clientId; redirect_uri = $ytRedirect; response_type = 'code'; scope = 'https://www.googleapis.com/auth/youtube.readonly'
    access_type = 'offline'; prompt = 'consent'; state = $ytAuth.state; code_challenge = $challenge; code_challenge_method = 'S256' }
  'https://accounts.google.com/o/oauth2/v2/auth?' + (($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&')
}
function Complete-YtLogin($q) {
  if (-not $ytAuth.state -or $q['state'] -cne $ytAuth.state) { throw 'sign-in link expired or not started by Pulse' }
  $ytAuth.state = ''
  if (-not $q['code']) { throw "Google said: $($q['error'])" }
  $r = Invoke-RestMethod 'https://oauth2.googleapis.com/token' -Method Post -TimeoutSec 15 -Body @{ code = $q['code']; client_id = $yt.clientId; client_secret = $yt.clientSecret
    redirect_uri = $ytRedirect; grant_type = 'authorization_code'; code_verifier = $ytAuth.verifier }
  if (-not $r.refresh_token) { throw 'Google sent no refresh token' }
  $yt.refresh = $r.refresh_token; Save-Json $yt $ytFile
  $ytAuth.access = $r.access_token; $ytAuth.expires = (Get-Date).AddSeconds([int]$r.expires_in - 60)
}
function Get-YtToken {
  if ($ytAuth.access -and (Get-Date) -lt $ytAuth.expires) { return $ytAuth.access }
  if (-not $yt.refresh) { throw 'not signed in' }
  try {
    $r = Invoke-RestMethod 'https://oauth2.googleapis.com/token' -Method Post -TimeoutSec 15 -Body @{ client_id = $yt.clientId; client_secret = $yt.clientSecret; refresh_token = $yt.refresh; grant_type = 'refresh_token' }
  } catch {
    # 400 = revoked or expired (apps left in Google's "Testing" mode expire every 7 days): sign in again
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 400) { $yt.Remove('refresh'); Save-Json $yt $ytFile }
    throw
  }
  $ytAuth.access = $r.access_token; $ytAuth.expires = (Get-Date).AddSeconds([int]$r.expires_in - 60)
  $ytAuth.access
}
function ConvertTo-YtItem($i) {
  # one shape for the page: kind + id + title + thumbnail (+ channel for videos)
  $s = $i.snippet; $thumb = "$($s.thumbnails.medium.url)"
  switch ($i.kind) {
    'youtube#subscription' { @{ kind = 'channel'; id = $s.resourceId.channelId; title = $s.title; thumb = $thumb } }
    'youtube#playlist' { @{ kind = 'playlist'; id = $i.id; title = $s.title; thumb = $thumb; count = [int]$i.contentDetails.itemCount } }
    'youtube#playlistItem' { if ($s.title -notin 'Private video', 'Deleted video') { @{ kind = 'video'; id = $s.resourceId.videoId; title = $s.title; channel = $s.videoOwnerChannelTitle; thumb = $thumb } } }
    'youtube#video' { @{ kind = 'video'; id = $i.id; title = $s.title; channel = $s.channelTitle; thumb = $thumb } }
    # search results come HTML-escaped ("Don&#39;t"); the page escapes again, so decode here
    'youtube#searchResult' { @{ kind = 'video'; id = $i.id.videoId; title = [Net.WebUtility]::HtmlDecode($s.title); channel = [Net.WebUtility]::HtmlDecode($s.channelTitle); thumb = $thumb } }
  }
}
$ytHome = @{ at = [datetime]::MinValue; items = @() }
function Get-YtHome {
  # YouTube's API has no home feed, so: the newest uploads across your subscriptions, cached 15 min (~1 quota unit per channel per refresh)
  if ((Get-Date) -lt $ytHome.at.AddMinutes(15)) { return $ytHome.items }
  $token = Get-YtToken; $subs = @(); $page = ''
  do {
    $r = Invoke-RestMethod "https://www.googleapis.com/youtube/v3/subscriptions?part=snippet&mine=true&maxResults=50$(if ($page) { "&pageToken=$page" })" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 15
    $subs += @($r.items | ForEach-Object { "$($_.snippet.resourceId.channelId)" } | Where-Object { $_ -match '^UC[\w-]{22}$' }); $page = "$($r.nextPageToken)"
  } while ($page -and $subs.Count -lt 500)
  Add-Type -AssemblyName System.Net.Http
  [Net.ServicePointManager]::DefaultConnectionLimit = 16  # .NET Framework allows only 2 at a time per host by default
  $http = New-Object Net.Http.HttpClient; $http.Timeout = [TimeSpan]::FromSeconds(20)
  $http.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
  try {
    $tasks = @($subs | ForEach-Object { $http.GetStringAsync("https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&maxResults=5&playlistId=UU$($_.Substring(2))") })
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks) } catch {}  # a channel with no uploads 404s: skip it, keep the rest
    $vids = foreach ($t in $tasks) {
      if ($t.Status -eq 'RanToCompletion') { foreach ($i in ($t.Result | ConvertFrom-Json).items) { $v = ConvertTo-YtItem $i; if ($v) { $v.at = "$($i.snippet.publishedAt)"; $v } } }
    }
  } finally { $http.Dispose() }
  $ytHome.items = @($vids | Sort-Object { $_.at } -Descending | Select-Object -First 60)  # ISO dates sort as text
  if ($ytHome.items.Count) { $ytHome.at = Get-Date }  # an empty result (all failed) is retried next time, not kept for 15 min
  $ytHome.items
}
function Get-YtList([string]$list, [string]$id, [string]$page, [string]$q = '') {
  if ($id -notmatch '^[\w-]{0,64}$' -or $page -notmatch '^[\w-]{0,100}$') { throw 'bad id' }
  if ($q.Length -gt 100) { throw 'search is too long' }
  if ($list -eq 'home') { return @{ items = @(Get-YtHome); next = '' } }
  $path = switch ($list) {
    'subs' { 'subscriptions?part=snippet&mine=true&order=alphabetical' }
    'playlists' { 'playlists?part=snippet,contentDetails&mine=true' }
    'liked' { 'videos?part=snippet&myRating=like' }
    # 100 quota units per page (of 10,000/day), vs 1 for the lists above
    'search' { if (-not $q.Trim()) { throw 'type something to search for' }; "search?part=snippet&type=video&q=$([uri]::EscapeDataString($q.Trim()))" }
    'playlist' { "playlistItems?part=snippet&playlistId=$id" }
    'channel' { if ($id -notmatch '^UC[\w-]{22}$') { throw 'bad channel' }; "playlistItems?part=snippet&playlistId=UU$($id.Substring(2))" }  # a channel's uploads playlist is its id with UC -> UU
    default { throw 'unknown list' }
  }
  $r = Invoke-RestMethod "https://www.googleapis.com/youtube/v3/$path&maxResults=50$(if ($page) { "&pageToken=$page" })" -Headers @{ Authorization = "Bearer $(Get-YtToken)" } -TimeoutSec 15
  @{ items = @($r.items | ForEach-Object { ConvertTo-YtItem $_ } | Where-Object { $_ }); next = "$($r.nextPageToken)" }
}
function Stop-YtLogin {
  if ($yt.refresh) { try { Invoke-RestMethod 'https://oauth2.googleapis.com/revoke' -Method Post -Body @{ token = $yt.refresh } -TimeoutSec 10 | Out-Null } catch {} }
  $yt.Remove('refresh'); $ytAuth.access = ''; $ytHome.at = [datetime]::MinValue; Save-Json $yt $ytFile
}

# --- Server --------------------------------------------------------------

function Send($ctx, [string]$body, [string]$type) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  $ctx.Response.ContentType = "$type; charset=utf-8"
  # no other website may embed Pulse in a frame (clickjacking), and browsers mustn't guess content types
  $ctx.Response.Headers['X-Frame-Options'] = 'DENY'
  $ctx.Response.Headers['Content-Security-Policy'] = "frame-ancestors 'none'"
  $ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}

function Handle($ctx) {
  try {
    # http.sys listens on every network card and only checks the Host header, which another PC on the network can fake
    if (-not [Net.IPAddress]::IsLoopback($ctx.Request.RemoteEndPoint.Address)) { $ctx.Response.StatusCode = 403; $ctx.Response.Close(); return }
    # websites can't read Pulse, but can make your browser send it requests (img tags, links) that burn YouTube quota or start scans;
    # browsers label those, so refuse them. Google's sign-in redirect is the one visit from another site we expect.
    if ($ctx.Request.Headers['Sec-Fetch-Site'] -in 'cross-site', 'same-site' -and $ctx.Request.Url.AbsolutePath -ne '/oauth/callback') { $ctx.Response.StatusCode = 403; $ctx.Response.Close(); return }
    switch ($ctx.Request.Url.AbsolutePath) {
      '/'          { Send $ctx (Get-Content (Join-Path $PSScriptRoot 'index.html') -Raw -Encoding UTF8) 'text/html' }
      '/api/now'   { Send $ctx (ConvertTo-Json (Get-NowPlaying) -Compress) 'application/json' }
      '/api/stats' {
        # each part on its own: one that fails (an odd app icon, a weird Steam file) is logged and left empty instead of blanking the whole lobby
        $part = { param($name, $fn, $empty) try { & $fn } catch { Write-Warning "/api/stats $name failed: $_"; if ($null -ne $empty) { $empty } } }  # $null emits nothing, so @() stays empty
        $s = & $part 'steam' { Get-SteamStats } @{ games = @(); deck = @() }
        $rotation = @($songs.Values | Sort-Object plays -Descending | Select-Object -First 5)
        Send $ctx (ConvertTo-Json @{ games = $s.games; deck = $s.deck; apps = @(& $part 'apps' { Get-AppStats } $null); rotation = $rotation
          heatmap = @(& $part 'heatmap' { Get-Heatmap } $null); split = (& $part 'split' { Get-UsageSplit } $null) } -Depth 6 -Compress) 'application/json'
      }
      '/api/chase' { Send $ctx (ConvertTo-Json @(Get-CompletionChase) -Depth 5 -Compress) 'application/json' }
      '/api/trophies' { Update-Trophies; Send $ctx (ConvertTo-Json @{ scanning = ($null -ne $trophies.job); list = @($trophies.list | Sort-Object pct) } -Depth 4 -Compress) 'application/json' }
      '/api/contract' { Send $ctx (ConvertTo-Json (Get-Contract -Check:($ctx.Request.QueryString['check'] -eq '1')) -Compress) 'application/json' }
      '/api/bingo' { if (-not $bingoState.card) { New-BingoCard }; Send $ctx (ConvertTo-Json $bingoState.card -Depth 4 -Compress) 'application/json' }
      '/api/watch' { Send $ctx (ConvertTo-Json @{ list = @($watch.list); currency = $settings.currency } -Depth 3 -Compress) 'application/json' }
      '/api/search' {
        $q = "$($ctx.Request.QueryString['q'])"
        Send $ctx (ConvertTo-Json @(if ($q.Length -ge 2 -and $q.Length -le 60) { Find-StoreGames $q }) -Compress) 'application/json'
      }
      '/api/settings' { Send $ctx (ConvertTo-Json $settings -Compress) 'application/json' }
      '/api/store' { Send $ctx $(if ($s = Read-JsonFile $storeFile) { ConvertTo-Json $s -Compress } else { '{}' }) 'application/json' }
      { $_ -like '/api/do/*' } {
        # every change goes through POST + a custom header: another website can't send that to localhost without a preflight we never answer
        if ($ctx.Request.HttpMethod -ne 'POST' -or -not $ctx.Request.Headers['X-Pulse']) { $ctx.Response.StatusCode = 400; $ctx.Response.Close(); break }
        $q = $ctx.Request.QueryString
        switch ($ctx.Request.Url.AbsolutePath) {
          '/api/do/settings' { Set-Settings (Read-Body $ctx) }
          '/api/do/notify' {
            $b = Read-Body $ctx
            if ("$($b.kind)" -in 'Jackpot') { Show-Toast $b.kind ("$($b.title)".Substring(0, [Math]::Min(80, "$($b.title)".Length))) ("$($b.body)".Substring(0, [Math]::Min(200, "$($b.body)".Length))) }
          }
          '/api/do/store' {
            # trust boundary: only the page's own "pulse-" keys with short values. All-or-nothing: a bad or empty request
            # is refused instead of saved, so it can never wipe the chips backup.
            $b = Read-Body $ctx; $keep = @{}
            foreach ($p in $b.psobject.Properties) {
              if ($p.Name -notmatch '^pulse-[a-z-]{1,30}$' -or "$($p.Value)".Length -gt 4000 -or $keep.Count -ge 30) { throw "rejected store entry '$($p.Name)'" }
              $keep[$p.Name] = "$($p.Value)"
            }
            if (-not $keep.Count) { throw 'rejected empty store' }
            Save-Json $keep $storeFile
          }
          '/api/do/bingo-new' { New-BingoCard }
          '/api/do/bingo-claim' {
            $line = [int]$q['line']
            if ($bingoState.card -and $line -ge 0 -and $line -lt 13 -and $bingoState.card.paid -notcontains $line) { $bingoState.card.paid = @($bingoState.card.paid) + $line; Save-Json $bingoState.card $bingoFile }
          }
          '/api/do/contract-claim' { $c = Get-Contract; if ($c -and $c.done) { $c.claimed = $true; Save-Json $c $contractFile } }
          '/api/do/watch-add' {
            $b = Read-Body $ctx
            if ("$($b.id)" -match '^\d+$' -and [int]$b.target -gt 0 -and $watch.list.Count -lt 50) {  # 50 games max: one store request checks them all
              foreach ($w in @($watch.list | Where-Object { "$($_.id)" -eq "$($b.id)" })) { $watch.list.Remove($w) }
              [void]$watch.list.Add([pscustomobject]@{ id = "$($b.id)"; name = "$($b.name)".Substring(0, [Math]::Min(120, "$($b.name)".Length)); target = [int]$b.target; notified = $false })
              Update-Watch -Force
            }
          }
          '/api/do/yt-keys' { Set-YtKeys (Read-Body $ctx) }
          '/api/do/yt-logout' { Stop-YtLogin }
          '/api/do/watch-remove' { foreach ($w in @($watch.list | Where-Object { "$($_.id)" -eq "$($q['id'])" })) { $watch.list.Remove($w) }; Save-Json @($watch.list) $watchFile }
          default { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); return }
        }
        Send $ctx '{}' 'application/json'
      }
      '/api/game' {
        $id = $ctx.Request.QueryString['id']
        if ($id -notmatch '^\d+$') { $ctx.Response.StatusCode = 400; $ctx.Response.Close(); break }
        Send $ctx (ConvertTo-Json (Get-GameDetails $id) -Depth 5 -Compress) 'application/json'
      }
      '/api/ban' {
        # POST + custom header: another website can't send that to localhost without a preflight we never answer
        $id = $ctx.Request.QueryString['id']
        if ($ctx.Request.HttpMethod -ne 'POST' -or -not $ctx.Request.Headers['X-Pulse'] -or $id -notmatch '^\d+$') { $ctx.Response.StatusCode = 400; $ctx.Response.Close(); break }
        if ($ctx.Request.QueryString['on'] -eq '1') { [void]$bans.Add($id) } else { [void]$bans.Remove($id) }
        Save-Json @($bans) $bansFile
        Send $ctx '{}' 'application/json'
      }
      '/bg.mp4' {
        # optional background video; shortcut: sent whole without range support, fine for a looping local clip
        $f = Join-Path $PSScriptRoot 'bg.mp4'
        if (Test-Path $f) { $b = [IO.File]::ReadAllBytes($f); $ctx.Response.ContentType = 'video/mp4'; $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close() }
        else { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
      }
      '/api/yt/status' { Send $ctx (ConvertTo-Json (Get-YtStatus) -Compress) 'application/json' }
      '/api/yt' {
        $q = $ctx.Request.QueryString
        $r = try { Get-YtList "$($q['list'])" "$($q['id'])" "$($q['page'])" "$($q['q'])" } catch { @{ error = "$($_.Exception.Message)"; signedIn = [bool]$yt.refresh } }
        Send $ctx (ConvertTo-Json $r -Depth 4 -Compress) 'application/json'
      }
      '/api/yt-login' {
        # POST + custom header, like /api/do/*: only the page can start a sign-in
        if ($ctx.Request.HttpMethod -ne 'POST' -or -not $ctx.Request.Headers['X-Pulse'] -or -not (Get-YtStatus).keys) { $ctx.Response.StatusCode = 400; $ctx.Response.Close(); break }
        Send $ctx (ConvertTo-Json @{ url = (Start-YtLogin) } -Compress) 'application/json'
      }
      '/oauth/callback' {
        # Google sends your browser here after you sign in
        $msg = try { Complete-YtLogin $ctx.Request.QueryString; '&#127916; Signed in to YouTube. You can close this tab and go back to Pulse.' } catch { "Sign-in didn't work: $([Net.WebUtility]::HtmlEncode($_.Exception.Message)). Try again from Pulse's Theater." }
        Send $ctx "<!doctype html><meta charset=utf-8><title>Pulse</title><body style=`"background:#12030a;color:#f6efd9;font:18px Segoe UI,sans-serif;display:grid;place-items:center;height:90vh`"><p>$msg</p>" 'text/html'
      }
      '/api/scratch' { Send $ctx (ConvertTo-Json (Get-ScratchCard) -Depth 4 -Compress) 'application/json' }
      '/api/app' {
        $id = $ctx.Request.QueryString['id']
        if ($id -notmatch '^\d+$') { $ctx.Response.StatusCode = 400; $ctx.Response.Close(); break }
        Send $ctx (ConvertTo-Json (Get-AppInfo $id) -Compress) 'application/json'
      }
      '/api/sales' { Send $ctx (ConvertTo-Json (Get-Sales) -Depth 4 -Compress) 'application/json' }
      '/api/installed' { Send $ctx (ConvertTo-Json @(Get-InstalledGames) -Compress) 'application/json' }
      default      { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
    }
  } catch {
    Write-Warning "$($ctx.Request.Url.AbsolutePath): $_"
    try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch {}
  }
}

if ($MyInvocation.InvocationName -eq '.') { return }  # dot-sourced by test.ps1: functions only

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")  # localhost-only; HttpListener also rejects other Host headers
$url = "http://localhost:$Port/"
# already running (e.g. hidden from the desktop shortcut): just open another window
try { $listener.Start() } catch { Start-Process msedge "--app=$url"; return }
Write-Host "Pulse running at $url (Ctrl+C to quit)"
if (-not $NoWindow) { try { Start-Process msedge "--app=$url" } catch { Start-Process $url } }

$clock = [Diagnostics.Stopwatch]::StartNew()
$lastSave = 0
$salesTick = 55  # first deal check a few seconds after startup
$songTick = 0; $contractTick = 1790
$next = $listener.GetContextAsync()
try {
  while ($true) {
    # the shortcut runs Pulse hidden, so a stray error would kill it silently; log it to pulse.log and keep serving instead
    try {
      if ($next.Wait(1000)) { Handle $next.Result; $next = $listener.GetContextAsync() }
      $elapsed = $clock.Elapsed.TotalSeconds
      if ($elapsed -ge 1) { $clock.Restart(); Add-Usage ([Math]::Min($elapsed, 5)) ; $lastSave += $elapsed; $salesTick += $elapsed; $songTick += $elapsed; $contractTick += $elapsed }
      if ($lastSave -ge 30) { Save-Usage; $lastSave = 0 }
      if ($songTick -ge 5) { [void](Update-NowSong); Watch-Session; $songTick = 0 }  # songs feed play counts, soundtracks and bingo with no window open
      if ($salesTick -ge 60) { [void](Get-Sales); Update-Trophies; Update-Watch; $salesTick = 0 }  # once a minute; each one decides itself whether it's due
      if ($contractTick -ge 1800) { [void](Get-Contract -Check); $contractTick = 0 }  # did you finish today's achievement contract?
    } catch {
      Add-Content (Join-Path $PSScriptRoot 'pulse.log') "$(Get-Date -Format s) $($_ | Out-String)"
      if ($next.IsCompleted) { $next = $listener.GetContextAsync() }  # a failed request: wait for the next one
      Start-Sleep -Milliseconds 500
    }
  }
} finally {
  Save-Usage
  $listener.Stop()
}
