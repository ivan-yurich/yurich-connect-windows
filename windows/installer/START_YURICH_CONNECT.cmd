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
  echo Yurich Connect не запущен: нужны права администратора для Windows TUN/Wintun.
  pause
  exit /b 1
)

exit /b 0
