Yurich Connect Portable

Важно: не запускай YurichConnect.exe прямо внутри ZIP-архива.

Как запускать:

1. Распакуй YurichConnect_Windows_Portable.zip в отдельную папку.
2. Открой распакованную папку Yurich Connect.
3. Запусти YurichConnect.exe.
4. Если приложение попросит права администратора, нажми "Перезапустить от имени администратора" и разреши Windows UAC.

START_YURICH_CONNECT.cmd оставлен для совместимости. Он тоже запускает приложение через UAC.

Если приложение не стартует:

- проверь, что рядом есть YurichConnect.exe, flutter_windows.dll и папка runtime;
- проверь, что рядом есть MSVCP140.dll, VCRUNTIME140.dll и VCRUNTIME140_1.dll;
- установи Microsoft Visual C++ Redistributable 2015-2022 x64:
  https://aka.ms/vs/17/release/vc_redist.x64.exe

Логи:

- %APPDATA%\Yurich Connect\logs\yurich.log
- %APPDATA%\Yurich Connect\logs\sing-box.log
- %APPDATA%\Yurich Connect\logs\naive.log

Диагностика:

- %APPDATA%\Yurich Connect\diagnostics\report.zip

Удаление portable:

1. Отключи VPN.
2. Запусти uninstall_yurich_connect.ps1 от имени администратора.
3. Подтверди удаление словом YES.

Безопасность:

- скачивай Yurich Connect только из официального GitHub Releases;
- не публикуй свои Yurich ID, VLESS/Naive/Hysteria ссылки и токены.
