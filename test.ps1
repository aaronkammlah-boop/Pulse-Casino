# Self-check for the Steam parsers. Run: powershell -ExecutionPolicy Bypass -File test.ps1
. "$PSScriptRoot\app.ps1"

$vdf = @'
"apps"
{
	"7" { "cloud" { "last_sync_state" "synchronized" } }
	"730"
	{
		"LastPlayed"		"1784862265"
		"Playtime2wks"		"12"
		"Playtime"		"2719"
	}
	"550" { "Playtime" "38" }
	"440"
	{
		"cloud" { "quota" { "used" "1" } "note" "{not a block}" }
		"LastPlayed"		"1784000000"
		"Playtime"		"99"
	}
}
'@
$p = Read-SteamPlaytime $vdf
if ($p.Count -ne 3 -or $p['730'] -ne 2719 -or $p['550'] -ne 38 -or $p['440'] -ne 99) { throw "playtime parse failed (nested block before Playtime?): $($p | Out-String)" }
$lp = Read-SteamPlaytime $vdf 'LastPlayed'
if ($lp.Count -ne 2 -or $lp['730'] -ne 1784862265 -or $lp['440'] -ne 1784000000) { throw "LastPlayed parse failed: $($lp | Out-String)" }

$priv = Read-PrivateApps '"PrivateApps_42"		"[22100,310080, 743450]"' '42'
if ($priv.Count -ne 3 -or $priv -notcontains '743450') { throw "private apps parse failed: $priv" }
if ((Read-PrivateApps '"PrivateApps_42" "[1]"' '7').Count -ne 0) { throw "private apps must match the signed-in account" }

$page = @'
<a href="https://store.steampowered.com/app/1203620/x/" data-ds-appid="1203620" class="search_result_row">
  <span class="title">Enshrouded &amp; Co</span><div class="search_released responsive_secondrow"> Oct 15, 2026 </div>
  <span class="search_review_summary positive" data-tooltip-html="Very Positive&lt;br&gt;87%"></span>
  <div class="discount_block" data-price-final="3599" data-discount="10"><div class="discount_original_price">$39.99</div><div class="discount_final_price">$35.99</div></div></a>
<a href="https://store.steampowered.com/bundle/1/" data-ds-bundleid="1" data-ds-appid="5,6"><span class="title">Bundle</span><div data-discount="50"></div></a>
<a href="https://store.steampowered.com/app/9/" data-ds-appid="9"><span class="title">Full price</span></a>
'@
$deals = @(Read-SalesPage $page)
if ($deals.Count -ne 1 -or $deals[0].id -ne '1203620' -or $deals[0].cents -ne 3599 -or $deals[0].name -ne 'Enshrouded & Co' -or $deals[0].pct -ne 10 -or $deals[0].now -ne '$35.99' -or $deals[0].review -ne 'Very Positive' -or $deals[0].released -ne 'Oct 15, 2026') {
  throw "sales page parse failed: $($deals | Out-String)"
}

# deal drop = 10:05 Pacific; before it, the previous day's drop counts
$pt = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
$toLocal = { param($y, $mo, $d, $h, $mi) [TimeZoneInfo]::ConvertTime((New-Object DateTime $y, $mo, $d, $h, $mi, 0), $pt, [TimeZoneInfo]::Local) }
if ((Get-DealDropTime (& $toLocal 2026 7 4 10 30)) -ne (& $toLocal 2026 7 4 10 5)) { throw 'drop after 10:05 PT (summer) should be same day' }
if ((Get-DealDropTime (& $toLocal 2026 1 15 9 0)) -ne (& $toLocal 2026 1 14 10 5)) { throw 'drop before 10:05 PT (winter) should be previous day' }

# --- new features: tests write to temp files, never Pulse's real data ---
$tmp = Join-Path $env:TEMP "pulse-test-$PID"; New-Item -ItemType Directory $tmp -Force | Out-Null
$bingoFile = Join-Path $tmp 'bingo.json'; $pricesFile = Join-Path $tmp 'prices.json'

