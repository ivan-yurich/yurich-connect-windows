# Yurich Connect for Windows

Yurich Connect is the Windows client in the Yurich ecosystem for stable access to foreign services, Yurich ID subscriptions, and manual VPN/proxy profiles.

It runs on Windows 10/11 and uses Yurich Core powered by sing-box, Xray-core, NaiveProxy, Hysteria, and optional Wintun.

## English

### Product Modes

- **Stable Proxy Mode** is the default and recommended mode. It does not use TUN, Wintun, or administrator rights. It starts a local mixed proxy at `127.0.0.1:20808` and a SOCKS proxy at `127.0.0.1:20809`.
- **Advanced TUN Mode** is an optional advanced mode for all-app routing, Wintun, DNS hijack, split routing, and full-system VPN behavior. It may require administrator rights.

Start with Stable Proxy Mode unless you explicitly need a full TUN tunnel.

### Subscriptions And Profiles

Yurich Connect imports single profile links and full subscriptions with multiple servers.

Supported inputs:

- Yurich ID subscription URL;
- VLESS Reality and VLESS TLS over TCP, WebSocket, gRPC, HTTP/H2, and HTTPUpgrade;
- VLESS XHTTP through the bundled Xray-core in Stable Proxy Mode;
- NaiveProxy;
- Hysteria 1 and Hysteria 2;
- raw sing-box JSON;
- panel HTML pages when raw profile links are embedded inside.

XHTTP profiles preserve the subscription `host`, `path`, `mode`, `extra`, and SNI settings. They are validated by the bundled Xray-core before the current connection is stopped. XHTTP is intentionally unavailable in Advanced TUN Mode until Xray TUN routing can be isolated from the sing-box/Wintun lifecycle.

### ChatGPT, OpenAI, And Codex Stability

Yurich Connect separates ChatGPT website routing from Codex CLI routing:

- **ChatGPT website through VPN** is enabled by default, so `chatgpt.com` and OpenAI web assets use the current VPN/proxy route.
- **Codex CLI direct** can be enabled separately for Codex processes when long-running Codex sessions should bypass reconnect-sensitive routing.

For long WebSocket sessions, the app avoids aggressive tunnel restarts. A single health-check timeout does not kill the VPN, multiple endpoints are checked, reconnect watchdog is softened during active traffic, and DNS/TCP/WebSocket/reconnect history diagnostics are written to logs.

### SSH, Early Startup, And Leak Protection

- **Developer mode** routes SSH, Git, and terminal processes directly.
- **SSH and terminal through VPN** forces `ssh.exe`, SCP/SFTP, Git, PowerShell, CMD, Windows Terminal, PuTTY, and WinSCP through the VPN. Transparent process routing is available only in Advanced TUN Mode.
- **Start with Windows** creates an immediate elevated logon task and starts the UI hidden in the tray. UAC is requested only while configuring the task. If Task Scheduler registration is denied, the app keeps a per-user `HKCU\\Run` fallback.

Advanced TUN uses strict routing while Yurich Core is running. A persistent firewall kill switch is intentionally not enabled yet: safe crash protection requires a signed Windows Service/WFP helper, explicit VPN-server/bootstrap exceptions, and an emergency restore path. A naive global firewall block can leave Windows completely offline.

### Install

1. Download `YurichConnect_Setup.exe` from the official GitHub Releases page.
2. Run the installer.
3. Start Yurich Connect.
4. Import a Yurich ID subscription or a single profile link.
5. Connect in Stable Proxy Mode first.
6. Enable Windows system proxy only when regular apps should use `127.0.0.1:20808` / `127.0.0.1:20809`.

Portable build:

1. Download `YurichConnect_Windows_Portable.zip`.
2. Extract the archive first.
3. Open the `Yurich Connect` folder.
4. Run `START_YURICH_CONNECT.cmd` or `YurichConnect.exe`.

Do not run the portable build directly from the Windows ZIP viewer.

### Administrator Rights

Stable Proxy Mode does not need administrator rights. Administrator rights are only needed for the installer and Advanced TUN Mode, because Windows must create a TUN/Wintun network interface and routes.

### If The App Does Not Start

- Install Microsoft Visual C++ Redistributable 2015-2022 x64: <https://aka.ms/vs/17/release/vc_redist.x64.exe>
- Reinstall the latest `YurichConnect_Setup.exe`.
- Check `%APPDATA%\Yurich Connect\logs\yurich.log`.
- Create a diagnostics report from the app and send it to the developer.

### Logs And Diagnostics

Logs are stored under `%APPDATA%\Yurich Connect\logs`:

- `yurich.log`
- `sing-box.log`
- `xray.log`
- `naive.log`

Diagnostics are created under `%APPDATA%\Yurich Connect\diagnostics` as `report.zip`.

The report masks UUIDs, passwords, tokens, private keys, `vless://` links, `naive+https://` links, Hysteria links, and Yurich ID subscription URLs.

### Updates

The app checks GitHub Releases for newer Windows builds. Update downloads are written to a temporary `.download` file first, checked, and only then renamed to the final installer file.

### Windows Defender

Unsigned VPN/proxy tools may trigger Defender or SmartScreen warnings. Download only from the official GitHub Releases page and verify the SHA-256 checksum from the release.

### Rebranding

The old Aurum VPN name is no longer used for the Windows product. Current names are Yurich Connect, Yurich Desktop, Yurich Core, and Yurich ID.

## Русский

### Режимы продукта

