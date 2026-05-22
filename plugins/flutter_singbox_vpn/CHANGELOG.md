## 1.1.3

* Fixed iOS podspec file name and metadata to match package name (flutter_singbox_vpn)
* Updated podspec version and author information

## 1.1.2

* Removed unnecessary location permissions (ACCESS_COARSE_LOCATION, ACCESS_FINE_LOCATION, ACCESS_BACKGROUND_LOCATION)
* Removed REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission
* Added clear documentation for all required permissions in AndroidManifest
* Improved permission structure with categorized comments

## 1.1.1

* Fixed app launcher icon being overridden by plugin drawable
* Added VPN key icon for notification
* Fixed VPN status incorrectly showing "Started" when config has errors
* Improved error handling during VPN startup
* Renamed internal drawable resources to avoid conflicts

## 1.1.0

* Added log streaming support with `onLogMessage` stream
* Added 16KB page size support for Android 15+ devices
* Migrated to libbox 1.12.12 from JitPack
* Improved VPN state management and connection stability
* Fixed `seq.Inc: unknown refnum` crashes on disconnect
* Added proper shutdown handling with `Stopping` status
* Added `getLogs()` and `clearLogs()` methods
* Updated compileSdk and targetSdk to 36

## 1.0.0

* Initial stable release
* VPN connection management (start/stop)
* Real-time status updates via streams
* Traffic statistics monitoring
* Per-app tunneling support (include/exclude modes)
* JSON configuration support
* Full sing-box protocol support
