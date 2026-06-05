Aurum VPN Portable

Важно: не запускай AurumVPN.exe прямо внутри ZIP-архива.
Windows в таком режиме открывает только один exe без соседних DLL, поэтому приложение не сможет найти runtime-файлы.

Как запустить portable-версию:
1. Нажми "Извлечь все".
2. Открой распакованную папку Aurum VPN.
3. Запусти START_AURUM_VPN.cmd.
4. Подтверди запрос UAC. Для Windows TUN/Wintun нужны права администратора.

Если приложение не запускается:
- проверь, что рядом есть AurumVPN.exe, flutter_windows.dll и папка runtime;
- установи Microsoft Visual C++ Redistributable 2015-2022 x64:
  https://aka.ms/vs/17/release/vc_redist.x64.exe
- не запускай из ZIP, Desktop root, Downloads root или другой случайной папки.

Логи:
- %APPDATA%\Aurum VPN\logs\aurum.log
- %APPDATA%\Aurum VPN\logs\sing-box.log
- %APPDATA%\Aurum VPN\logs\naive.log

Диагностика:
- %APPDATA%\Aurum VPN\diagnostics\report.zip

Удаление portable-версии:
1. Отключи VPN.
2. Запусти uninstall_aurum_vpn.ps1 от имени администратора.
3. Введи YES для подтверждения.

Если Windows Defender ругается:
- скачивай Aurum VPN только из официального GitHub Releases;
- проверь SHA256 из релиза;
- если файл заблокирован, открой свойства файла и нажми "Разблокировать".
