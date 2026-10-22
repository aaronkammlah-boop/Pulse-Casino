# Puts a "Pulse Casino" shortcut (poker-chip icon) on the desktop that starts Pulse.ps1 with no console. Re-run if you move this folder.
Add-Type -AssemblyName System.Drawing
$ico = Join-Path $PSScriptRoot 'pulse.ico'

# draw a 256px chip and wrap the PNG in an .ico (Windows reads PNG-in-ICO since Vista)
$bmp = New-Object Drawing.Bitmap 256, 256
$g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
$g.FillEllipse([Drawing.Brushes]::White, 4, 4, 248, 248)
$red = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(179, 18, 27))
for ($a = 0; $a -lt 360; $a += 45) { $g.FillPie($red, 4, 4, 248, 248, $a, 30) }
$g.FillEllipse($red, 40, 40, 176, 176)
$g.DrawEllipse((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(227, 193, 100)), 8), 52, 52, 152, 152)
$fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
$g.DrawString([string][char]0x2660, (New-Object Drawing.Font 'Segoe UI Symbol', 92), [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 4, 256, 256), $fmt)
$ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $png = $ms.ToArray()
$w = New-Object IO.BinaryWriter ([IO.File]::Create($ico))
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)                       # header: icon, 1 image
$w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)          # 256x256, no palette
$w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$png.Length); $w.Write([uint32]22)
$w.Write($png); $w.Close()

$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Pulse Casino.lnk'))
# conhost --headless runs PowerShell with no console window at all; RemoteSigned runs these unblocked local scripts but still refuses downloaded ones
$lnk.TargetPath = "$env:WINDIR\System32\conhost.exe"
$lnk.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File `"$(Join-Path $PSScriptRoot 'Pulse.ps1')`""
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.IconLocation = $ico
$lnk.Save()
"Shortcut created: $($lnk.FullName)"
