# Yurich Connect for Windows

**Yurich Connect** is the Windows app in the Yurich ecosystem. The Windows build
is distributed as **Yurich Desktop**, uses **Yurich Core** on top of sing-box and
Wintun, and supports **Yurich ID** subscriptions.

Brand map:

- Brand: `Yurich`
- App: `Yurich Connect`
- Panel: `Yurich Panel`
- Core: `Yurich Core`
- DNS: `Yurich DNS`
- Windows: `Yurich Desktop`
- Android: `Yurich Mobile`
- Subscription: `Yurich ID`
- Site: `Yurich Cloud`

## Features

- Flutter Desktop client for Windows.
- sing-box TUN mode with Wintun.
- VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, Yurich ID and raw
  sing-box JSON import.
- HTML subscription import for panel pages that contain raw links.
- Server latency panel with TCP ping for every imported profile.
- Auto-start with Windows through Task Scheduler with highest privileges.
- Auto-connect to the selected profile.
- Split tunneling by excluded `.exe` process names.
- Fast Yurich DNS mode for browser bursts with many tabs and mixed Russian and
  foreign sites.
- GitHub Releases update checks and in-app installer download.
- Traffic counters through the sing-box Clash API.
- Safe diagnostics with masked UUIDs, passwords, tokens and subscription URLs.

## Install

1. Download `YurichConnect_Setup.exe` from GitHub Releases.
2. Run it as administrator.
3. Allow Windows UAC.
4. After installation, choose whether to launch Yurich Connect immediately.

Portable users should extract `YurichConnect_Windows_Portable.zip` first and run
`START_YURICH_CONNECT.cmd`. Do not run the app directly from inside the ZIP
viewer.

## Why Administrator Rights Are Required

Yurich Desktop uses Windows TUN routing through Wintun. Creating the network
interface and routes requires administrator privileges. Without elevation,
Yurich Core cannot start TUN mode and Windows may show `Access is denied`.

The installer and `START_YURICH_CONNECT.cmd` launch `YurichConnect.exe` through
UAC when needed.

## Visual C++ Runtime

The Windows payload includes these DLL files next to `YurichConnect.exe`:

- `MSVCP140.dll`
- `VCRUNTIME140.dll`
- `VCRUNTIME140_1.dll`

If Windows still reports missing runtime files, install Microsoft Visual C++
Redistributable 2015-2022 x64:

https://aka.ms/vs/17/release/vc_redist.x64.exe

## If The App Does Not Start

- Start it from the installed folder or with `START_YURICH_CONNECT.cmd`.
- Do not run it directly from inside a ZIP archive.
- Check that `runtime/sing-box.exe`, `runtime/naive.exe`,
  `runtime/wintun.dll`, `runtime/libcronet.dll` and the Visual C++ DLL files are
  present.
- Open **Yurich Core logs** inside the app.
- Send a diagnostics report to the developer.

## Yurich DNS And Many Browser Tabs

Yurich Desktop uses local system DNS for fast resolution, then routes traffic
through sing-box rules:

- Russian domains such as `.ru`, `.рф`, `.su` and selected Russian services go
  direct.
- Russian GeoIP routes go direct when `geoip-ru.srs` is available.
- Foreign destinations go through VPN.
- PTR, SRV, HTTPS and SVCB DNS bursts are resolved locally to avoid 10-second
  DNS queues when Chrome opens many tabs across multiple profiles.

This avoids making Yurich DNS depend on a saturated VPN tunnel while preserving
VPN routing for foreign traffic.

## Logs And Diagnostics

Logs are written to:

```text
%APPDATA%\Yurich Connect\logs\yurich.log
%APPDATA%\Yurich Connect\logs\sing-box.log
%APPDATA%\Yurich Connect\logs\naive.log
```

Diagnostics are written to:

```text
%APPDATA%\Yurich Connect\diagnostics\report.zip
```

Reports mask UUIDs, passwords, tokens, VLESS links, NaiveProxy links,
Hysteria links and Yurich ID URLs.

Old `%APPDATA%\Aurum VPN` files are copied into `%APPDATA%\Yurich Connect` on
first launch when the new folder does not exist.

## Uninstall

