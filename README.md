# Aurum VPN for Windows 11

**Aurum VPN** is a Windows 11 VPN client built with Flutter Desktop, sing-box,
NaiveProxy and Wintun. The Windows version is developed separately from Android
and focuses on a native desktop workflow: tray mode, autostart, auto-connect,
split tunneling, GitHub Releases updates, diagnostics and Windows TUN routing.

> Русская версия ниже.

## Features

- Windows 10/11 x64 desktop client.
- sing-box TUN mode with Wintun.
- VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, Remnawave subscriptions
  and raw sing-box JSON import.
- Autostart through Windows Task Scheduler with elevated run level.
- Auto-connect to the selected profile after launch.
- Split tunneling by excluded `.exe` process names.
- Russian routes bypass mode: `.ru`, `.рф`, `.su` and Russian IP ranges go
  directly, while foreign traffic goes through the VPN.
- Fast Windows DNS mode for browser bursts with many tabs and mixed
  Russian/foreign sites.
- Traffic counters through the sing-box Clash API.
- Update checks and installer downloads through GitHub Releases.
- Local logs and diagnostics archive.

## Install

1. Download `AurumVPN_Setup.exe` from GitHub Releases.
2. Run the installer and allow the Windows UAC prompt.
3. The installer creates Desktop and Start Menu shortcuts.
4. After installation, choose whether to launch Aurum VPN immediately.

Portable users should extract `AurumVPN_Windows_Portable.zip` first and run
`START_AURUM_VPN.cmd`. Do not run the app directly from inside the ZIP viewer.

## Why Administrator Rights Are Required

Aurum VPN uses Windows TUN routing through Wintun. Creating the network
interface and routes requires administrator privileges. Without elevation,
sing-box cannot start TUN mode and Windows may show `Access is denied`.

## Visual C++ Runtime

The Windows payload includes these Microsoft Visual C++ Runtime DLL files next
to `AurumVPN.exe`:

- `MSVCP140.dll`
- `VCRUNTIME140.dll`
- `VCRUNTIME140_1.dll`

If Windows still reports a missing runtime, install Microsoft Visual C++
Redistributable 2015-2022 x64:

```text
https://aka.ms/vs/17/release/vc_redist.x64.exe
```

## If The App Does Not Start

- Start it from the installed folder or with `START_AURUM_VPN.cmd`.
- Check that `runtime/sing-box.exe`, `runtime/naive.exe`,
  `runtime/wintun.dll` and `runtime/libcronet.dll` exist.
- Check that no other local proxy is using `127.0.0.1:20808`,
  `127.0.0.1:20809` or `127.0.0.1:19090`.
- Open the logs listed below and send diagnostics if the problem repeats.

## DNS And Many Browser Tabs

Windows builds use local system DNS for fast resolution, then route traffic
through sing-box rules:

- Russian domains and Russian GeoIP ranges go directly.
- Foreign traffic goes through the selected VPN profile.
- PTR, SRV, HTTPS and SVCB DNS bursts are resolved locally to avoid 10-second
  DNS queues when Chrome opens many tabs across multiple profiles.

This avoids making DNS depend on a saturated VPN tunnel while preserving VPN
routing for foreign connections.

## Logs And Diagnostics

Runtime logs are stored under:

```text
%APPDATA%\Aurum VPN\logs\aurum.log
%APPDATA%\Aurum VPN\logs\sing-box.log
%APPDATA%\Aurum VPN\logs\naive.log
```

Diagnostic reports are written to:

```text
%APPDATA%\Aurum VPN\diagnostics\report.zip
```

Sensitive values are redacted before they are shown or written: UUIDs,
passwords, tokens, VLESS links, NaiveProxy links, Hysteria links and
subscription URLs.

## Uninstall

Use Windows "Apps & features" or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Aurum VPN\uninstall_aurum_vpn.ps1"
```

The uninstall script asks for confirmation, removes only the `Aurum VPN`
installation folder, removes shortcuts and deletes the uninstall registry entry.
It stops only `AurumVPN.exe`, `sing-box.exe` and `naive.exe` processes launched
from the Aurum VPN application folder.

## Windows Defender

If Windows Defender warns about the installer:

- download only from the official GitHub Releases page;
- compare the SHA256 hash published with the release;
- unblock the file from Windows file properties if SmartScreen marked it as
  downloaded from the internet.

## Build From Source

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release --split-debug-info=build\symbols\windows
```

The Windows output is created at:

```text
build\windows\x64\runner\Release
```

## Smoke Test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

The smoke-test checks Flutter analysis, tests, release build, installer payload,
Visual C++ DLLs, runtime files, README, uninstall script, absence of debug files,
absence of local developer paths and absence of obvious secrets.

## Release Files

Publish generated files on GitHub Releases instead of committing them:

- `AurumVPN_Setup.exe`
- `AurumVPN_Windows_Portable.zip`