# bingo: a card always has 24 squares + a free centre, even with no listening history
$songs = @{}
New-BingoCard
$sq = @($bingoState.card.squares)
if ($sq.Count -ne 25 -or $sq[12].kind -ne 'free' -or -not $sq[12].marked -or @($sq | Where-Object marked).Count -ne 1) { throw "bingo card malformed: $($sq.Count) squares" }
$bingoState.card.squares = @(
  @{ kind = 'artist'; value = 'Charlie Puth'; marked = $false }, @{ kind = 'word'; value = 'love'; marked = $false },
  @{ kind = 'long'; marked = $false }, @{ kind = 'repeat'; marked = $false }, @{ kind = 'feat'; marked = $false }, @{ kind = 'titletrack'; marked = $false })
Update-Bingo 'Slow It Down' 'Charlie Puth' $false 200 '' 'Voicenotes'
Update-Bingo 'Lovely Love Song (feat. Someone)' 'Charlie Puth' $false 320 'Charlie Puth' 'Lovely Love Song (feat. Someone)'
$m = @($bingoState.card.squares | ForEach-Object { [bool]$_.marked })
if (($m -join ',') -ne 'True,True,True,True,True,True') { throw "bingo marking wrong: $($m -join ',')" }

# best price: a deal cheaper than every earlier day is a new low; a cheaper price within the last week is reported
$prices = @{ '42' = @{ ((Get-Date).AddDays(-3).ToString('yyyy-MM-dd')) = 1500; ((Get-Date).AddDays(-20).ToString('yyyy-MM-dd')) = 2000 } }
$d1 = [pscustomobject]@{ id = '42'; cents = 1200 }; Add-PriceHistory @($d1)
if (-not $d1.lowest -or $d1.cheaperWeek) { throw "best price: 1200 after 1500/2000 should be a new low" }
$prices = @{ '42' = @{ ((Get-Date).AddDays(-3).ToString('yyyy-MM-dd')) = 900 } }
$d2 = [pscustomobject]@{ id = '42'; cents = 1200 }; Add-PriceHistory @($d2)
if ($d2.lowest -or $d2.cheaperWeek -ne 900) { throw "best price: 1200 after 900 three days ago should say 'was cheaper last week'" }

# game detection: a program inside steamapps\common\<installdir>\ maps to that game's appid
$gameMap.dirs = @{ 'Marvel Rivals' = '2767030' }; $gameMap.at = Get-Date
if ((Get-GameIdForPath 'D:\SteamLibrary\steamapps\common\Marvel Rivals\MarvelGame\Marvel.exe') -ne '2767030') { throw 'game path not recognised' }
if (Get-GameIdForPath 'C:\Program Files\Google\Chrome\Application\chrome.exe') { throw 'chrome mistaken for a game' }
# settings: unknown keys ignored, ranges clamped, fractional volume kept
$settingsFile = Join-Path $tmp 'settings.json'
Set-Settings ('{"volume":0.5,"bogus":1,"salesMinutes":3,"currency":"EUR<x>","notifyDeals":false}' | ConvertFrom-Json)
if ($settings.volume -ne 0.5 -or $settings.salesMinutes -ne 10 -or $settings.currency -ne 'EUR' -or $settings.notifyDeals -or $settings.ContainsKey('bogus')) { throw "settings validation wrong: $($settings | ConvertTo-Json -Compress)" }
# price watch: an empty saved list loads as empty, not as one phantom entry
'[]' | Set-Content (Join-Path $tmp 'w.json'); $watchFile = Join-Path $tmp 'w.json'
$watch.list.Clear(); foreach ($w in (Get-Content $watchFile -Raw | ConvertFrom-Json)) { if ($w.id) { [void]$watch.list.Add($w) } }
if ($watch.list.Count -ne 0) { throw "empty watch list loaded as $($watch.list.Count) entries" }

# store search: the region is a plain two-letter country code, and the search actually returns games
if ($storeCountry -cnotmatch '^[A-Z]{2}$') { throw "bad store country '$storeCountry'" }
if (-not @(Find-StoreGames 'portal').Count) { throw 'store search returned nothing (offline, or the region code is wrong)' }

