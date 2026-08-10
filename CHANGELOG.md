# Changelog

## 1.0.102 - 2026-08-10

### Fixed

- Moved the sing-box runtime cache from the protected installation directory to `%APPDATA%\Yurich Connect\cache\sing-box.db`.
- Prevented `start service: initialize cache-file: open cache.db: Access is denied` failures for non-elevated Stable Proxy Mode starts.
- Applied the writable cache path before preflight, startup canary, and the real core start for every sing-box protocol.
- Corrected the primary Windows subscription User-Agent to a valid product-token format.

### Tests

- Added cache-path preservation, disabled-cache, and bundled sing-box startup coverage.

## 1.0.101 - 2026-07-17

### Changed

- Replaced Codex direct routing with **Codex CLI through VPN only** in Advanced TUN Mode.
- Migrated the old Codex direct preference to a disabled state and enabled the new VPN-only preference by default.

### Fixed

- Codex process and process-path rules now take priority over split-tunnel and direct-domain exceptions.
- Codex DNS queries use the VPN DNS route while Codex VPN-only mode is active.
- Active Codex sessions continue to suppress aggressive health-check reconnects regardless of routing mode.

### Tests

- Added Codex process, path-regex, DNS-route, direct-rule conflict, and preference-migration coverage.

## 1.0.100 - 2026-07-15

### Added

- Added an explicit **SSH and terminal through VPN** switch for Advanced TUN Mode.
- Added forced VPN process routing for OpenSSH, SCP/SFTP, Git, GitHub CLI, PowerShell, CMD, Windows Terminal, PuTTY, and WinSCP.
- Added immediate elevated Windows logon startup with hidden tray launch and a safe `HKCU\\Run` fallback.

### Fixed

- Made terminal-through-VPN and Developer Mode mutually exclusive to prevent conflicting process rules.
- Disabled terminal-through-VPN automatically when leaving Advanced TUN Mode.
- Added persistent diagnostics for terminal routing and early startup state.

### Security

- Kept Advanced TUN strict routing and documented the signed Windows Service/WFP requirement before adding a persistent kill switch, avoiding unsafe global firewall lockouts.

### Tests

- Added forced SSH routing, terminal preference, and healthy scheduled-task XML coverage.

## 1.0.99 - 2026-07-14

### Added

- Restored VLESS XHTTP as a dedicated Windows profile transport through the bundled Xray-core in Stable Proxy Mode.
- Added an XHTTP profile filter and explicit XHTTP labels in the profile list, active profile card, and diagnostics.

### Fixed

- Preserved XHTTP `host`, `path`, `mode`, and structured `extra` from VLESS links and Xray JSON subscriptions.
- Preserved the subscription SNI/Reality server name instead of deriving it from the XHTTP host.
- Added strict XHTTP mode, path, host, JSON size, and core-backend validation before replacing an active connection.
- Stopped misclassifying full Xray JSON configurations as raw sing-box configurations.

### Tests

- Added importer, profile migration, config generation, invalid-mode, and bundled Xray config-check coverage for XHTTP.

## 1.0.98 - 2026-07-13

### Fixed

- Health watchdog probes are single-flight, preventing overlapping checks and competing soft recovery under a slow network.

### Changed

- Split the main window into Connection, Profiles, Routing, and Settings sections with fixed bottom navigation.
- Kept the connect action fixed at the top while moving profiles and advanced Windows controls out of the connection status view.
- Updated the Windows palette to a neutral graphite surface with distinct connection-success color.
- Runtime logs now use a bounded batched notifier and no longer rebuild the entire home screen for every log burst.

### Tests

- Added minimum-window navigation and bounded runtime-log buffer tests.
- Expanded the Flutter test suite from 90 to 93 tests.
- Two-minute soak validation passed with 11,971 requests, zero errors, p95 236 ms, and p99 326 ms.

## 1.0.97 - 2026-07-12

### Fixed

- A transient health warning no longer opens the red failed-connection panel while VPN is still connected.
- Health warnings are cleared automatically after a successful proxy probe.
- Repeated connection-refused errors from direct application endpoints are hidden from the user-facing log.

### Tests

- Added a reusable Windows soak test that tracks requests, proxy port uptime, core/app PID, memory, handles, and CPU.
- Ten-minute soak validation passed with 112,938 requests, zero errors, p95 155 ms, and p99 174 ms.
- Expanded the Flutter test suite from 86 to 90 tests.

## 1.0.96 - 2026-07-11

### Changed

- Serialized connect, disconnect, profile switch, repair, and import operations.
- Limited profile latency probes to four concurrent connections and cancelled stale batches.
- Updated only the status panel for live traffic and session timer changes.
- Normalized Windows process routing with `Always through VPN` taking priority.
- Disabled a conflicting Windows system proxy when Advanced TUN mode is restored.

### Tests

- Added operation overlap, routing conflict, bounded concurrency, and cancellation tests.
- Expanded the Flutter test suite from 76 to 86 tests.

## 1.0.95 - 2026-07-10

- Removed XHTTP profiles from the Windows client.
- Hardened profile deletion, subscription refresh, routing conflicts, startup, and installer validation.