---

# Aurum VPN для Windows 11

**Aurum VPN** - это VPN-клиент для Windows 11 на Flutter Desktop, sing-box,
NaiveProxy и Wintun. Windows-версия разрабатывается отдельно от Android и
заточена под desktop-сценарий: трей, автозапуск, автоподключение, split
tunneling, обновления через GitHub Releases, диагностика и Windows TUN.

## Возможности

- Клиент для Windows 10/11 x64.
- VPN-ядро sing-box в TUN-режиме через Wintun.
- Импорт VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, Remnawave
  подписок и raw sing-box JSON.
- Автостарт через планировщик задач Windows с повышенными правами.
- Автоподключение выбранного профиля после запуска.
- Split tunneling по исключенным `.exe` процессам.
- Режим обхода российских адресов: `.ru`, `.рф`, `.su` и российские IP идут
  напрямую, иностранный трафик идет через VPN.
- Быстрый Windows DNS для старта браузера с большим количеством вкладок и
  смесью российских/зарубежных сайтов.
- Счетчики трафика через sing-box Clash API.
- Проверка и скачивание обновлений через GitHub Releases.
- Локальные логи и диагностический архив.

## Как установить

1. Скачай `AurumVPN_Setup.exe` из GitHub Releases.
2. Запусти установщик и подтверди запрос UAC.
3. Установщик создаст ярлык на рабочем столе и в меню Пуск.
4. После установки можно сразу запустить Aurum VPN.

Portable-версию сначала распакуй из `AurumVPN_Windows_Portable.zip`, затем
запусти `START_AURUM_VPN.cmd`. Не запускай приложение прямо из ZIP.

## Почему нужны права администратора

Aurum VPN использует Windows TUN через Wintun. Для создания сетевого интерфейса
и маршрутов нужны права администратора. Без них sing-box не сможет запустить TUN
и Windows может показать `Access is denied`.

## Visual C++ Runtime

В Windows payload рядом с `AurumVPN.exe` добавлены:

- `MSVCP140.dll`
- `VCRUNTIME140.dll`
- `VCRUNTIME140_1.dll`

Если Windows всё равно пишет, что runtime отсутствует, установи Microsoft
Visual C++ Redistributable 2015-2022 x64:

```text
https://aka.ms/vs/17/release/vc_redist.x64.exe
```

## Если приложение не запускается

- Запускай из установленной папки или через `START_AURUM_VPN.cmd`.
- Проверь наличие `runtime/sing-box.exe`, `runtime/naive.exe`,
  `runtime/wintun.dll` и `runtime/libcronet.dll`.
- Проверь, что другие прокси/VPN не заняли `127.0.0.1:20808`,
  `127.0.0.1:20809` или `127.0.0.1:19090`.
- Открой логи ниже и отправь диагностику разработчику, если проблема
  повторяется.

## DNS и много вкладок браузера

Windows-сборка использует локальный системный DNS для быстрого резолва, а
потом маршрутизирует трафик правилами sing-box:

- российские домены и GeoIP RU идут напрямую;
- иностранный трафик идет через выбранный VPN-профиль;
- PTR, SRV, HTTPS и SVCB DNS-залпы обрабатываются локально, чтобы Chrome с
  двумя профилями и большим числом вкладок не создавал очередь DNS timeout по
  10 секунд.

Так DNS не зависит от загруженного VPN-туннеля, но маршрутизация иностранного
трафика остаётся через VPN.

## Логи и диагностика

Логи лежат здесь:

```text
%APPDATA%\Aurum VPN\logs\aurum.log
%APPDATA%\Aurum VPN\logs\sing-box.log
%APPDATA%\Aurum VPN\logs\naive.log
```

Диагностический архив:

```text
%APPDATA%\Aurum VPN\diagnostics\report.zip
```

Перед записью и отправкой маскируются UUID, пароли, токены, VLESS-ссылки,
NaiveProxy-ссылки, Hysteria-ссылки и URL подписок.

## Как удалить

Через "Приложения и возможности" Windows или командой:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Aurum VPN\uninstall_aurum_vpn.ps1"
```

Скрипт удаления просит подтверждение, удаляет только папку установки
`Aurum VPN`, удаляет ярлыки и запись uninstall. Он останавливает только процессы
`AurumVPN.exe`, `sing-box.exe` и `naive.exe`, запущенные из папки приложения.

## Если ругается Windows Defender

- Скачивай установщик только из официальных GitHub Releases.
- Сверяй SHA256 с хэшем в релизе.
- Если SmartScreen заблокировал файл, открой свойства файла и нажми
  "Разблокировать".

## Сборка

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release --split-debug-info=build\symbols\windows
```

## Smoke-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

Скрипт проверяет анализ, тесты, release build, installer payload, Visual C++
DLL, runtime-файлы, README, uninstall script, отсутствие debug-файлов,
локальных dev path и явных секретов.
