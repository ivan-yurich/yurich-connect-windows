# Aurum VPN for Windows 11

**Aurum VPN** is a Windows 11 VPN client built with Flutter Desktop, sing-box,
and Wintun. The Windows version is developed separately from Android and focuses
on a native desktop workflow: tray mode, autostart, auto-connect, split
tunneling, GitHub Releases updates, and Windows TUN routing.

> Русская версия ниже.

## Highlights

- Windows 11 desktop client built with Flutter.
- sing-box core with Wintun TUN mode.
- VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, Remnawave
  subscriptions, and raw sing-box JSON import.
- System tray support with show, hide, connect/disconnect, and quit actions.
- Autostart with Windows through Task Scheduler.
- Auto-connect to the selected profile after app launch.
- Split tunneling by excluded `.exe` process names, including selection through
  the Windows file picker.
- Russian routes bypass mode: `.ru`, `.рф`, `.su`, and Russian IP ranges go
  directly, while foreign traffic goes through the VPN.
- Traffic counters through the sing-box Clash API.
- Update checks through GitHub Releases.
- Portable archive and one-file Windows installer.

## Screens And UX

The app is designed as a compact desktop control panel:

- profile import and selection;
- connection status and live traffic;
- Windows tools panel;
- logs and diagnostics for sing-box;
- tray-first background usage.

## Routing Model

Aurum VPN uses sing-box TUN routing on Windows:

- `auto_route: true`
- `strict_route: true`
- MTU `1380`
- `mixed` stack for Windows stability
- local mixed proxy on `127.0.0.1:20808`
- Clash API on `127.0.0.1:19090`
- private IP ranges routed directly
- Russian domains and Russian IP rule set routed directly
- all other traffic routed through the selected VPN profile

The Russian IP bypass is implemented through a remote sing-box rule set:

```text
https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs
```

## DNS

Windows DNS is configured to use Cloudflare DoH through the VPN:

- server: `1.1.1.1`
- port: `443`
- path: `/dns-query`
- TLS SNI: `cloudflare-dns.com`
- detour: `proxy`

This avoids relying on plain DNS for remote lookups while keeping local resolver
fallbacks for bootstrap and system compatibility.

## Requirements

- Windows 11 x64.
- Administrator permissions for TUN/Wintun.
- Flutter SDK for development builds.
- .NET 9 SDK for rebuilding the installer.

## Build From Source

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

The Windows app output is created at:

```text
build\windows\x64\runner\Release
```

## Windows Smoke Test

The repository includes a Windows QA script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

It checks:

- Flutter analysis;
- unit tests;
- Windows release build;
- required runtime files;
- sing-box version;
- active sing-box config validation;
- portable archive contents;
- installer publishing;
- SHA256 hashes for release artifacts.

## Release Artifacts

Do not commit generated `.exe` and `.zip` artifacts into git. Publish them on
the GitHub **Releases** page instead.

Recommended release files:

- `AurumVPN_Setup.exe`
- `AurumVPN_Windows_Portable.zip`

## Project Structure

```text
lib/                         Flutter app and VPN logic
windows/                     Windows runner, installer, and QA scripts
assets/windows/sing-box/     sing-box, Wintun, Cronet runtime files
test/                        Unit tests
plugins/flutter_singbox_vpn/ Local plugin code used by the app
```

## Security Notes

- Do not commit real VPN profile links, UUIDs, passwords, private keys, or
  production configs.
- The app redacts sensitive values in diagnostic reports.
- Windows TUN mode requires administrator privileges.

## License

No project license has been selected yet. Runtime components keep their own
licenses inside `assets/windows/sing-box`.

---

# Aurum VPN для Windows 11

**Aurum VPN** - это VPN-клиент для Windows 11 на Flutter Desktop, sing-box и
Wintun. Windows-версия разрабатывается отдельно от Android и заточена под
нормальный desktop-сценарий: трей, автозапуск, автоподключение, split
tunneling, обновления через GitHub Releases и Windows TUN-маршрутизацию.

## Возможности

- Нативное Windows 11 приложение на Flutter.
- VPN-ядро sing-box с Wintun TUN-режимом.
- Импорт VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, Remnawave
  подписок и raw sing-box JSON.
- Иконка в трее: открыть, скрыть, подключить/отключить, выйти.
- Автостарт вместе с Windows через планировщик задач.
- Автоподключение выбранного профиля после запуска приложения.
- Split tunneling по `.exe` процессам, включая выбор приложения через
  проводник Windows.
- Режим обхода российских адресов: `.ru`, `.рф`, `.su` и российские IP идут
  напрямую, иностранный трафик идет через VPN.
- Счетчики трафика через sing-box Clash API.
- Проверка обновлений через GitHub Releases.
- Portable-архив и Windows-установщик одним `.exe` файлом.

## Как работает маршрутизация

На Windows Aurum VPN использует sing-box TUN:

- `auto_route: true`
- `strict_route: true`
- MTU `1380`
- Windows stack `mixed`
- локальный mixed proxy `127.0.0.1:20808`
- Clash API `127.0.0.1:19090`
- приватные IP идут напрямую
- российские домены и российский IP rule set идут напрямую
- весь остальной трафик идет через выбранный VPN-профиль

Российские IP определяются через удаленный rule set sing-box:

```text
https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs
```

## DNS

На Windows DNS настроен через Cloudflare DoH внутри VPN:

- сервер: `1.1.1.1`
- порт: `443`
- путь: `/dns-query`
- TLS SNI: `cloudflare-dns.com`
- detour: `proxy`

Так DNS-запросы уходят через туннель, а локальный DNS остается только для
bootstrap/совместимости системы.

## Требования

- Windows 11 x64.
- Права администратора для TUN/Wintun.
- Flutter SDK для сборки из исходников.
- .NET 9 SDK для пересборки установщика.

## Сборка

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

Готовая Windows-сборка появляется здесь:

```text
build\windows\x64\runner\Release
```

## Smoke-тест Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

Скрипт проверяет анализ, тесты, Windows build, runtime-файлы, sing-box,
portable-архив, публикацию установщика и SHA256 хэши.

## Релизы

Готовые `.exe` и `.zip` файлы лучше не коммитить в git. Загружай их на страницу
GitHub **Releases**.

Рекомендуемые файлы релиза:

- `AurumVPN_Setup.exe`
- `AurumVPN_Windows_Portable.zip`

## Безопасность

- Не коммить реальные VPN-ссылки, UUID, пароли, приватные ключи и рабочие
  конфиги.
- Диагностические отчеты в приложении скрывают чувствительные данные.
- Windows TUN-режим требует запуска с правами администратора.
