@echo off
rem Double-click this when the phone cannot reach this machine. It asks for
rem administrator rights (the only way to touch the firewall), removes the
rem inbound block rules that Windows creates when its prompt was dismissed, and
rem allows the sync ports in on every profile.
setlocal
net session >nul 2>&1
if errorlevel 1 (
	echo Asking for administrator rights...
	powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
	exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-lan-sync-firewall.ps1"
echo.
pause
