# Pulse: the casino in its own window (WebView2) with a tray icon; the server (app.ps1) runs in a background runspace.
# Windows' Smart App Control blocks home-built .exe files, so the host is this script: PowerShell and the WebView2 DLLs are Microsoft-signed.
# Launched by the desktop shortcut without a console window. -Tray: start in the tray only (used when starting with Windows).
param([switch]$Tray)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$dir = $PSScriptRoot
$url = 'http://localhost:5577/'
function Log([string]$m) { Add-Content (Join-Path $dir 'pulse.log') "$(Get-Date -Format s) Pulse.ps1: $m" }

# one copy at a time: a second launch just asks the first to bring its window up
$created = $false
$mutex = New-Object Threading.Mutex($true, 'PulseCasino.SingleInstance', [ref]$created)
$showSignal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'PulseCasino.Show')
if (-not $created) { [void]$showSignal.Set(); return }

# the server runs in its own runspace so this thread stays free for the window
$ps = [PowerShell]::Create()
[void]$ps.AddCommand((Join-Path $dir 'app.ps1')).AddParameter('NoWindow', $true)
$server = $ps.BeginInvoke()

$icon = New-Object Drawing.Icon (Join-Path $dir 'pulse.ico')
$bg = [Drawing.Color]::FromArgb(18, 3, 10)  # the casino's backdrop colour: no white flash while loading
$form = New-Object Windows.Forms.Form -Property @{ Text = 'Pulse Casino'; Icon = $icon; Width = 1280; Height = 880; StartPosition = 'CenterScreen'; BackColor = $bg }

Add-Type -Path (Join-Path $dir 'Microsoft.Web.WebView2.Core.dll'), (Join-Path $dir 'Microsoft.Web.WebView2.WinForms.dll')
$web = New-Object Microsoft.Web.WebView2.WinForms.WebView2 -Property @{ Dock = 'Fill'; DefaultBackgroundColor = $bg }
$web.CreationProperties = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties -Property @{
  UserDataFolder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PulseCasino\WebView2' }
$form.Controls.Add($web)

$state = @{ quitting = $false; toldAboutTray = $false; retries = 0; started = $false }
$retry = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
$retry.add_Tick({ $retry.Stop(); $web.CoreWebView2.Navigate($url) })

function Open-External([string]$uri) {
  # only Steam links (Play/Install/Store) and real web pages leave the window; anything else a page might try is ignored
  # steam: only the three link kinds the page makes; other steam:// commands (uninstall, console, extra launch options) are refused
  if ($uri -match '^(steam://(rungameid|store|install)/\d+|https://\S+)$') { try { Start-Process $uri } catch { Log "couldn't open $uri : $_" } }
}

$web.add_CoreWebView2InitializationCompleted({
  param($s, $e)
  if (-not $e.IsSuccess) {
    # no WebView2 runtime on this PC: fall back to an Edge app window
    Log "built-in window unavailable, using Edge instead: $($e.InitializationException.Message)"
    $form.Hide(); $state.started = $false
    try { Start-Process msedge "--app=$url" } catch { Start-Process $url }
    return
  }
  $core = $web.CoreWebView2
  $core.Settings.IsStatusBarEnabled = $false
  $core.add_NavigationStarting({ param($s, $e) if (-not $e.Uri.StartsWith($url)) { $e.Cancel = $true; Open-External $e.Uri } })
  $core.add_NewWindowRequested({ param($s, $e) $e.Handled = $true; Open-External $e.Uri })
  $core.add_NavigationCompleted({
    param($s, $e)
    # the server may still be starting when the window opens: retry for up to ~30s
    if (-not $e.IsSuccess -and "$($e.WebErrorStatus)" -ne 'OperationCanceled' -and $state.retries++ -lt 30) { $retry.Start() }
  })
})

function Show-Window {
  if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
  $form.Show(); $form.Activate()
  if (-not $state.started) { $state.started = $true; $web.Source = [uri]$url }  # setting Source starts WebView2 with the CreationProperties above
}

$form.add_FormClosing({
  param($s, $e)
  if ($state.quitting -or $e.CloseReason -ne 'UserClosing') { return }
  $e.Cancel = $true  # closing the window keeps Pulse tracking in the tray
  $form.Hide()
  if (-not $state.toldAboutTray) { $state.toldAboutTray = $true; $trayIcon.ShowBalloonTip(4000, 'Pulse is still running', 'It keeps tracking in the tray. Right-click the chip icon to quit.', 'Info') }
})

# --- tray icon ---
# "Start with Windows" = a copy of the desktop shortcut in your Startup folder (plus -Tray), like any normal app.
# No registry autostart and no launch command spelled out here: antivirus heuristics read those as malware persistence.
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Pulse Casino.lnk'
function Set-StartWithWindows([bool]$on) {
  if (-not $on) { Remove-Item $startupLnk -ErrorAction SilentlyContinue; return $true }
  $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Pulse Casino.lnk'
  if (-not (Test-Path $desktopLnk)) { return $false }
  $sh = New-Object -ComObject WScript.Shell
  $src = $sh.CreateShortcut($desktopLnk); $dst = $sh.CreateShortcut($startupLnk)
  $dst.TargetPath = $src.TargetPath; $dst.Arguments = "$($src.Arguments) -Tray"; $dst.WorkingDirectory = $src.WorkingDirectory; $dst.IconLocation = $src.IconLocation
  $dst.Save(); $true
}
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open Pulse', $null, { Show-Window })
$auto = New-Object Windows.Forms.ToolStripMenuItem 'Start with Windows'
$auto.CheckOnClick = $true
$auto.Checked = Test-Path $startupLnk
$auto.add_CheckedChanged({
  if (-not (Set-StartWithWindows $auto.Checked)) {
    $auto.Checked = $false
    [void][Windows.Forms.MessageBox]::Show('Pulse needs its desktop shortcut for this. Run the installer (or make-shortcut.ps1) again, then try once more.', 'Pulse Casino')
  }
})
[void]$menu.Items.Add($auto)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Quit Pulse', $null, {
  $state.quitting = $true
  $trayIcon.Visible = $false
  try { $ps.Stop() } catch {}  # stops app.ps1's loop; its finally block saves app usage and closes the port
  [Windows.Forms.Application]::Exit()
})
$trayIcon = New-Object Windows.Forms.NotifyIcon -Property @{ Icon = $icon; Text = 'Pulse Casino'; ContextMenuStrip = $menu; Visible = $true }
$trayIcon.add_DoubleClick({ Show-Window })

# twice a second: a second launch asking for the window, or the server stopping on its own
$watch = New-Object Windows.Forms.Timer -Property @{ Interval = 500 }
$watch.add_Tick({
  if ($showSignal.WaitOne(0)) { Show-Window }
  if ($server.IsCompleted -and -not $state.quitting) {
    $watch.Stop()
    Log "server ended: $(($ps.Streams.Error | ForEach-Object { "$_" }) -join ' | ') $($ps.InvocationStateInfo.Reason)"
    $trayIcon.Visible = $false
    [void][Windows.Forms.MessageBox]::Show("Pulse stopped unexpectedly. Details are in pulse.log.`n`nIf an older Pulse is still running, close it in Task Manager and start Pulse again.", 'Pulse Casino', 'OK', 'Warning')
    [Windows.Forms.Application]::Exit()
  }
})
$watch.Start()

if (-not $Tray) { Show-Window }
try { [Windows.Forms.Application]::Run() }
catch { Log "window crashed: $_" }
finally { $trayIcon.Visible = $false; if (-not $state.quitting) { try { $ps.Stop() } catch {} }; $mutex.ReleaseMutex() }