# Steam XML: normal documents parse, documents carrying a DTD (entity tricks) are refused
if ((Read-SteamXml '<playerstats><game><gameName>X</gameName></game></playerstats>').playerstats.game.gameName -ne 'X') { throw 'steam xml parse failed' }
$refused = $false; try { Read-SteamXml '<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "boom">]><a>&x;</a>' | Out-Null } catch { $refused = $true }
if (-not $refused) { throw 'steam xml accepted a DTD' }
Remove-Item $tmp -Recurse -Force

$ach = Read-Achievements '[["usernews",{"data":[]}],["achievements",{"data":{"nTotal":10,"nAchieved":3,"vecHighlight":[{"strName":"Old","bAchieved":true,"rtUnlocked":1},{"strName":"New","bAchieved":true,"rtUnlocked":9}]}}]]'
if ($ach.got -ne 3 -or $ach.total -ne 10 -or $ach.recent[0].name -ne 'New') { throw "achievement parse failed" }
if ($null -ne (Read-Achievements '[["achievements",{"data":{"nTotal":0,"nAchieved":0}}]]')) { throw "zero-achievement game should be null" }
# a Steam library on an unplugged drive is skipped, not a crash (a friend's H: drive hid all their games)
$realSteam = $steam; $steam = Join-Path $env:TEMP "pulse-steam-$PID"; New-Item -ItemType Directory "$steam\steamapps" -Force | Out-Null
$gone = [char[]](72..90) | Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
"`"libraryfolders`" { `"0`" { `"path`" `"$($steam -replace '\\', '\\')`" } `"1`" { `"path`" `"${gone}:\\SteamLibrary`" } }" | Set-Content "$steam\steamapps\libraryfolders.vdf"
$libs = @(Get-SteamLibs); if ($libs.Count -ne 1 -or $libs[0] -ne $steam) { throw "missing-drive library not skipped: $libs" }
$null = Get-GameName '999999999'  # walks every library; must not throw
Remove-Item $steam -Recurse -Force; $steam = $realSteam
# a cache file PowerShell 5 can't parse (same key in two cases) must not crash anything
$badJson = Join-Path $env:TEMP "pulse-bad-$PID.json"; '[["achievements",{"data":{"a":1,"A":2}}]]' | Set-Content $badJson
if ($null -ne (Read-LibraryAchievements $badJson 3>$null)) { throw 'unreadable library cache should give nothing' }; Remove-Item $badJson

# data files: a file cut off mid-save (all NUL bytes, like after a shutdown) is set aside, not fatal; saves leave no temp file and read back
New-Item -ItemType Directory $tmp -Force | Out-Null
$cut = Join-Path $tmp 'cut.json'; [IO.File]::WriteAllBytes($cut, (New-Object byte[] 543))
$logBefore = if (Test-Path (Join-Path $PSScriptRoot 'pulse.log')) { (Get-Content (Join-Path $PSScriptRoot 'pulse.log')).Count } else { 0 }
$h = Read-JsonHash $cut
if ($h.Count -ne 0 -or (Test-Path $cut) -or -not (Get-ChildItem $tmp -Filter 'cut.json.broken-*')) { throw 'cut-off data file was not set aside' }
Save-Json @{ a = 1; s = 'Overwatch' + [char]0xAE } (Join-Path $tmp 'ok.json'); Save-Json @{ a = 2; s = 'x' } (Join-Path $tmp 'ok.json')
if ((Read-JsonFile (Join-Path $tmp 'ok.json')).a -ne 2 -or (Test-Path (Join-Path $tmp 'ok.json.tmp'))) { throw 'safe save failed' }
Save-Json @{ s = 'Overwatch' + [char]0xAE } (Join-Path $tmp 'u.json'); if ((Read-JsonHash (Join-Path $tmp 'u.json')).s -ne ('Overwatch' + [char]0xAE)) { throw 'safe save mangled non-ASCII' }
Remove-Item $tmp -Recurse -Force
$plog = Get-Content (Join-Path $PSScriptRoot 'pulse.log'); if ($plog.Count -gt $logBefore) { $plog | Select-Object -First $logBefore | Set-Content (Join-Path $PSScriptRoot 'pulse.log') }  # don't leave the test's note in the real log

# movie theater: keys validated, sign-in uses PKCE + one-time state, ids can't steer the API path
New-Item -ItemType Directory $tmp -Force | Out-Null; $ytFile = Join-Path $tmp 'youtube.json'; $yt = @{}
foreach ($bad in @{ clientId = 'evil&redirect_uri=x'; clientSecret = 'abcdefghijkl' }, @{ clientId = 'abc.apps.googleusercontent.com'; clientSecret = 'short' }) {
  try { Set-YtKeys ([pscustomobject]$bad); throw 'accepted' } catch { if ("$_" -eq 'accepted') { throw "bad YouTube keys accepted: $($bad.clientId)" } }
}
Set-YtKeys ([pscustomobject]@{ clientId = ' 123-abc.apps.googleusercontent.com '; clientSecret = 'GOCSPX-abc_DEF-123' })
if (-not (Get-YtStatus).keys -or (Get-YtStatus).signedIn) { throw 'YouTube status wrong after saving keys' }
$u = Start-YtLogin
if ($u -notmatch '^https://accounts\.google\.com/.*code_challenge_method=S256' -or $u -notmatch "state=$([regex]::Escape($ytAuth.state))" -or $u -notmatch 'client_id=123-abc\.apps') { throw "sign-in URL wrong: $u" }
$q = New-Object Collections.Specialized.NameValueCollection; $q['state'] = 'forged'; $q['code'] = 'x'
try { Complete-YtLogin $q; throw 'accepted' } catch { if ("$_" -eq 'accepted') { throw 'forged sign-in state accepted' } }
if ($ytAuth.state) { $q['state'] = $ytAuth.state.ToUpper(); try { Complete-YtLogin $q; throw 'accepted' } catch { if ("$_" -eq 'accepted') { throw 'state compared case-insensitively' } } }
foreach ($args2 in @('playlist', 'x&mine=true', ''), @('channel', 'UCabc', ''), @('liked', '', 'a&b'), @('nope', '', '')) {
  try { Get-YtList @args2; throw 'accepted' } catch { if ("$_" -eq 'accepted') { throw "bad YouTube list request accepted: $args2" } }
}
$v = ConvertTo-YtItem ('{"kind":"youtube#playlistItem","snippet":{"title":"Hi","videoOwnerChannelTitle":"Ch","resourceId":{"videoId":"dQw4w9WgXcQ"},"thumbnails":{"medium":{"url":"https://i.ytimg.com/x.jpg"}}}}' | ConvertFrom-Json)
if ($v.kind -ne 'video' -or $v.id -ne 'dQw4w9WgXcQ' -or $v.channel -ne 'Ch') { throw 'playlist item mapping wrong' }
if (ConvertTo-YtItem ('{"kind":"youtube#playlistItem","snippet":{"title":"Private video","resourceId":{"videoId":"x"}}}' | ConvertFrom-Json)) { throw 'private video kept' }
# search: refused when empty or too long (before any request), results decoded from YouTube's HTML-escaped titles
foreach ($bq in '', '   ', ('a' * 101)) { try { Get-YtList 'search' '' '' $bq; throw 'accepted' } catch { if ("$_" -eq 'accepted') { throw "bad search accepted: '$bq'" } } }
$v = ConvertTo-YtItem ('{"kind":"youtube#searchResult","id":{"kind":"youtube#video","videoId":"dQw4w9WgXcQ"},"snippet":{"title":"Don&#39;t &amp; Stop","channelTitle":"A &amp; B","thumbnails":{"medium":{"url":"https://i.ytimg.com/x.jpg"}}}}' | ConvertFrom-Json)
if ($v.kind -ne 'video' -or $v.id -ne 'dQw4w9WgXcQ' -or $v.title -ne "Don't & Stop" -or $v.channel -ne 'A & B') { throw "search result mapping wrong: $($v | ConvertTo-Json -Compress)" }
Remove-Item $tmp -Recurse -Force

"ok"
