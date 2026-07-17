# Установка Yurich Connect для Windows

## Installer

1. Скачайте `YurichConnect_Setup.exe` из официального GitHub Releases.
2. Запустите файл.
3. Подтвердите UAC, если его запросит установщик.
4. Установщик поставит приложение в `C:\Program Files\Yurich Connect`.
5. Будут созданы ярлыки рабочего стола и меню Пуск.
6. При обновлении профили, подписки и настройки сохраняются в `%APPDATA%\Yurich Connect`.
7. После первого запуска подключитесь в **Stable Proxy Mode**.

Stable Proxy Mode не требует TUN, Wintun и прав администратора. Это режим по умолчанию для обычной работы.

Advanced TUN Mode включайте только если нужен полный системный туннель, split routing или Wintun. Этот режим может требовать права администратора.

Чтобы `ssh.exe`, Git, PowerShell, Windows Terminal, PuTTY и WinSCP шли через VPN, включите Advanced TUN Mode, затем переключатель **SSH и терминал через VPN** и переподключитесь. В Stable Proxy Mode OpenSSH идёт напрямую, если отдельно не настроен SOCKS `127.0.0.1:20809`.

Чтобы Codex CLI работал через VPN, включите Advanced TUN Mode и **Codex CLI только через VPN**, затем переподключитесь. Yurich Connect принудительно маршрутизирует `codex.exe`, `openai-codex.exe` и Codex-приложения с подходящим путём процесса. Общий `node.exe` не перехватывается, чтобы не направлять через VPN чужие Node.js-проекты.

Автостарт создаётся через Планировщик заданий при входе пользователя без задержки и запускает Yurich Connect скрытым в трее. UAC нужен только при включении или отключении раннего автостарта. Если UAC отменён, приложение сохраняет резервный автостарт через `HKCU\\Run`.

Постоянный firewall kill switch в этой версии не включён. Advanced TUN использует строгую маршрутизацию во время работы ядра; полноценная защита после аварийного завершения будет добавляться через отдельную Windows-службу с аварийным восстановлением сети.

## Portable

1. Скачайте `YurichConnect_Windows_Portable.zip`.
2. Распакуйте архив.
3. Откройте папку `Yurich Connect`.
4. Запустите `START_YURICH_CONNECT.cmd` или `YurichConnect.exe`.
5. Если Windows попросит права администратора для Advanced TUN Mode, подтвердите UAC.

Не запускайте приложение прямо из ZIP-просмотрщика Windows.

## Подписки Yurich ID

В приложение можно добавить одиночный профиль или Yurich ID подписку с несколькими серверами. После импорта Yurich Connect покажет профили списком и сможет проверить ping серверов.

Поддерживаются VLESS Reality, VLESS TLS, VLESS XHTTP через встроенный Xray-core в Stable Proxy Mode, NaiveProxy, Hysteria 1/2, raw sing-box JSON и HTML-страницы панели с raw-ссылками внутри.

XHTTP-профили запускаются только в Stable Proxy Mode. Перед переключением Yurich Connect проверяет Xray-конфиг; `host`, `path`, `mode`, `extra` и SNI берутся из подписки без подмены. Если включён Advanced TUN Mode, приложение попросит его отключить и не остановит текущее рабочее соединение.

## Логи и диагностика

Логи находятся в `%APPDATA%\Yurich Connect\logs`:

- `yurich.log`
- `sing-box.log`
- `xray.log`
- `naive.log`

Диагностический отчёт сохраняется в `%APPDATA%\Yurich Connect\diagnostics\report.zip`.

В отчёте маскируются UUID, пароли, токены, private keys, VLESS/NaiveProxy/Hysteria-ссылки и Yurich ID subscription URL.

## Windows Defender и SmartScreen

Yurich Connect содержит сетевые компоненты. В Advanced TUN Mode приложение может создавать VPN-интерфейс и маршруты Windows. Новая неподписанная сборка может вызвать предупреждение Defender или SmartScreen.

Скачивайте установщик только из официальных GitHub Releases и сверяйте SHA-256 из релиза.

## Удаление

Installer-версия удаляется через параметры Windows или `uninstall_yurich_connect.ps1` из папки установки.

Portable-версия удаляется вручную: закройте приложение, убедитесь, что VPN отключён, затем удалите распакованную папку. Пользовательские данные находятся в `%APPDATA%\Yurich Connect`.
