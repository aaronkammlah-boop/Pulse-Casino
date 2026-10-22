# Installs Pulse Casino for the current Windows user. Run: double-click Install.cmd (plain "Run with PowerShell" is blocked by the default execution policy).
# Copies the program to %LOCALAPPDATA%\PulseCasino\app, clears the downloaded-from-internet mark, adds a desktop shortcut and starts Pulse.
# -InstallDir / -NoShortcut / -NoStart / -NoPause exist so the packager can dry-run this into a temp folder.
param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PulseCasino\app'),
  [switch]$NoShortcut,
  [switch]$NoStart,
  [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$files = 'app.ps1', 'Pulse.ps1', 'index.html', 'pulse.ico', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll', 'README.txt'

function Done([int]$code) {
  if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
  exit $code
}

try {
  Write-Host 'Installing Pulse Casino...' -ForegroundColor Cyan

  $missing = @($files | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) })
  if ($missing) { throw "These files are missing next to install.ps1: $($missing -join ', '). Extract the whole zip first, then run install.ps1 from the extracted folder." }

  $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
  if (-not $steam -or -not (Test-Path $steam)) {
    Write-Host ''
    Write-Host 'WARNING: Steam does not seem to be installed for this Windows user.' -ForegroundColor Yellow
    Write-Host 'Pulse reads your games, playtime and achievements from Steam, so most of it will be empty.' -ForegroundColor Yellow
    Write-Host 'Install Steam from https://store.steampowered.com/about/ and sign in, then open Pulse again.' -ForegroundColor Yellow
    Write-Host ''
  } else { Write-Host "Found Steam at $steam" }

  # an already-running Pulse keeps its DLLs locked, so updating over it would fail halfway
  $running = $null
  if ((Test-Path (Join-Path $InstallDir 'WebView2Loader.dll')) -and [Threading.Mutex]::TryOpenExisting('PulseCasino.SingleInstance', [ref]$running)) {
    $running.Dispose()
    throw 'Pulse Casino is running. Right-click its tray icon (near the clock) and quit it, then run install.ps1 again.'
  }

  New-Item -ItemType Directory $InstallDir -Force | Out-Null
  foreach ($f in $files) {
    $dest = Join-Path $InstallDir $f
    Copy-Item (Join-Path $PSScriptRoot $f) $dest -Force
    Unblock-File $dest   # removes the "downloaded from the internet" mark so Windows lets it load
  }
  Write-Host "Copied $($files.Count) files to $InstallDir"

  $launch = Join-Path $InstallDir 'Pulse.ps1'
  if (-not $NoShortcut) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Pulse Casino.lnk'))
    # conhost --headless runs PowerShell with no console window at all; RemoteSigned runs these unblocked local scripts but still refuses downloaded ones
    $lnk.TargetPath = "$env:WINDIR\System32\conhost.exe"
    $lnk.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File `"$launch`""
    $lnk.WorkingDirectory = $InstallDir
    $lnk.IconLocation = Join-Path $InstallDir 'pulse.ico'
    $lnk.Save()
    Write-Host "Desktop shortcut created: $($lnk.FullName)"
  }

  if (-not $NoStart) {
    Start-Process "$env:WINDIR\System32\conhost.exe" "--headless powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File `"$launch`"" -WorkingDirectory $InstallDir
    Write-Host 'Starting Pulse Casino (its window opens in a few seconds).'
  }

  Write-Host ''
  Write-Host 'Done! Open it any time with the "Pulse Casino" icon on your desktop.' -ForegroundColor Green
  Done 0
} catch {
  Write-Host ''
  Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
  Done 1
}
