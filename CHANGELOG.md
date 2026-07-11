# Changelog

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
