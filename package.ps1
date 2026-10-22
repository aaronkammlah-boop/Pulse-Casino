# Builds ..\pulse-share\PulseCasino.zip for friends. Run: powershell -ExecutionPolicy Bypass -File package.ps1
# Allow-list only: your data files (usage, songs, store, trophies...) live in this same folder, so nothing outside $files may ever be added.
$ErrorActionPreference = 'Stop'
$files = 'app.ps1', 'Pulse.ps1', 'index.html', 'pulse.ico', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll', 'install.ps1', 'Install.cmd', 'README.txt'
$outDir = Join-Path (Split-Path $PSScriptRoot) 'pulse-share'
$zip = Join-Path $outDir 'PulseCasino.zip'

$missing = @($files | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) })
if ($missing) { throw "missing program files: $($missing -join ', ')" }

# the code reads whoever is signed in to Steam; a SteamID64 in a shipped text file would mean an account slipped in (76561197960265728 is the ID base constant, not an account)
foreach ($f in $files | Where-Object { $_ -match '\.(ps1|html|txt)$' }) {
  if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $f)) -match '7656119(?!7960265728)\d{10}') { throw "$f contains a SteamID ($($Matches[0])); remove it before sharing" }
}

New-Item -ItemType Directory $outDir -Force | Out-Null
if (Test-Path $zip) { Remove-Item $zip }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  foreach ($f in $files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $PSScriptRoot $f), "PulseCasino/$f", 'Optimal') }
} finally { $archive.Dispose() }

# read the zip back: show exactly what goes out, and refuse anything not on the list
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try { $entries = @($archive.Entries | ForEach-Object { [pscustomobject]@{ File = $_.FullName; KB = [math]::Ceiling($_.Length / 1KB) } }) } finally { $archive.Dispose() }
$extra = @($entries | Where-Object { $files -notcontains ($_.File -replace '^PulseCasino/') })
if ($extra -or $entries.Count -ne $files.Count) { Remove-Item $zip; throw "zip had unexpected entries: $($extra.File -join ', ')" }

$entries | Format-Table -AutoSize | Out-String | Write-Host
"Built $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 2)) MB, $($entries.Count) files, no personal data)"
