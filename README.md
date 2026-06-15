# Yurich Connect for Windows

Yurich Connect is a Windows VPN/proxy client powered by Yurich Core, sing-box,
NaiveProxy, Hysteria, and optional Wintun.

## English

### Modes

- **Stable Proxy Mode** is the default and recommended mode. It does not use
  TUN, Wintun, or administrator rights. It starts a local mixed proxy at
  `127.0.0.1:20808` and a SOCKS proxy at `127.0.0.1:20809`.
- **Advanced TUN Mode** is optional beta mode for all-app routing. It can use
  TUN, Wintun, DNS hijack, split routing, and administrator rights.

### Install

1. Download `YurichConnect_Setup.exe` from GitHub Releases.
2. Run the installer.
3. Start Yurich Connect normally.
4. Import a Yurich ID subscription, QR content, or a single profile link.
5. Connect in Stable Proxy Mode first.
6. Enable Windows system proxy only when you want apps to use
   `127.0.0.1:20808` / `127.0.0.1:20809`.

### ChatGPT And Codex Routing

Yurich Connect separates ChatGPT website routing from Codex CLI routing:

- **ChatGPT website through VPN** is enabled by default, so `chatgpt.com` and
  OpenAI web assets use the current VPN/proxy route.
- **Codex CLI direct** can be enabled separately for Codex executables when a
  long-running Codex session should bypass reconnect-sensitive routing.

### Why Administrator Rights May Appear

Stable Proxy Mode does not need administrator rights. Administrator rights are
only needed for the installer and for Advanced TUN Mode, because Windows must
create a TUN/Wintun network interface and routes.

### If The App Does Not Start

- Install Microsoft Visual C++ Redistributable 2015-2022 x64:
  <https://aka.ms/vs/17/release/vc_redist.x64.exe>
- Reinstall the latest `YurichConnect_Setup.exe`.
- Open logs from the app and send a diagnostics report.

### Logs And Diagnostics

Logs are stored under `%APPDATA%\Yurich Connect\logs`:

- `yurich.log`
- `sing-box.log`
- `naive.log`

Diagnostics are created under `%APPDATA%\Yurich Connect\diagnostics` as
`report.zip`. The report masks UUIDs, passwords, tokens, private keys,
subscription URLs, and proxy links.

### Updates

The app checks GitHub Releases for newer Windows builds. Update downloads are
written to a temporary `.download` file first, checked, and only then renamed to
the final installer file.

### Autostart

Autostart uses the current user's Windows Run registry key. It does not create
an elevated Scheduled Task by default.

### Uninstall

Use Windows Settings or the uninstaller. The uninstaller removes application
files, shortcuts, uninstall entries, old startup tasks, and runtime processes
that belong to Yurich Connect. User profiles are not removed without explicit
confirmation.

### Windows Defender

Unsigned VPN/proxy tools may trigger Defender warnings. Download only from the
official GitHub Releases page, keep the installer name unchanged, and send a
diagnostics report if Windows blocks startup.

## Русский

### Режимы

- **Стабильный proxy-режим** включён по умолчанию и рекомендован для обычной
  работы. Он не использует TUN, Wintun и права администратора. Поднимает mixed
  proxy на `127.0.0.1:20808` и SOCKS proxy на `127.0.0.1:20809`.
- **Продвинутый TUN-режим** отдельный beta-режим для маршрутизации всех
  приложений. Он может использовать TUN, Wintun, DNS hijack, split routing и
  права администратора.

### Установка

1. Скачай `YurichConnect_Setup.exe` из GitHub Releases.
2. Запусти установщик.
3. Открой Yurich Connect обычным способом.
4. Добавь Yurich ID подписку, QR-текст или отдельную ссылку профиля.
5. Сначала подключись в стабильном proxy-режиме.
6. Включай системный proxy Windows только если нужно направить приложения на
   `127.0.0.1:20808` / `127.0.0.1:20809`.

### Маршрутизация ChatGPT и Codex

Yurich Connect разделяет сайт ChatGPT и Codex CLI:

- **ChatGPT сайт через VPN** включён по умолчанию, поэтому `chatgpt.com` и
  web-ресурсы OpenAI идут через текущий VPN/proxy маршрут.
- **Codex CLI напрямую** можно включить отдельно для процессов Codex, если
  длинная Codex-сессия должна идти напрямую и не зависеть от reconnect-логики.

### Почему могут понадобиться права администратора

Стабильный proxy-режим не требует права администратора. Права нужны только
установщику и продвинутому TUN-режиму, потому что Windows должна создать
TUN/Wintun интерфейс и маршруты.

### Если приложение не запускается

- Установи Microsoft Visual C++ Redistributable 2015-2022 x64:
  <https://aka.ms/vs/17/release/vc_redist.x64.exe>
- Переустанови свежий `YurichConnect_Setup.exe`.
- Открой логи в приложении и сформируй диагностический отчёт.

### Логи и диагностика

Логи лежат в `%APPDATA%\Yurich Connect\logs`:

- `yurich.log`
- `sing-box.log`
- `naive.log`

Диагностика создаётся в `%APPDATA%\Yurich Connect\diagnostics` как
`report.zip`. В отчёте маскируются UUID, пароли, токены, private keys, ссылки
подписок и proxy-ссылки.

### Обновления

Приложение проверяет GitHub Releases. Обновление сначала скачивается во
временный `.download` файл, проверяется и только потом переименовывается в
финальный установщик.

### Автостарт

Автостарт использует пользовательский Windows Run registry key. По умолчанию
elevated Scheduled Task не создаётся.

### Удаление

Удаляй приложение через параметры Windows или uninstaller. Удаляются файлы
приложения, ярлыки, uninstall-записи, старые startup tasks и процессы runtime,
которые принадлежат Yurich Connect. Пользовательские профили не удаляются без
явного подтверждения.

### Windows Defender

Неподписанные VPN/proxy инструменты иногда вызывают предупреждения Defender.
Скачивай установщик только из официальных GitHub Releases, не меняй имя файла и
отправь диагностический отчёт, если Windows блокирует запуск.
