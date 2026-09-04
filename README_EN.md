# Yurich Connect for Windows

**Yurich Connect** is the Windows client in the Yurich ecosystem for stable access to foreign services, Yurich ID subscriptions, and manual VPN/proxy profiles.

It runs on Windows 10/11 and uses **Yurich Core** powered by sing-box, NaiveProxy, Hysteria, and optional Wintun.

## Highlights

- **Stable Proxy Mode** is the default mode without TUN, Wintun, or administrator rights.
- **Advanced TUN Mode** is an optional advanced mode for full-system routing, Wintun, DNS hijack, and split routing.
- **Yurich ID** subscription import with multiple servers and profiles.
- VLESS Reality, VLESS TLS, NaiveProxy, Hysteria 1/2, and raw sing-box JSON support.
- Separate routing logic for ChatGPT, OpenAI, and Codex sessions.
- Diagnostics, logs, and safe reports with secret masking.
- Installer and portable builds.

## Stable Proxy Mode

Stable Proxy Mode is the main mode for regular users.

It does not create a TUN interface, does not use Wintun, and does not require administrator rights. Yurich Connect starts local proxy endpoints instead:

- mixed proxy: `127.0.0.1:20808`
- SOCKS proxy: `127.0.0.1:20809`

This mode touches the Windows networking stack less, so it is better for daily use, browsers, Codex, ChatGPT, IDEs, and applications with long-lived WebSocket connections.

Windows system proxy can be enabled separately when regular apps should use Yurich Connect.

## Advanced TUN Mode

Advanced TUN Mode is an advanced scenario.

Use it when you need full-system VPN routing, split routing, DNS interception, or application routing at the TUN level.

This mode may require:

- Wintun;
- administrator rights;
- creating a network interface;
- changing Windows routes;
- more careful diagnostics on unstable networks.

If you do not explicitly need a full TUN tunnel, start with Stable Proxy Mode.

## Adaptive Access

The **Adaptive access** switch is intended for networks where an ISP interferes with TLS or blocks individual VPN endpoints.

When enabled:

- compatible sing-box VLESS profiles use safe TLS record fragmentation without changing SNI or Reality settings;
- after a confirmed startup failure, the client may try an available profile using another protocol;
- XHTTP/Xray, NaiveProxy, raw sing-box JSON, and DNS settings are not rewritten.

The mode is experimental and disabled by default. Reconnect the VPN after changing it. **Blocking diagnostics** checks selected-server DNS, endpoint reachability, TCP 443, and public TLS without changing routes.

## Yurich ID And Subscription Import

Yurich Connect can import not only a single profile link, but also a subscription containing multiple servers.

Supported inputs:

- Yurich ID subscription URL;
- VLESS Reality;
- VLESS TLS;
- NaiveProxy;
- Hysteria 1;
- Hysteria 2;
- raw sing-box JSON;
- panel HTML pages when raw profile links are embedded inside.

After import, the app shows profiles in a list, checks server ping, and lets the user choose the best connection.

## ChatGPT, OpenAI, And Codex

The Windows client separates ChatGPT website routing from Codex CLI routing.

- **ChatGPT website through VPN** is enabled by default: `chatgpt.com` and OpenAI web assets use the current VPN/proxy route.
- **Codex CLI direct** can be enabled separately: Codex processes can bypass reconnect-sensitive routing when long sessions need that behavior.

For stable Codex/OpenAI sessions, Yurich Connect:

- does not restart the tunnel after a single health-check timeout;
- checks multiple endpoints;
- avoids fast `start -> timeout -> stop -> start` loops;
- softens the reconnect watchdog during active traffic;
- avoids breaking long-lived WebSocket sessions unless necessary;
- writes probe and reconnect history to logs;
- includes DNS, TCP 443, WebSocket upgrade, and reconnect-history diagnostics.

This matters for OpenAI Codex, ChatGPT, IDEs, browsers, and any service where the connection should stay alive.

## Logs And Diagnostics

Logs are stored in:

- `%APPDATA%\Yurich Connect\logs\yurich.log`
- `%APPDATA%\Yurich Connect\logs\sing-box.log`
- `%APPDATA%\Yurich Connect\logs\naive.log`

Diagnostics are created here:

- `%APPDATA%\Yurich Connect\diagnostics\report.zip`

The report masks:

- UUIDs;
- passwords;
- tokens;
- private keys;
- `vless://` links;
- `naive+https://` links;
- `hysteria://` and `hysteria2://` links;
- Yurich ID subscription URLs.

The diagnostics report can be sent to the developer without exposing private keys or subscriptions.

## Install

Recommended installation:

1. Open the official GitHub Releases page.
2. Download `YurichConnect_Setup.exe`.
3. Run the installer.
4. Launch Yurich Connect.
5. Import a Yurich ID subscription or a single profile.
6. Connect in Stable Proxy Mode first.

Portable build:

1. Download `YurichConnect_Windows_Portable.zip`.
2. Extract the archive first.
3. Open the `Yurich Connect` folder.
4. Run `START_YURICH_CONNECT.cmd` or `YurichConnect.exe`.

Do not run the portable build directly from the Windows ZIP viewer.

## Administrator Rights

Stable Proxy Mode does not require administrator rights.

Administrator rights are required only for the installer and Advanced TUN Mode, because Windows must create a Wintun network interface and system routes.

## If The App Does Not Start

Check:

- Microsoft Visual C++ Redistributable 2015-2022 x64 is installed;
- `sing-box.exe`, `naive.exe`, `wintun.dll`, and `libcronet.dll` exist in runtime;
- Windows Defender or SmartScreen did not block the app;
- `%APPDATA%\Yurich Connect\logs\yurich.log` contains no critical startup errors.

Visual C++ Runtime:

<https://aka.ms/vs/17/release/vc_redist.x64.exe>

## If Internet Stops Working

Open Yurich Connect and press **Repair connection**.

The app stops its own processes, clears temporary configs, restores Windows proxy settings, and flushes DNS. Profiles and subscriptions are not removed.

## Updates

Yurich Connect checks Windows builds on GitHub Releases.

Updates are downloaded to a temporary `.download` file, checked, and only then renamed to the final installer file. This prevents broken partial downloads from being used.

## Uninstall

Installer builds can be removed through Windows Settings or the uninstaller in the installation folder.

Portable builds are removed manually: close the app, disconnect VPN, and delete the extracted folder. User data stays in `%APPDATA%\Yurich Connect` until you remove it manually.

## Windows Defender And SmartScreen

Yurich Connect includes networking components and can create a VPN interface in Advanced TUN Mode. A new unsigned build can trigger Windows Defender or SmartScreen warnings.

Download the installer only from the official GitHub Releases page and verify the SHA-256 checksum from the release. If Windows blocks startup, create a diagnostics report and send it to the developer.

## Rebranding

The old **Aurum VPN** name is no longer used for the Windows product. Current naming:

- brand: Yurich;
- app: Yurich Connect;
- Windows client: Yurich Desktop;
- core: Yurich Core;
- subscription: Yurich ID.
