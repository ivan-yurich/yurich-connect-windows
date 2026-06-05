@echo off
setlocal EnableExtensions

cd /d "%~dp0"
set "APP_DIR=%CD%"
set "APP_EXE=%APP_DIR%\AurumVPN.exe"

echo "%APP_DIR%" | findstr /i /c:"\\Temp\\" /c:"\\Temporary Internet Files\\" /c:"\\Compressed\\" >nul
if not errorlevel 1 (
  echo Aurum VPN нельзя запускать прямо из ZIP-архива.
  echo Сначала распакуй папку приложения или установи Aurum VPN через установщик.
  pause
  exit /b 1
)

if not exist "%APP_EXE%" (
  echo AurumVPN.exe не найден рядом с START_AURUM_VPN.cmd.
  echo Запускай этот файл только из папки Aurum VPN.
  pause
  exit /b 1
)

net session >nul 2>&1
if %errorlevel%==0 (
  start "" /D "%APP_DIR%" "%APP_EXE%"
  exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$exe = '%APP_EXE%'; $dir = '%APP_DIR%';" ^
  "try { Start-Process -FilePath $exe -WorkingDirectory $dir -Verb RunAs -ErrorAction Stop; exit 0 }" ^
  "catch { [Console]::Error.WriteLine('Пользователь отменил запрос прав администратора или Windows заблокировал запуск.'); exit 1223 }"

if errorlevel 1 (
  echo.
  echo Aurum VPN не запущен: нужны права администратора для Windows TUN/Wintun.
  pause
  exit /b 1
)

exit /b 0
