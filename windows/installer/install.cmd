@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_aurum_vpn.ps1" -Payload "%~dp0AurumVPN_payload.zip"
exit /b %ERRORLEVEL%
