# Yurich Connect for Windows

**Yurich Connect** is the Yurich Desktop Windows client powered by Yurich Core, sing-box, NaiveProxy and Wintun.

## Features

- VLESS Reality and VLESS TLS.
- NaiveProxy through sing-box or bundled `naive.exe`.
- Hysteria and Hysteria2.
- Profile import from links, subscriptions, QR codes, clipboard and manual input.
- Windows TUN/Wintun mode.
- Split tunneling by `.exe` process names.
- Always-on VPN rules for selected apps.
- Windows startup and selected-profile auto-connect.
- GitHub Releases update checks.
- Diagnostics, logs and secret-masked reports.
- Installer and portable builds.

## Install

1. Download `YurichConnect_Setup.exe` from GitHub Releases.
2. Run the installer.
3. Allow Windows UAC.
4. Launch Yurich Connect after installation.

Portable build: extract `YurichConnect_Windows_Portable.zip`, open the `Yurich Connect` folder and run `YurichConnect.exe` or `START_YURICH_CONNECT.cmd`.

## Administrator Rights

Yurich Connect uses Windows TUN/Wintun. Creating the network adapter and routes requires administrator rights. If the app is started without elevation, it shows a clear prompt with **Restart as administrator**.

## Logs And Diagnostics

Logs are stored in:

- `%APPDATA%\Yurich Connect\logs\yurich.log`
- `%APPDATA%\Yurich Connect\logs\sing-box.log`
- `%APPDATA%\Yurich Connect\logs\naive.log`

Diagnostics are saved to:

- `%APPDATA%\Yurich Connect\diagnostics\report.zip`

UUIDs, passwords, tokens, subscription URLs and keys are masked automatically.