Use Windows **Apps & Features**, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Yurich Connect\uninstall_yurich_connect.ps1"
```

The uninstall script asks for confirmation, removes only the `Yurich Connect`
application folder, removes shortcuts and uninstall registry entries, and stops
only `YurichConnect.exe`, `AurumVPN.exe`, `sing-box.exe` and `naive.exe`
processes launched from the application folder.

## Windows Defender

The app bundles networking tools and creates a VPN interface, so Windows
Defender or SmartScreen may warn about a new unsigned build. Download only from
the official GitHub Releases page, verify the SHA-256 hash, and allow the app
only if the hash matches the release notes.

## Build

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release --split-debug-info=build\symbols\windows
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

The smoke-test checks Flutter analysis, tests, release build, installer payload,
portable archive contents, required runtime files, Visual C++ DLL files, and
absence of local development paths or secrets in public artifacts.

## Release Files

Publish generated files on GitHub Releases instead of committing them:

- `YurichConnect_Setup.exe`
- `YurichConnect_Windows_Portable.zip`

---

# Yurich Connect для Windows

**Yurich Connect** - приложение Windows в экосистеме Yurich. Windows-сборка
называется **Yurich Desktop**, использует **Yurich Core** поверх sing-box и
Wintun, а подписки называются **Yurich ID**.

Карта бренда:

- Бренд: `Yurich`
- Приложение: `Yurich Connect`
- Панель: `Yurich Panel`
- Ядро: `Yurich Core`
- DNS: `Yurich DNS`
- Windows: `Yurich Desktop`
- Android: `Yurich Mobile`
- Подписка: `Yurich ID`
- Сайт: `Yurich Cloud`

## Возможности

- Flutter Desktop клиент для Windows.
- Yurich Core/sing-box в TUN-режиме через Wintun.
- Импорт VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, Yurich ID и raw
  sing-box JSON.
- Импорт HTML-страниц панели, если внутри есть raw-ссылки.
- Блок пинга серверов: TCP-проверка каждого импортированного профиля.
- Автостарт с Windows через планировщик задач с высшими правами.
- Автоподключение выбранного профиля.
- Split tunneling через исключения `.exe` процессов.
- Быстрый Yurich DNS для браузера с большим количеством вкладок.
- Проверка обновлений через GitHub Releases.
- Счётчики трафика через sing-box Clash API.
- Диагностика с маскировкой UUID, паролей, токенов и URL подписок.

## Установка

1. Скачай `YurichConnect_Setup.exe` из GitHub Releases.
2. Запусти установщик от имени администратора.
3. Разреши Windows UAC.
4. После установки можно сразу запустить Yurich Connect.

Portable-версию сначала распакуй из `YurichConnect_Windows_Portable.zip`, затем
запусти `START_YURICH_CONNECT.cmd`. Не запускай приложение прямо из ZIP.

## Почему нужны права администратора

Yurich Desktop использует Windows TUN через Wintun. Для создания сетевого
интерфейса и маршрутов нужны права администратора. Без них Yurich Core не
сможет запустить TUN, а Windows может показать `Access is denied`.

Установщик и `START_YURICH_CONNECT.cmd` запускают `YurichConnect.exe` через UAC,
если прав не хватает.

## Visual C++ Runtime

В Windows payload рядом с `YurichConnect.exe` добавлены:

- `MSVCP140.dll`
- `VCRUNTIME140.dll`
- `VCRUNTIME140_1.dll`

Если Windows всё равно пишет, что runtime отсутствует, установи Microsoft
Visual C++ Redistributable 2015-2022 x64:

https://aka.ms/vs/17/release/vc_redist.x64.exe

## Если приложение не запускается

- Запускай из установленной папки или через `START_YURICH_CONNECT.cmd`.
- Не запускай приложение прямо из ZIP.
- Проверь наличие `runtime/sing-box.exe`, `runtime/naive.exe`,
  `runtime/wintun.dll`, `runtime/libcronet.dll` и Visual C++ DLL.
- Открой **Логи Yurich Core** внутри приложения.
- Отправь диагностический отчёт разработчику.

## Yurich DNS и много вкладок браузера

Yurich Desktop использует локальный системный DNS для быстрого резолва, а потом
маршрутизирует трафик правилами sing-box:

- Российские домены `.ru`, `.рф`, `.su` и выбранные российские сервисы идут
  напрямую.
- Российские GeoIP маршруты идут напрямую, если доступен `geoip-ru.srs`.
- Иностранные адреса идут через VPN.
- PTR, SRV, HTTPS и SVCB DNS-залпы обрабатываются локально, чтобы Chrome с
  несколькими профилями и большим числом вкладок не создавал очередь DNS timeout
  примерно на 10 секунд.

Так Yurich DNS не зависит от загруженного VPN-туннеля, но маршрутизация
иностранного трафика сохраняется через VPN.

## Логи и диагностика

Логи лежат здесь:

```text
%APPDATA%\Yurich Connect\logs\yurich.log
%APPDATA%\Yurich Connect\logs\sing-box.log
%APPDATA%\Yurich Connect\logs\naive.log
```

Диагностика:

```text
%APPDATA%\Yurich Connect\diagnostics\report.zip
```

Отчёт маскирует UUID, пароли, токены, VLESS-ссылки, NaiveProxy-ссылки,
Hysteria-ссылки и Yurich ID URL.

Старые файлы из `%APPDATA%\Aurum VPN` копируются в `%APPDATA%\Yurich Connect`
при первом запуске, если новая папка ещё не создана.

## Удаление

Используй **Приложения и возможности** Windows или запусти:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Yurich Connect\uninstall_yurich_connect.ps1"
```

Скрипт удаления просит подтверждение, удаляет только папку `Yurich Connect`,
ярлыки и записи uninstall. Он останавливает только процессы `YurichConnect.exe`,
`AurumVPN.exe`, `sing-box.exe` и `naive.exe`, запущенные из папки приложения.

## Windows Defender

Приложение содержит сетевые компоненты и создаёт VPN-интерфейс, поэтому Windows
Defender или SmartScreen могут ругаться на новую неподписанную сборку. Скачивай
установщик только из официальных GitHub Releases и сверяй SHA-256 из релиза.
