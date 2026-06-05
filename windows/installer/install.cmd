@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_yurich_connect.ps1" -Payload "%~dp0YurichConnect_payload.zip"
exit /b %ERRORLEVEL%