- **Stable Proxy Mode** - режим по умолчанию и основной сценарий для обычного пользователя. Он не использует TUN, Wintun и права администратора. Поднимает mixed proxy на `127.0.0.1:20808` и SOCKS proxy на `127.0.0.1:20809`.
- **Advanced TUN Mode** - отдельный продвинутый режим для маршрутизации всех приложений, Wintun, DNS hijack, split routing и полного системного VPN. Может требовать права администратора.

Начинайте со Stable Proxy Mode, если нет явной необходимости в полном TUN-туннеле.

### Подписки и профили

Yurich Connect импортирует одиночные ссылки профилей и подписки, внутри которых может быть несколько серверов.

Поддерживаются:

- Yurich ID subscription URL;
- VLESS Reality и VLESS TLS через TCP, WebSocket, gRPC, HTTP/H2 и HTTPUpgrade;
- VLESS XHTTP через встроенный Xray-core в Stable Proxy Mode;
- NaiveProxy;
- Hysteria 1 и Hysteria 2;
- raw sing-box JSON;
- HTML-страницы панели, если внутри есть raw-ссылки на профили.

Для XHTTP сохраняются переданные подпиской `host`, `path`, `mode`, `extra` и SNI. До остановки текущего соединения конфиг проверяется встроенным Xray-core. В Advanced TUN Mode XHTTP намеренно недоступен, пока TUN-маршрутизация Xray не будет изолирована от жизненного цикла sing-box/Wintun.

### Стабильность ChatGPT, OpenAI и Codex

Yurich Connect разделяет маршрутизацию сайта ChatGPT и Codex CLI:

- **ChatGPT сайт через VPN** включён по умолчанию, поэтому `chatgpt.com` и web-ресурсы OpenAI идут через текущий VPN/proxy маршрут.
- **Codex CLI напрямую** можно включить отдельно для процессов Codex, когда длинные Codex-сессии должны обходить reconnect-чувствительные маршруты.

Для долгих WebSocket-сессий приложение не делает агрессивный перезапуск туннеля. Один health-check timeout не убивает VPN, проверяется несколько endpoint, reconnect watchdog смягчён во время активного трафика, а диагностика DNS/TCP/WebSocket/reconnect history пишется в логи.

### SSH, ранний автостарт и защита от утечек

- **Режим разработчика** направляет SSH, Git и терминалы напрямую.
- **SSH и терминал через VPN** принудительно направляет `ssh.exe`, SCP/SFTP, Git, PowerShell, CMD, Windows Terminal, PuTTY и WinSCP через VPN. Прозрачная маршрутизация процессов доступна только в Advanced TUN Mode.
- **Автостарт с Windows** создаёт задачу входа без задержки, с повышенными правами, и запускает интерфейс скрытым в трее. UAC запрашивается только при настройке. Если Планировщик заданий недоступен, остаётся резервный запуск текущего пользователя через `HKCU\\Run`.

Advanced TUN использует строгую маршрутизацию, пока Yurich Core работает. Постоянный firewall kill switch пока намеренно не включён: для безопасной защиты после сбоя нужен подписанный Windows Service/WFP helper, исключения для VPN-сервера и bootstrap, а также аварийное восстановление сети. Простое глобальное правило блокировки может полностью оставить Windows без интернета.

### Установка

1. Скачайте `YurichConnect_Setup.exe` из официального раздела GitHub Releases.
2. Запустите установщик.
3. Откройте Yurich Connect.
4. Импортируйте Yurich ID подписку или отдельную ссылку профиля.
5. Сначала подключитесь в Stable Proxy Mode.
6. Включайте системный proxy Windows только если обычным приложениям нужно использовать `127.0.0.1:20808` / `127.0.0.1:20809`.

Portable-версия:

1. Скачайте `YurichConnect_Windows_Portable.zip`.
2. Сначала распакуйте архив.
3. Откройте папку `Yurich Connect`.
4. Запустите `START_YURICH_CONNECT.cmd` или `YurichConnect.exe`.

Не запускайте portable-версию прямо из ZIP-просмотрщика Windows.

### Права администратора

Stable Proxy Mode не требует прав администратора. Права нужны только установщику и Advanced TUN Mode, потому что Windows должна создать TUN/Wintun интерфейс и маршруты.

### Если приложение не запускается

- Установите Microsoft Visual C++ Redistributable 2015-2022 x64: <https://aka.ms/vs/17/release/vc_redist.x64.exe>
- Переустановите свежий `YurichConnect_Setup.exe`.
- Проверьте `%APPDATA%\Yurich Connect\logs\yurich.log`.
- Сформируйте диагностический отчёт в приложении и отправьте разработчику.

### Логи и диагностика

Логи лежат в `%APPDATA%\Yurich Connect\logs`:

- `yurich.log`
- `sing-box.log`
- `xray.log`
- `naive.log`

Диагностика создаётся в `%APPDATA%\Yurich Connect\diagnostics` как `report.zip`.

В отчёте маскируются UUID, пароли, токены, private keys, `vless://` ссылки, `naive+https://` ссылки, Hysteria-ссылки и Yurich ID subscription URL.

### Обновления

Приложение проверяет Windows-сборки в GitHub Releases. Обновление сначала скачивается во временный `.download` файл, проверяется и только потом переименовывается в финальный установщик.

### Windows Defender

Неподписанные VPN/proxy инструменты иногда вызывают предупреждения Defender или SmartScreen. Скачивайте установщик только из официальных GitHub Releases и сверяйте SHA-256 из релиза.

### Ребрендинг

Старое название Aurum VPN больше не используется для Windows-продукта. Актуальные названия: Yurich Connect, Yurich Desktop, Yurich Core и Yurich ID.
