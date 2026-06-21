@echo off
setlocal EnableExtensions

cd /d "%~dp0"
set "APP_DIR=%CD%"
set "APP_EXE=%APP_DIR%\YurichConnect.exe"

echo "%APP_DIR%" | findstr /i /c:"\\Temp\\" /c:"\\Temporary Internet Files\\" /c:"\\Compressed\\" >nul
if not errorlevel 1 (
  echo Yurich Connect нельзя запускать прямо из ZIP-архива.
  echo Сначала распакуй папку приложения или установи Yurich Connect через установщик.
  pause
  exit /b 1
)

if not exist "%APP_EXE%" (
  echo YurichConnect.exe не найден рядом с START_YURICH_CONNECT.cmd.
  echo Запускай этот файл только из папки Yurich Connect.
  pause
  exit /b 1
)

start "" /D "%APP_DIR%" "%APP_EXE%"
exit /b 0
