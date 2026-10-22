@echo off
rem Double-click this to install Pulse Casino. Windows blocks .ps1 scripts by default ("Run with PowerShell" then closes instantly).
rem So: clear the downloaded-from-internet mark on this folder's files, then run install.ps1 under RemoteSigned for this one run only.
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0.' | Unblock-File"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0install.ps1" -NoPause
echo.
pause
