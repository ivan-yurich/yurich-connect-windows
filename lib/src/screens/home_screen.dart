import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../models/vpn_profile.dart';
import '../branding.dart';
import '../services/profile_importer.dart';
import '../services/profile_store.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import '../services/windows_integration_service.dart';
import 'qr_scan_screen.dart';

const _gold = Color(0xFFD9A441);
const _goldSoft = Color(0xFFFFE6A3);
const _ink = Color(0xFF0E0B07);
const _surface = Color(0xFF18130B);
const _surfaceMetric = Color(0xFF2D2110);
const _mutedGold = Color(0xFFB9AA86);
const _appName = YurichBranding.appName;
const _telegramUrl = 'https://t.me/ivan_it_net';
const _vkUrl = 'https://vk.com/ivan_yurievich_it';
const _donateUrl = 'https://dzen.ru/ivanyurievich?donate=true';
const _supportEmail = 'ai@ivan-it.net';
const _appVersion = '1.0.17';

class _ConnectionConfigPlan {
  const _ConnectionConfigPlan(this.naiveMode, this.label);

  final NaiveOutboundMode naiveMode;
  final String label;
}

enum _AppLanguage {
  ru('ru'),
  en('en');

  const _AppLanguage(this.code);

  final String code;

  static _AppLanguage fromCode(String? code) {
    return values.firstWhere(
      (language) => language.code == code,
      orElse: () => _AppLanguage.ru,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TrayListener, WindowListener {
  final _vpnEngine = createVpnEngine();
  final _store = ProfileStore();
  final _importer = ProfileImporter();
  final _configBuilder = SingBoxConfigBuilder();
  final _windowsIntegration = WindowsIntegrationService();
  final _manualController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _statusSubscription;
  StreamSubscription<Map<String, dynamic>>? _trafficSubscription;
  StreamSubscription<Map<String, dynamic>>? _logSubscription;
  Timer? _logFlushTimer;
  Timer? _healthWatchdogTimer;
  DateTime? _ignoreStoppedUntil;
  DateTime? _healthWatchdogWarmupUntil;
  DateTime? _lastTrafficUpdateAt;

  List<VpnProfile> _profiles = const [];
  String? _selectedProfileId;
  _AppLanguage _language = _AppLanguage.ru;
  String _status = YurichConnectStatus.stopped;
  String _uplink = '0 B/s';
  String _downlink = '0 B/s';
  String _sessionTotal = '0 B';
  int _uplinkBytesPerSecond = 0;
  int _downlinkBytesPerSecond = 0;
  String _message = 'Готов к импорту подписки';
  String? _lastError;
  bool _busy = false;
  bool _stoppingByUser = false;
  bool _windowsSettingsBusy = false;
  bool _checkingUpdate = false;
  bool _installingUpdate = false;
  bool _autoStart = false;
  bool _autoConnect = false;
  bool _autoConnectAttempted = false;
  bool _healthWatchdogRestarting = false;
  int _healthWatchdogFailures = 0;
  bool _quitFromTray = false;
  List<String> _splitTunnelExcludedProcesses = const [];
  WindowsUpdateInfo? _updateInfo;
  Map<String, _ServerLatencyResult> _serverLatencies = const {};
  bool _checkingServerLatency = false;
  String? _lastConfigSummary;
  final _logs = <String>[];
  final _pendingLogs = <String>[];

  _Strings get s => _Strings.forLanguage(_language);

  VpnProfile? get _selectedProfile {
    for (final profile in _profiles) {
      if (profile.id == _selectedProfileId) {
        return profile;
      }
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  bool get _connected =>
      _status == YurichConnectStatus.started ||
      _status == YurichConnectStatus.starting;

  Future<void> _setupTray() async {
    if (!Platform.isWindows) {
      return;
    }
    await trayManager.setIcon(await _windowsTrayIconPath());
    await trayManager.setToolTip(_appName);
    await _refreshTrayMenu();
  }

  Future<String> _windowsTrayIconPath() async {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final releaseIcon = File(
      '${executableDir.path}\\data\\flutter_assets\\windows\\runner\\resources\\app_icon.ico',
    );
    if (await releaseIcon.exists()) {
      return releaseIcon.path;
    }

    final devIcon = File('windows\\runner\\resources\\app_icon.ico');
    if (await devIcon.exists()) {
      return devIcon.absolute.path;
    }

    return releaseIcon.path;
  }

  Future<void> _refreshTrayMenu() async {
    if (!Platform.isWindows) {
      return;
    }
    final connected = _status == YurichConnectStatus.started;
    final connecting = _status == YurichConnectStatus.starting;
    final stopping = _status == YurichConnectStatus.stopping;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: s.trayShow),
          MenuItem(key: 'hide', label: s.trayHide),
          MenuItem.separator(),
          MenuItem(
            key: 'toggle',
            label: connected ? s.disconnect : s.connect,
            disabled:
                _busy || _selectedProfile == null || connecting || stopping,
          ),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: s.trayQuit),
        ],
      ),
    );
  }

  Future<void> _showMainWindow() async {
    if (!Platform.isWindows) {
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _hideToTray() async {
    if (!Platform.isWindows) {
      return;
    }
    await windowManager.hide();
  }

  Future<void> _quitAppFromTray() async {
    _quitFromTray = true;
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await _vpnEngine.stopVPN();
    await windowManager.close();
  }

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      trayManager.addListener(this);
      windowManager.addListener(this);
      unawaited(_setupTray());
    }
    _load();
    _initVpn();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _trafficSubscription?.cancel();
    _logSubscription?.cancel();
    _logFlushTimer?.cancel();
    _stopHealthWatchdog();
    if (Platform.isWindows) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      unawaited(trayManager.destroy());
    }
    _manualController.dispose();
    unawaited(_vpnEngine.dispose());
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showMainWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showMainWindow());
        break;
      case 'hide':
        unawaited(_hideToTray());
        break;
      case 'toggle':
        unawaited(_toggleVpn());
        break;
      case 'quit':
        unawaited(_quitAppFromTray());
        break;
    }
  }

  @override
  void onWindowClose() {
    if (_quitFromTray) {
      return;
    }
    unawaited(_hideToTray());
  }

  Future<void> _load() async {
    final profiles = await _store.loadProfiles();
    final selectedId = await _store.loadSelectedProfileId();
    final language = _AppLanguage.fromCode(await _store.loadLanguageCode());
    final autoConnect = await _store.loadAutoConnect();
    final splitTunnelExcludedProcesses = await _store
        .loadSplitTunnelExcludedProcesses();
    if (Platform.isWindows) {
      await _windowsIntegration.repairAutoStartIfNeeded();
    }
    final autoStart = Platform.isWindows
        ? await _windowsIntegration.isAutoStartEnabled()
        : false;
    if (!mounted) {
      return;
    }
    final strings = _Strings.forLanguage(language);
    final resolvedSelectedId =
        profiles.any((profile) => profile.id == selectedId)
        ? selectedId
        : (profiles.isEmpty ? null : profiles.first.id);
    setState(() {
      _language = language;
      _profiles = profiles;
      _selectedProfileId = resolvedSelectedId;
      _autoConnect = autoConnect;
      _autoStart = autoStart;
      _splitTunnelExcludedProcesses = splitTunnelExcludedProcesses;
      _message = profiles.isEmpty
          ? strings.addProfileHint
          : strings.loadedProfiles(profiles.length);
    });
    if (profiles.isNotEmpty) {
      unawaited(_refreshServerLatencies());
    }

    if (Platform.isWindows &&
        autoConnect &&
        resolvedSelectedId != null &&
        !_autoConnectAttempted) {
      _autoConnectAttempted = true;
      unawaited(
        Future<void>.delayed(const Duration(seconds: 12), () async {
          if (mounted && !_connected && !_busy) {
            await _connect();
          }
        }),
      );
    }
  }

  Future<void> _initVpn() async {
    _statusSubscription = _vpnEngine.onStatusChanged.listen((event) {
      if (event['type'] == 'alert') {
        final message = event['message'] as String?;
        if (message != null && message.isNotEmpty && mounted) {
          setState(() => _message = message);
          _showSnack(message);
        }
        return;
      }

      final status = event['status'] as String?;
      if (status != null && mounted) {
        setState(() {
          _status = status;
          if (status == YurichConnectStatus.started) {
            _lastError = null;
            _ignoreStoppedUntil = DateTime.now().add(
              const Duration(seconds: 4),
            );
            _startHealthWatchdog(warmup: const Duration(seconds: 30));
          } else if (status == YurichConnectStatus.stopped ||
              status == YurichConnectStatus.stopping) {
            _stopHealthWatchdog();
          }
          final ignoreStopped =
              _ignoreStoppedUntil != null &&
              DateTime.now().isBefore(_ignoreStoppedUntil!);
          if (status == YurichConnectStatus.stopped &&
              !_stoppingByUser &&
              !ignoreStopped) {
            _lastError = s.vpnStoppedUnexpectedly;
            _message = s.openLogsMessage;
          }
        });
        unawaited(_refreshTrayMenu());
      }
    });

    _trafficSubscription = _vpnEngine.onTrafficUpdate.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        _lastTrafficUpdateAt = DateTime.now();
        _uplinkBytesPerSecond =
            (event['uplinkSpeed'] as num?)?.round() ?? _uplinkBytesPerSecond;
        _downlinkBytesPerSecond =
            (event['downlinkSpeed'] as num?)?.round() ??
            _downlinkBytesPerSecond;
        _uplink = event['formattedUplinkSpeed'] as String? ?? _uplink;
        _downlink = event['formattedDownlinkSpeed'] as String? ?? _downlink;
        _sessionTotal =
            event['formattedSessionTotal'] as String? ?? _sessionTotal;
      });
    });

    _logSubscription = _vpnEngine.onLogMessage.listen((event) {
      if (!mounted || event['type'] != 'log') {
        return;
      }
      final message = event['message'] as String?;
      if (message == null || message.isEmpty) {
        return;
      }
      _queueLog(message);
    });

    try {
      await _vpnEngine.setNotificationTitle(_appName);
      await _vpnEngine.setNotificationDescription(s.notificationDescription);
      await _vpnEngine.requestNotificationPermission();
      final status = await _vpnEngine.getVPNStatus();
      final bufferedLogs = await _vpnEngine.getLogs();
      if (mounted) {
        setState(() {
          _status = status;
          _logs
            ..clear()
            ..addAll(
              bufferedLogs
                  .map(_cleanLog)
                  .where((log) => log.isNotEmpty)
                  .toList()
                  .reversed
                  .take(60)
                  .toList()
                  .reversed,
            );
        });
      }
    } on Object {
      // In widget tests and desktop preview the native Android plugin is absent.
    }
  }

  Future<void> _importManual() async {
    await _importText(_manualController.text);
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    await _importText(text);
  }

  Future<void> _importFromQr() async {
    if (Platform.isWindows) {
      _showSnack(s.qrCameraUnavailable);
      await _showImportSheet();
      return;
    }
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (value == null || value.trim().isEmpty) {
      return;
    }
    await _importText(value);
  }

  Future<void> _showImportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      s.addProfile,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: s.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _manualController,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(hintText: s.importHint),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            unawaited(_importManual());
                          },
                    icon: const Icon(Icons.add_link),
                    label: Text(s.importAction),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            unawaited(_importFromClipboard());
                          },
                    icon: const Icon(Icons.content_paste),
                    label: Text(s.clipboard),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            unawaited(_importFromQr());
                          },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('QR'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importText(String text) async {
    await _runBusy(() async {
      final imported = await _importer.importFromText(text);
      if (imported.isEmpty) {
        throw ProfileImportException(s.nothingToImport);
      }

      final merged = <String, VpnProfile>{
        for (final profile in _profiles) profile.id: profile,
        for (final profile in imported) profile.id: profile,
      }.values.toList();

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(imported.first.id);
      _manualController.clear();

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = merged;
        _selectedProfileId = imported.first.id;
        _message = s.imported(imported.length);
      });
      unawaited(_refreshTrayMenu());
      unawaited(_refreshServerLatencies());
      _showSnack(s.importedProfiles(imported.length));
    });
  }

  Future<void> _refreshServerLatencies() async {
    if (_checkingServerLatency || _profiles.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() => _checkingServerLatency = true);
    }
    final profiles = List<VpnProfile>.of(_profiles);
    final results = Map<String, _ServerLatencyResult>.fromEntries(
      await Future.wait(
        profiles.map((profile) async {
          final latency = await _measureServerLatency(profile);
          return MapEntry(profile.id, latency);
        }),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _serverLatencies = results;
      _checkingServerLatency = false;
    });
  }

  Future<_ServerLatencyResult> _measureServerLatency(VpnProfile profile) async {
    final server = profile.server?.trim();
    final port = profile.port ?? 443;
    if (server == null || server.isEmpty) {
      return const _ServerLatencyResult.unavailable();
    }

    Socket? socket;
    final stopwatch = Stopwatch()..start();
    try {
      socket = await Socket.connect(
        server,
        port,
        timeout: const Duration(seconds: 3),
      );
      stopwatch.stop();
      return _ServerLatencyResult.ok(stopwatch.elapsedMilliseconds);
    } on Object {
      stopwatch.stop();
      return const _ServerLatencyResult.failed();
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _toggleVpn() async {
    if (_connected) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _selectProfile(VpnProfile profile) async {
    if (_busy) {
      return;
    }

    final current = _selectedProfile;
    if (current?.id == profile.id) {
      return;
    }

    if (!_connected) {
      setState(() {
        _selectedProfileId = profile.id;
        _message = s.selectedProfile(profile.name);
      });
      await _store.saveSelectedProfileId(profile.id);
      unawaited(_refreshTrayMenu());
      return;
    }

    await _runBusy(() async {
      await _stopVpnCore(updateMessage: false);
      await _startVpnCore(profile);
    }, message: s.switchingProfile);
  }

  Future<void> _connect() async {
    final profile = _selectedProfile;
    if (profile == null) {
      _showSnack(s.importFirst);
      return;
    }

    await _runBusy(
      () => _startVpnCore(profile),
      message: s.connectingTo(profile.name),
    );
  }

  Future<void> _startVpnCore(VpnProfile profile) async {
    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    final status = await _refreshVpnStatus();
    if (status != YurichConnectStatus.stopped) {
      await _stopVpnCore(updateMessage: false);
    }

    await Future<void>.delayed(const Duration(milliseconds: 1400));

    _pendingLogs.clear();
    _logs.clear();
    _lastError = null;
    await _vpnEngine.clearLogs();

    await _vpnEngine.requestNotificationPermission();

    Object? lastStartError;
    var connected = false;
    final plans = _connectionPlans(profile);

    for (
      var planIndex = 0;
      planIndex < plans.length && !connected;
      planIndex += 1
    ) {
      final plan = plans[planIndex];
      final config = _configBuilder.build(
        profile,
        target: _vpnEngine.configTarget,
        naiveMode: plan.naiveMode,
        splitTunnelExcludedProcesses: _splitTunnelExcludedProcesses,
      );
      final naiveProxyConfig =
          _vpnEngine.configTarget == SingBoxConfigTarget.windows &&
              profile.kind == VpnProfileKind.naive &&
              plan.naiveMode == NaiveOutboundMode.externalCore
          ? _configBuilder.buildNaiveProxyConfig(profile)
          : null;
      final configSummary = _summarizeSingBoxConfig(
        config,
        target: _vpnEngine.configTarget,
      );
      final saved = await _vpnEngine.saveConfig(
        config,
        naiveProxyConfig: naiveProxyConfig,
      );
      if (!saved) {
        throw StateError(s.configSaveFailed);
      }

      for (var attempt = 1; attempt <= 2 && !connected; attempt += 1) {
        if (mounted) {
          setState(() {
            _selectedProfileId = profile.id;
            _lastError = null;
            _message = plans.length > 1
                ? '${s.connectingStatus(profile.name)} · ${plan.label}'
                : s.connectingStatus(profile.name);
            _uplink = '0 B/s';
            _downlink = '0 B/s';
            _uplinkBytesPerSecond = 0;
            _downlinkBytesPerSecond = 0;
            _sessionTotal = '0 B';
            _lastConfigSummary = configSummary;
          });
        }

        final started = await _vpnEngine.startVPN();
        if (started) {
          final finalStatus = await _waitForVpnStatus({
            YurichConnectStatus.started,
          }, timeout: const Duration(seconds: 14));
          if (finalStatus == YurichConnectStatus.started) {
            if (_vpnEngine.configTarget != SingBoxConfigTarget.windows ||
                await _probeLocalMixedProxy()) {
              connected = true;
              break;
            }
            lastStartError = s.connectionProbeFailed;
          } else {
            lastStartError = s.vpnNotConnected(finalStatus);
          }
        } else {
          lastStartError = s.vpnStartFailed;
        }

        if (!connected) {
          _queueLog(
            'VPN start retry [$attempt/${plan.label}]: '
            '${_redactSensitive('$lastStartError')}',
          );
          await _stopVpnCore(updateMessage: false);
          await Future<void>.delayed(const Duration(milliseconds: 1600));
          await _vpnEngine.saveConfig(
            config,
            naiveProxyConfig: naiveProxyConfig,
          );
          _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 14));
        }
      }

      if (!connected && planIndex < plans.length - 1) {
        _queueLog('Naive mode fallback: ${plan.label} did not pass probe.');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }

    if (!connected) {
      throw StateError('${lastStartError ?? s.vpnStartFailed}');
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _store.saveSelectedProfileId(profile.id);
    if (mounted) {
      setState(() {
        _selectedProfileId = profile.id;
        _lastError = null;
        _message = s.connectionProfile(profile.name);
      });
    }
  }

  List<_ConnectionConfigPlan> _connectionPlans(VpnProfile profile) {
    if (profile.kind != VpnProfileKind.naive) {
      return const [_ConnectionConfigPlan(NaiveOutboundMode.auto, 'auto')];
    }

    final outboundType = (profile.outbound?['type'] as String?)?.toLowerCase();
    if (outboundType == 'http') {
      return const [
        _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
        _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
      ];
    }

    return const [
      _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
      _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
    ];
  }

  Future<bool> _probeLocalMixedProxy({bool logFailures = true}) async {
    final endpoints = <({Uri uri, bool allowCertificateMismatch})>[
      (
        uri: Uri.https('cp.cloudflare.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
    ];

    for (final endpoint in endpoints) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        ..badCertificateCallback = endpoint.allowCertificateMismatch
            ? (_, host, _) => host == endpoint.uri.host
            : null
        ..findProxy = (_) =>
            'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
      try {
        final request = await client
            .getUrl(endpoint.uri)
            .timeout(const Duration(seconds: 3));
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'YurichConnect/$_appVersion',
        );
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 4),
        );
        await response.drain<void>().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        if (response.statusCode >= 200 && response.statusCode < 400) {
          return true;
        }
        if (logFailures) {
          _queueLog(
            'VPN health probe HTTP ${response.statusCode}: ${endpoint.uri}',
          );
        }
      } on Object catch (error) {
        if (logFailures) {
          _queueLog('VPN health probe failed: ${_redactSensitive('$error')}');
        }
      } finally {
        client.close(force: true);
      }
    }

    return false;
  }

  void _startHealthWatchdog({Duration warmup = Duration.zero}) {
    if (!Platform.isWindows) {
      return;
    }
    _healthWatchdogTimer?.cancel();
    _healthWatchdogFailures = 0;
    _healthWatchdogWarmupUntil = DateTime.now().add(warmup);
    _healthWatchdogTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_runHealthWatchdogTick());
    });
  }

  void _stopHealthWatchdog() {
    _healthWatchdogTimer?.cancel();
    _healthWatchdogTimer = null;
    _healthWatchdogWarmupUntil = null;
    _healthWatchdogFailures = 0;
  }

  Future<void> _runHealthWatchdogTick() async {
    if (!mounted ||
        !Platform.isWindows ||
        _busy ||
        _healthWatchdogRestarting ||
        _status != YurichConnectStatus.started) {
      return;
    }

    final warmupUntil = _healthWatchdogWarmupUntil;
    if (warmupUntil != null && DateTime.now().isBefore(warmupUntil)) {
      return;
    }

    final healthy = await _probeLocalMixedProxy(logFailures: false);
    if (healthy) {
      if (_healthWatchdogFailures > 0) {
        _queueLog('VPN health watchdog recovered.');
      }
      _healthWatchdogFailures = 0;
      return;
    }

    if (_hasActiveTraffic()) {
      _queueLog('VPN health watchdog probe failed during active traffic.');
      _healthWatchdogFailures = 0;
      return;
    }

    _healthWatchdogFailures += 1;
    _queueLog('VPN health watchdog failed $_healthWatchdogFailures/3.');
    if (_healthWatchdogFailures < 3) {
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      _healthWatchdogFailures = 0;
      return;
    }

    _healthWatchdogRestarting = true;
    _queueLog('VPN health watchdog restarting tunnel.');
    await _runBusy(() async {
      await _stopVpnCore(updateMessage: false);
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) {
        await _startVpnCore(profile);
      }
    }, message: 'Проверка сети провалилась, перезапускаю VPN...');

    _healthWatchdogRestarting = false;
    _healthWatchdogFailures = 0;
    if (mounted && _status == YurichConnectStatus.started) {
      _startHealthWatchdog(warmup: const Duration(seconds: 45));
    }
  }

  bool _hasActiveTraffic() {
    final lastUpdateAt = _lastTrafficUpdateAt;
    if (lastUpdateAt == null ||
        DateTime.now().difference(lastUpdateAt) > const Duration(seconds: 12)) {
      return false;
    }
    return _uplinkBytesPerSecond + _downlinkBytesPerSecond > 1024;
  }

  Future<void> _disconnect() async {
    await _runBusy(() => _stopVpnCore(), message: s.disconnectingVpn);
  }

  Future<void> _stopVpnCore({bool updateMessage = true}) async {
    _stoppingByUser = true;
    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    if (mounted) {
      setState(() => _lastError = null);
    }
    try {
      final status = await _refreshVpnStatus();
      if (status != YurichConnectStatus.stopped) {
        await _vpnEngine.stopVPN().timeout(
          const Duration(seconds: 5),
          onTimeout: () => true,
        );
        final stoppedStatus = await _waitForVpnStatus({
          YurichConnectStatus.stopped,
        }, timeout: const Duration(seconds: 8));
        if (stoppedStatus != YurichConnectStatus.stopped) {
          _queueLog('VPN stop cleanup is still finishing: $stoppedStatus');
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      if (mounted) {
        _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
        setState(() {
          _status = YurichConnectStatus.stopped;
          _uplink = '0 B/s';
          _downlink = '0 B/s';
          _lastError = null;
          if (updateMessage) {
            _message = s.vpnStopped;
          }
        });
      }
    } finally {
      _stoppingByUser = false;
    }
  }

  Future<String> _refreshVpnStatus() async {
    try {
      final status = await _vpnEngine.getVPNStatus();
      if (mounted) {
        setState(() => _status = status);
      }
      return status;
    } on Object {
      return _status;
    }
  }

  Future<String> _waitForVpnStatus(
    Set<String> expected, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var latest = _status;
    while (DateTime.now().isBefore(deadline)) {
      latest = await _refreshVpnStatus();
      if (expected.contains(latest)) {
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return latest;
  }

  Future<void> _setLanguage(_AppLanguage language) async {
    if (_language == language) {
      return;
    }
    await _store.saveLanguageCode(language.code);
    if (!mounted) {
      return;
    }
    final strings = _Strings.forLanguage(language);
    setState(() {
      _language = language;
      _message = strings.languageChanged;
    });
    unawaited(_refreshTrayMenu());
    try {
      await _vpnEngine.setNotificationDescription(
        strings.notificationDescription,
      );
    } on Object {
      // Native plugin is unavailable in widget tests and desktop preview.
    }
  }

  Future<void> _setAutoConnect(bool value) async {
    await _store.saveAutoConnect(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _autoConnect = value;
      _message = value ? s.autoConnectEnabled : s.autoConnectDisabled;
    });
  }

  Future<void> _setAutoStart(bool value) async {
    if (!Platform.isWindows || _windowsSettingsBusy) {
      return;
    }
    setState(() => _windowsSettingsBusy = true);
    try {
      await _windowsIntegration.setAutoStart(value);
      final enabled = await _windowsIntegration.isAutoStartEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _autoStart = enabled;
        _message = enabled ? s.autoStartEnabled : s.autoStartDisabled;
      });
    } on Object catch (e) {
      if (mounted) {
        _showSnack('${s.autoStartFailed}: ${_redactSensitive('$e')}');
      }
    } finally {
      if (mounted) {
        setState(() => _windowsSettingsBusy = false);
      }
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate || _installingUpdate) {
      return;
    }
    setState(() {
      _checkingUpdate = true;
      _updateInfo = null;
      _message = s.checkingUpdates;
    });
    try {
      final info = await _windowsIntegration.checkForUpdate(_appVersion);
      if (!mounted) {
        return;
      }
      setState(() {
        _checkingUpdate = false;
        _updateInfo = info;
        _message = s.updateMessage(info);
      });

      if (!info.available) {
        return;
      }

      if (!info.canInstall) {
        if (info.releaseUrl != null) {
          _showSnack(
            s.updateInstallerMissing,
            action: SnackBarAction(
              label: s.openRelease,
              onPressed: () => unawaited(_openUrl(info.releaseUrl.toString())),
            ),
          );
        } else {
          _showSnack(s.updateInstallerMissing);
        }
        return;
      }

      setState(() {
        _installingUpdate = true;
        _message = s.downloadingUpdate(info.latestVersion ?? '');
      });
      final installer = await _windowsIntegration.downloadInstaller(info);
      if (!mounted) {
        return;
      }
      setState(() => _message = s.startingUpdater);
      await _stopVpnCore(updateMessage: false);
      await _windowsIntegration.runInstallerAsAdmin(installer);
      exit(0);
    } on Object catch (error) {
      if (mounted) {
        final message = '${s.updateFailed}: ${_redactSensitive('$error')}';
        setState(() => _message = message);
        _showSnack(message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _checkingUpdate = false;
          _installingUpdate = false;
        });
      }
    }
  }

  Future<void> _showSplitTunnelSheet() async {
    final controller = TextEditingController(
      text: _splitTunnelExcludedProcesses.join('\n'),
    );
    final value = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        Future<void> pickExecutables() async {
          final result = await FilePicker.pickFiles(
            dialogTitle: s.pickExeTitle,
            type: FileType.custom,
            allowedExtensions: const ['exe'],
            allowMultiple: true,
          );
          final paths =
              result?.files
                  .map((file) => file.path)
                  .whereType<String>()
                  .toList() ??
              const [];
          if (paths.isEmpty) {
            return;
          }
          final names = paths
              .map((path) => path.split(RegExp(r'[\\/]')).last)
              .where((name) => name.toLowerCase().endsWith('.exe'));
          final merged = _parseProcessList(
            [..._parseProcessList(controller.text), ...names].join('\n'),
          );
          controller.text = merged.join('\n');
        }

        return AlertDialog(
          title: Text(s.splitTunnelTitle),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.splitTunnelDescription),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  minLines: 4,
                  maxLines: 8,
                  decoration: InputDecoration(hintText: s.splitTunnelHint),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(pickExecutables()),
                    icon: const Icon(Icons.folder_open),
                    label: Text(s.pickExeButton),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(_parseProcessList(controller.text));
              },
              child: Text(s.save),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (value == null) {
      return;
    }
    await _store.saveSplitTunnelExcludedProcesses(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _splitTunnelExcludedProcesses = value;
      _message = _connected ? s.reconnectToApply : s.settingsSaved;
    });
  }

  List<String> _parseProcessList(String value) {
    final items = value
        .split(RegExp(r'[\n,;]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .where((item) => !item.contains('\\') && !item.contains('/'))
        .toSet()
        .toList();
    items.sort();
    return items;
  }

  String _profileKindLabel(VpnProfileKind kind) {
    return switch (kind) {
      VpnProfileKind.vlessReality => 'VLESS Reality',
      VpnProfileKind.vlessTls => 'VLESS TLS',
      VpnProfileKind.naive => 'NaiveProxy',
      VpnProfileKind.hysteria => 'Hysteria',
      VpnProfileKind.hysteria2 => 'Hysteria2',
      VpnProfileKind.singBoxConfig => 'Sing-box',
    };
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedProfile;
    if (selected == null) {
      return;
    }

    final next = _profiles
        .where((profile) => profile.id != selected.id)
        .toList();
    await _store.saveProfiles(next);
    await _store.saveSelectedProfileId(next.isEmpty ? null : next.first.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _profiles = next;
      _selectedProfileId = next.isEmpty ? null : next.first.id;
      _message = s.profileDeleted;
    });
  }

  Future<void> _copySelected() async {
    final selected = _selectedProfile;
    if (selected == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: selected.originalInput));
    _showSnack(s.linkCopied);
  }

  Future<void> _showQr() async {
    final selected = _selectedProfile;
    if (selected == null || selected.originalInput.trim().isEmpty) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(selected.name),
          content: SizedBox(
            width: 260,
            child: QrImageView(
              data: selected.originalInput,
              version: QrVersions.auto,
              backgroundColor: Colors.white,
              size: 240,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.close),
            ),
          ],
        );
      },
    );
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    String? message,
  }) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = message ?? s.working;
    });
    try {
      await action();
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
        _showSnack(
          errorText,
          action: SnackBarAction(
            label: s.report,
            onPressed: () => unawaited(_emailDeveloper()),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        unawaited(_refreshTrayMenu());
      }
    }
  }

  void _showSnack(String text, {SnackBarAction? action}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _openUrl(String value) async {
    final uri = Uri.parse(value);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showSnack(s.cannotOpenLink);
    }
  }

  Future<void> _emailDeveloper() async {
    final report = _buildDiagnosticReport();
    await _writeDiagnosticArchive(report);
    final uri = Uri.parse(
      'mailto:$_supportEmail?subject=${Uri.encodeComponent(s.mailSubject)}&body=${Uri.encodeComponent(report)}',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: report));
      _showSnack(s.mailFallback);
    }
  }

  Future<void> _writeDiagnosticArchive(String report) async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      final appData = Platform.environment['APPDATA'];
      final base = appData == null || appData.isEmpty
          ? Directory('${Platform.environment['USERPROFILE']}\\.yurich_connect')
          : Directory('$appData\\Yurich Connect');
      final diagnosticsDir = Directory('${base.path}\\diagnostics');
      final logsDir = Directory('${base.path}\\logs');
      await diagnosticsDir.create(recursive: true);
      final reportFile = File('${diagnosticsDir.path}\\report.txt');
      final zipFile = File('${diagnosticsDir.path}\\report.zip');
      await reportFile.writeAsString(report, encoding: utf8, flush: true);

      final paths = <String>[reportFile.path];
      if (await logsDir.exists()) {
        await for (final entry in logsDir.list()) {
          if (entry is File && entry.path.toLowerCase().endsWith('.log')) {
            paths.add(entry.path);
          }
        }
      }

      final pathLiteral = paths.map(_powerShellQuote).join(',');
      final script =
          'Compress-Archive -Path @($pathLiteral) -DestinationPath ${_powerShellQuote(zipFile.path)} -Force';
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 10));
    } on Object {
      // Diagnostics archive is best-effort; email fallback still contains text.
    }
  }

  String _powerShellQuote(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  String _buildDiagnosticReport() {
    final profile = _selectedProfile;
    final lines = <String>[
      '$_appName diagnostic',
      'app_version: $_appVersion',
      'config_target: ${_vpnEngine.configTarget.name}',
      if (_lastConfigSummary != null) 'config: $_lastConfigSummary',
      'status: $_status',
      'message: ${_redactSensitive(_message)}',
      if (_lastError != null) 'last_error: $_lastError',
      if (profile != null) ...[
        'profile: ${_redactSensitive(profile.name)}',
        'protocol: ${_profileKindLabel(profile.kind)}',
        'endpoint: ${_redactSensitive(profile.endpoint)}',
      ],
      'traffic: up=$_uplink down=$_downlink total=$_sessionTotal',
      '',
      'logs:',
    ];

    final safeLogs = _logs
        .take(_logs.length)
        .toList()
        .reversed
        .take(35)
        .toList()
        .reversed
        .where((log) => !_isDiagnosticNoise(log))
        .map(_redactSensitive);
    lines.addAll(safeLogs.isEmpty ? const ['Логов пока нет.'] : safeLogs);
    return lines.join('\n');
  }

  String _summarizeSingBoxConfig(
    String config, {
    required SingBoxConfigTarget target,
  }) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return 'target=${target.name}; raw/custom config';
      }
      final map = decoded.cast<String, dynamic>();
      final inbounds = ((map['inbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final tun = inbounds.firstWhere(
        (inbound) => inbound['type'] == 'tun',
        orElse: () => const <String, dynamic>{},
      );
      final hasMixedProxy = inbounds.any(
        (inbound) =>
            inbound['type'] == 'mixed' &&
            inbound['listen'] == '127.0.0.1' &&
            inbound['listen_port'] == SingBoxConfigBuilder.localMixedProxyPort,
      );
      final outbounds = ((map['outbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final proxy = outbounds.firstWhere(
        (outbound) => outbound['tag'] == 'proxy',
        orElse: () =>
            outbounds.isEmpty ? const <String, dynamic>{} : outbounds.first,
      );
      final dns = (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
      final dnsFinal = dns['final'] ?? 'unknown';
      final dnsServers = ((dns['servers'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final hasFakeDns = dnsServers.any((server) => server['type'] == 'fakeip');
      final dnsServer = dnsServers.firstWhere(
        (server) => server['tag'] == dnsFinal,
        orElse: () => const <String, dynamic>{},
      );
      return [
        'target=${target.name}',
        'proxy=${proxy['type'] ?? 'unknown'}',
        'dns=$dnsFinal/${dnsServer['type'] ?? 'unknown'}',
        if (hasFakeDns) 'fake_dns=true',
        'mtu=${tun['mtu'] ?? 'unknown'}',
        'strict_route=${tun['strict_route'] ?? 'unknown'}',
        'stack=${tun['stack'] ?? 'unknown'}',
        'network=${proxy['network_strategy'] ?? 'default'}',
        if (proxy['type'] == 'http') 'mode=https-connect',
        if (proxy['type'] == 'socks') 'mode=naive-core',
        if (proxy['type'] != 'http') 'quic=${proxy['quic'] ?? 'auto'}',
        'mixed_proxy=$hasMixedProxy',
      ].join('; ');
    } on Object {
      return 'target=${target.name}; raw/custom config';
    }
  }

  bool _isDiagnosticNoise(String log) {
    return log.contains('router: found package name:') ||
        log.contains('router: found user id:') ||
        log.contains('router: failed to search process: process not found');
  }

  String _redactSensitive(String value) {
    return value
        .replaceAll(
          RegExp(
            r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
            caseSensitive: false,
          ),
          '***uuid***',
        )
        .replaceAllMapped(
          RegExp(r'(naive\+https://)[^:@\s]+:[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(
            r'(vless://|hysteria2://|hy2://|hysteria://)[^\s]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***',
        )
        .replaceAllMapped(
          RegExp(r'(vless://)[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(r'(https?://)[^:@/\s]+:[^@/\s]+@', caseSensitive: false),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(
            r'("(?:password|passwd|token|access_token|refresh_token|uuid|auth|auth_str|public_key|short_id|subscription)"\s*:\s*")[^"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:password|passwd|token|access_token|refresh_token|auth|key)=)[^&\s]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***',
        );
  }

  void _queueLog(String message) {
    final cleaned = _cleanLog(message);
    if (cleaned.isEmpty) {
      return;
    }

    _pendingLogs.add(cleaned);
    if (_pendingLogs.length > 120) {
      _pendingLogs.removeRange(0, _pendingLogs.length - 120);
    }

    _logFlushTimer ??= Timer(const Duration(milliseconds: 250), () {
      _logFlushTimer = null;
      if (!mounted || _pendingLogs.isEmpty) {
        return;
      }

      setState(() {
        _logs.addAll(_pendingLogs);
        _pendingLogs.clear();
        if (_logs.length > 60) {
          _logs.removeRange(0, _logs.length - 60);
        }
      });
    });
  }

  String _cleanLog(String message) {
    return message.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedProfile;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              radius: 17,
              backgroundImage: AssetImage('assets/images/app_icon.png'),
            ),
            const SizedBox(width: 10),
            const Text(_appName),
            const Spacer(),
            Text(
              s.windowsEdition,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: _mutedGold),
            ),
            const SizedBox(width: 12),
            PopupMenuButton<_AppLanguage>(
              tooltip: s.language,
              onSelected: (language) => unawaited(_setLanguage(language)),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: _AppLanguage.ru,
                  checked: _language == _AppLanguage.ru,
                  child: const Text('Русский'),
                ),
                CheckedPopupMenuItem(
                  value: _AppLanguage.en,
                  checked: _language == _AppLanguage.en,
                  child: const Text('English'),
                ),
              ],
              child: Text(
                _language.code.toUpperCase(),
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: _goldSoft),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _StatusPanel(
              strings: s,
              status: _status,
              message: _message,
              uplink: _uplink,
              downlink: _downlink,
              sessionTotal: _sessionTotal,
            ),
            const SizedBox(height: 16),
            _ProfilePanel(
              strings: s,
              profiles: _profiles,
              selectedId: selected?.id,
              serverLatencies: _serverLatencies,
              checkingServerLatency: _checkingServerLatency,
              onSelect: _selectProfile,
              onAdd: _showImportSheet,
              onCopy: selected == null ? null : _copySelected,
              onQr: selected == null ? null : _showQr,
              onDelete: selected == null ? null : _deleteSelected,
              onRefreshLatency: () => unawaited(_refreshServerLatencies()),
              kindLabel: _profileKindLabel,
            ),
            if (Platform.isWindows) ...[
              const SizedBox(height: 14),
              _WindowsToolsPanel(
                strings: s,
                autoStart: _autoStart,
                autoConnect: _autoConnect,
                busy: _windowsSettingsBusy,
                checkingUpdate: _checkingUpdate,
                installingUpdate: _installingUpdate,
                excludedProcessCount: _splitTunnelExcludedProcesses.length,
                updateInfo: _updateInfo,
                onAutoStartChanged: (value) => unawaited(_setAutoStart(value)),
                onAutoConnectChanged: (value) =>
                    unawaited(_setAutoConnect(value)),
                onEditSplitTunnel: _showSplitTunnelSheet,
                onCheckUpdate: _checkForUpdates,
                onOpenReleases: () =>
                    _openUrl(WindowsIntegrationService.releasesUrl),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _busy || selected == null ? null : _toggleVpn,
              icon: Icon(_connected ? Icons.power_settings_new : Icons.shield),
              label: Text(_connected ? s.disconnect : s.connect),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                textStyle: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 16),
            _SupportPanel(
              strings: s,
              onSupport: () => _openUrl(_telegramUrl),
              onTelegram: () => _openUrl(_telegramUrl),
              onVk: () => _openUrl(_vkUrl),
              onDonate: () => _openUrl(_donateUrl),
              onDeveloper: _emailDeveloper,
            ),
            const SizedBox(height: 16),
            _FaqPanel(strings: s),
            const SizedBox(height: 16),
            _LogsPanel(strings: s, logs: _logs),
          ],
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.strings,
    required this.status,
    required this.message,
    required this.uplink,
    required this.downlink,
    required this.sessionTotal,
  });

  final _Strings strings;
  final String status;
  final String message;
  final String uplink;
  final String downlink;
  final String sessionTotal;

  @override
  Widget build(BuildContext context) {
    final connected = status == YurichConnectStatus.started;
    final statusLabel = switch (status) {
      YurichConnectStatus.started => strings.connected,
      YurichConnectStatus.starting => strings.connecting,
      YurichConnectStatus.stopping => strings.disconnecting,
      _ => strings.stopped,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: connected ? _gold : Colors.white12),
        boxShadow: [
          BoxShadow(
            color: connected ? _gold.withValues(alpha: 0.18) : Colors.black26,
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.verified_user : Icons.shield_outlined,
                  color: connected ? _goldSoft : _mutedGold,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    statusLabel,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(message, style: const TextStyle(color: _mutedGold)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _Metric(label: '↑', value: uplink),
                _Metric(label: '↓', value: downlink),
                _Metric(label: 'Σ', value: sessionTotal),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _surfaceMetric,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      child: Text('$label $value'),
    );
  }
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel({
    required this.strings,
    required this.profiles,
    required this.selectedId,
    required this.serverLatencies,
    required this.checkingServerLatency,
    required this.onSelect,
    required this.onAdd,
    required this.onCopy,
    required this.onQr,
    required this.onDelete,
    required this.onRefreshLatency,
    required this.kindLabel,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final String? selectedId;
  final Map<String, _ServerLatencyResult> serverLatencies;
  final bool checkingServerLatency;
  final ValueChanged<VpnProfile> onSelect;
  final VoidCallback onAdd;
  final VoidCallback? onCopy;
  final VoidCallback? onQr;
  final VoidCallback? onDelete;
  final VoidCallback onRefreshLatency;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.profiles,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: strings.addProfile,
              onPressed: onAdd,
              icon: const Icon(Icons.add_link),
            ),
            IconButton(
              tooltip: strings.showQr,
              onPressed: onQr,
              icon: const Icon(Icons.qr_code_2),
            ),
            IconButton(
              tooltip: strings.copy,
              onPressed: onCopy,
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: strings.delete,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (profiles.isEmpty)
          _EmptyProfiles(strings: strings)
        else
          ...profiles.map(
            (profile) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProfileTile(
                profile: profile,
                selected: profile.id == selectedId,
                onTap: () => onSelect(profile),
                kindLabel: kindLabel,
              ),
            ),
          ),
        const SizedBox(height: 6),
        _ServerPingPanel(
          strings: strings,
          profiles: profiles,
          selectedId: selectedId,
          latencies: serverLatencies,
          checking: checkingServerLatency,
          onRefresh: onRefreshLatency,
          kindLabel: kindLabel,
        ),
      ],
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.selected,
    required this.onTap,
    required this.kindLabel,
  });

  final VpnProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? _gold.withValues(alpha: 0.18) : _surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _gold : Colors.white12),
        ),
        child: Row(
          children: [
            Icon(
              profile.kind == VpnProfileKind.naive ? Icons.public : Icons.bolt,
              color: selected ? _goldSoft : _mutedGold,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${kindLabel(profile.kind)} · ${profile.endpoint}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _mutedGold),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({required this.strings});

  final _Strings strings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(strings.emptyProfiles),
    );
  }
}

class _ServerPingPanel extends StatelessWidget {
  const _ServerPingPanel({
    required this.strings,
    required this.profiles,
    required this.selectedId,
    required this.latencies,
    required this.checking,
    required this.onRefresh,
    required this.kindLabel,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final String? selectedId;
  final Map<String, _ServerLatencyResult> latencies;
  final bool checking;
  final VoidCallback onRefresh;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surfaceMetric.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.network_ping_outlined, color: _goldSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.profileInsight,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: strings.pingRefresh,
                  onPressed: checking || profiles.isEmpty ? null : onRefresh,
                  icon: checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (profiles.isEmpty)
              Text(
                strings.profileInsightEmpty,
                style: const TextStyle(color: _mutedGold),
              )
            else
              Column(
                children: profiles
                    .map(
                      (profile) => _ServerPingRow(
                        profile: profile,
                        selected: profile.id == selectedId,
                        latency: latencies[profile.id],
                        checking: checking,
                        strings: strings,
                        kindLabel: kindLabel,
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

class _ServerPingRow extends StatelessWidget {
  const _ServerPingRow({
    required this.profile,
    required this.selected,
    required this.latency,
    required this.checking,
    required this.strings,
    required this.kindLabel,
  });

  final VpnProfile profile;
  final bool selected;
  final _ServerLatencyResult? latency;
  final bool checking;
  final _Strings strings;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
    final status = latency == null
        ? (checking ? strings.pingChecking : strings.pingNotChecked)
        : latency!.label(strings);
    final statusColor = latency == null
        ? _mutedGold
        : latency!.ok
        ? _goldSoft
        : Colors.redAccent.shade100;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? _goldSoft : _mutedGold,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '${kindLabel(profile.kind)} · ${profile.endpoint}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _mutedGold, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            status,
            style: TextStyle(
              color: statusColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerLatencyResult {
  const _ServerLatencyResult._({this.milliseconds, required this.state});

  const _ServerLatencyResult.ok(int milliseconds)
    : this._(milliseconds: milliseconds, state: _ServerLatencyState.ok);

  const _ServerLatencyResult.failed()
    : this._(state: _ServerLatencyState.failed);

  const _ServerLatencyResult.unavailable()
    : this._(state: _ServerLatencyState.unavailable);

  final int? milliseconds;
  final _ServerLatencyState state;

  bool get ok => state == _ServerLatencyState.ok && milliseconds != null;

  String label(_Strings strings) {
    return switch (state) {
      _ServerLatencyState.ok => strings.pingMs(milliseconds ?? 0),
      _ServerLatencyState.failed => strings.pingFailed,
      _ServerLatencyState.unavailable => strings.pingUnavailable,
    };
  }
}

enum _ServerLatencyState { ok, failed, unavailable }

class _WindowsToolsPanel extends StatelessWidget {
  const _WindowsToolsPanel({
    required this.strings,
    required this.autoStart,
    required this.autoConnect,
    required this.busy,
    required this.checkingUpdate,
    required this.installingUpdate,
    required this.excludedProcessCount,
    required this.updateInfo,
    required this.onAutoStartChanged,
    required this.onAutoConnectChanged,
    required this.onEditSplitTunnel,
    required this.onCheckUpdate,
    required this.onOpenReleases,
  });

  final _Strings strings;
  final bool autoStart;
  final bool autoConnect;
  final bool busy;
  final bool checkingUpdate;
  final bool installingUpdate;
  final int excludedProcessCount;
  final WindowsUpdateInfo? updateInfo;
  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onAutoConnectChanged;
  final VoidCallback onEditSplitTunnel;
  final VoidCallback onCheckUpdate;
  final VoidCallback onOpenReleases;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.desktop_windows_outlined, color: _goldSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.windowsTools,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: autoStart,
              onChanged: busy ? null : onAutoStartChanged,
              title: Text(strings.autoStart),
              subtitle: Text(strings.autoStartHint),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: autoConnect,
              onChanged: onAutoConnectChanged,
              title: Text(strings.autoConnect),
              subtitle: Text(strings.autoConnectHint),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onEditSplitTunnel,
                  icon: const Icon(Icons.call_split_outlined),
                  label: Text(strings.splitTunnelButton(excludedProcessCount)),
                ),
                OutlinedButton.icon(
                  onPressed: checkingUpdate || installingUpdate
                      ? null
                      : onCheckUpdate,
                  icon: checkingUpdate || installingUpdate
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update_alt),
                  label: Text(
                    installingUpdate
                        ? strings.installingUpdate
                        : checkingUpdate
                        ? strings.checkingUpdates
                        : strings.updates,
                  ),
                ),
                TextButton.icon(
                  onPressed: onOpenReleases,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('GitHub'),
                ),
              ],
            ),
            if (updateInfo != null) ...[
              const SizedBox(height: 8),
              Text(
                strings.updateMessage(updateInfo!),
                style: TextStyle(
                  color: updateInfo!.available
                      ? const Color(0xFFFFD1A8)
                      : _mutedGold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SupportPanel extends StatelessWidget {
  const _SupportPanel({
    required this.strings,
    required this.onSupport,
    required this.onTelegram,
    required this.onVk,
    required this.onDonate,
    required this.onDeveloper,
  });

  final _Strings strings;
  final VoidCallback onSupport;
  final VoidCallback onTelegram;
  final VoidCallback onVk;
  final VoidCallback onDonate;
  final VoidCallback onDeveloper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.contact, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: onSupport,
              icon: const Icon(Icons.support_agent),
              label: Text(strings.support),
            ),
            OutlinedButton.icon(
              onPressed: onTelegram,
              icon: const Icon(Icons.forum_outlined),
              label: const Text('Telegram'),
            ),
            OutlinedButton.icon(
              onPressed: onVk,
              icon: const Icon(Icons.groups_outlined),
              label: const Text('VK'),
            ),
            OutlinedButton.icon(
              onPressed: onDonate,
              icon: const Icon(Icons.volunteer_activism_outlined),
              label: Text(strings.donate),
            ),
            OutlinedButton.icon(
              onPressed: onDeveloper,
              icon: const Icon(Icons.mail_outline),
              label: Text(strings.developer),
            ),
          ],
        ),
      ],
    );
  }
}

class _FaqPanel extends StatelessWidget {
  const _FaqPanel({required this.strings});

  final _Strings strings;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.help_outline, color: _goldSoft),
      title: Text(strings.faq),
      children: [
        for (final item in strings.faqItems)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.question,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.answer,
                      style: const TextStyle(color: _mutedGold, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({required this.strings, required this.logs});

  final _Strings strings;
  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(strings.logs),
      children: [
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 92),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _gold.withValues(alpha: 0.18)),
          ),
          child: Text(
            logs.isEmpty ? strings.noLogs : logs.join('\n'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqItem {
  const _FaqItem({required this.question, required this.answer});

  final String question;
  final String answer;
}

class _Strings {
  const _Strings._({
    required this.addProfileHint,
    required this.nothingToImport,
    required this.switchingProfile,
    required this.importFirst,
    required this.configSaveFailed,
    required this.vpnStartFailed,
    required this.disconnectingVpn,
    required this.vpnStopServiceFailed,
    required this.vpnStopped,
    required this.profileDeleted,
    required this.linkCopied,
    required this.close,
    required this.working,
    required this.report,
    required this.cannotOpenLink,
    required this.mailSubject,
    required this.mailFallback,
    required this.vpnStoppedUnexpectedly,
    required this.openLogsMessage,
    required this.languageChanged,
    required this.windowsEdition,
    required this.addProfile,
    required this.importHint,
    required this.importAction,
    required this.clipboard,
    required this.scanQr,
    required this.qrCameraUnavailable,
    required this.pasteFromClipboard,
    required this.language,
    required this.connected,
    required this.connecting,
    required this.disconnecting,
    required this.stopped,
    required this.profiles,
    required this.showQr,
    required this.copy,
    required this.delete,
    required this.emptyProfiles,
    required this.profileInsight,
    required this.profileInsightEmpty,
    required this.pingRefresh,
    required this.pingChecking,
    required this.pingNotChecked,
    required this.pingFailed,
    required this.pingUnavailable,
    required this.protocolLabel,
    required this.networkLabel,
    required this.dnsLabel,
    required this.dnsCountryValue,
    required this.mobileReady,
    required this.mobileNetworkAdvice,
    required this.endpointLabel,
    required this.connect,
    required this.disconnect,
    required this.contact,
    required this.support,
    required this.donate,
    required this.developer,
    required this.faq,
    required this.faqItems,
    required this.logs,
    required this.noLogs,
    required this.windowsTools,
    required this.autoStart,
    required this.autoStartHint,
    required this.autoStartEnabled,
    required this.autoStartDisabled,
    required this.autoStartFailed,
    required this.autoConnect,
    required this.autoConnectHint,
    required this.autoConnectEnabled,
    required this.autoConnectDisabled,
    required this.splitTunnelTitle,
    required this.splitTunnelDescription,
    required this.splitTunnelHint,
    required this.pickExeButton,
    required this.pickExeTitle,
    required this.settingsSaved,
    required this.reconnectToApply,
    required this.updates,
    required this.checkingUpdates,
    required this.openRelease,
    required this.save,
    required this.cancel,
    required this.trayShow,
    required this.trayHide,
    required this.trayQuit,
    required this.notificationDescription,
  });

  final String addProfileHint;
  final String nothingToImport;
  final String switchingProfile;
  final String importFirst;
  final String configSaveFailed;
  final String vpnStartFailed;
  final String disconnectingVpn;
  final String vpnStopServiceFailed;
  final String vpnStopped;
  final String profileDeleted;
  final String linkCopied;
  final String close;
  final String working;
  final String report;
  final String cannotOpenLink;
  final String mailSubject;
  final String mailFallback;
  final String vpnStoppedUnexpectedly;
  final String openLogsMessage;
  final String languageChanged;
  final String windowsEdition;
  final String addProfile;
  final String importHint;
  final String importAction;
  final String clipboard;
  final String scanQr;
  final String qrCameraUnavailable;
  final String pasteFromClipboard;
  final String language;
  final String connected;
  final String connecting;
  final String disconnecting;
  final String stopped;
  final String profiles;
  final String showQr;
  final String copy;
  final String delete;
  final String emptyProfiles;
  final String profileInsight;
  final String profileInsightEmpty;
  final String pingRefresh;
  final String pingChecking;
  final String pingNotChecked;
  final String pingFailed;
  final String pingUnavailable;
  final String protocolLabel;
  final String networkLabel;
  final String dnsLabel;
  final String dnsCountryValue;
  final String mobileReady;
  final String mobileNetworkAdvice;
  final String endpointLabel;
  final String connect;
  final String disconnect;
  final String contact;
  final String support;
  final String donate;
  final String developer;
  final String faq;
  final List<_FaqItem> faqItems;
  final String logs;
  final String noLogs;
  final String windowsTools;
  final String autoStart;
  final String autoStartHint;
  final String autoStartEnabled;
  final String autoStartDisabled;
  final String autoStartFailed;
  final String autoConnect;
  final String autoConnectHint;
  final String autoConnectEnabled;
  final String autoConnectDisabled;
  final String splitTunnelTitle;
  final String splitTunnelDescription;
  final String splitTunnelHint;
  final String pickExeButton;
  final String pickExeTitle;
  final String settingsSaved;
  final String reconnectToApply;
  final String updates;
  final String checkingUpdates;
  final String openRelease;
  final String save;
  final String cancel;
  final String trayShow;
  final String trayHide;
  final String trayQuit;
  final String notificationDescription;

  static _Strings forLanguage(_AppLanguage language) {
    return switch (language) {
      _AppLanguage.en => en,
      _ => ru,
    };
  }

  String loadedProfiles(int count) => switch (this) {
    _Strings.en => 'Profiles loaded: $count',
    _ => 'Загружено профилей: $count',
  };

  String imported(int count) => switch (this) {
    _Strings.en => 'Imported: $count',
    _ => 'Импортировано: $count',
  };

  String importedProfiles(int count) => switch (this) {
    _Strings.en => 'Profiles imported: $count',
    _ => 'Импортировано профилей: $count',
  };

  String selectedProfile(String name) => switch (this) {
    _Strings.en => 'Selected profile: $name',
    _ => 'Выбран профиль: $name',
  };

  String connectingTo(String name) => switch (this) {
    _Strings.en => 'Connecting to $name...',
    _ => 'Подключаю $name...',
  };

  String connectingStatus(String name) => switch (this) {
    _Strings.en => 'Connecting: $name',
    _ => 'Подключаюсь: $name',
  };

  String connectionProfile(String name) => switch (this) {
    _Strings.en => 'Connection: $name',
    _ => 'Подключение: $name',
  };

  String vpnNotConnected(String status) => switch (this) {
    _Strings.en => 'VPN did not reach Connected. Last status: $status.',
    _ => 'VPN не вышел в статус "Подключено". Последний статус: $status.',
  };

  String get connectionProbeFailed => switch (this) {
    _Strings.en => 'VPN started, but the proxy health check failed.',
    _ => 'VPN стартовал, но проверка прокси не прошла.',
  };

  String vpnStopTimeout(String status) => switch (this) {
    _Strings.en => 'VPN did not fully stop in time. Last status: $status.',
    _ => 'VPN не успел полностью остановиться. Последний статус: $status.',
  };

  String serverNotResponding(String kind, String server, int port) {
    return switch (this) {
      _Strings.en =>
        '$kind server $server:$port is not responding. Check the server or port.',
      _ => '$kind сервер $server:$port не отвечает. Проверь сервер или порт.',
    };
  }

  String pingMs(int milliseconds) => switch (this) {
    _Strings.en => '$milliseconds ms',
    _ => '$milliseconds мс',
  };

  String splitTunnelButton(int count) => switch (this) {
    _Strings.en when count == 0 => 'App exclusions',
    _Strings.en => 'App exclusions: $count',
    _ when count == 0 => 'Исключения приложений',
    _ => 'Исключения: $count',
  };

  String get installingUpdate => switch (this) {
    _Strings.en => 'Installing...',
    _ => 'Устанавливаю...',
  };

  String downloadingUpdate(String version) => switch (this) {
    _Strings.en when version.isNotEmpty => 'Downloading update $version...',
    _Strings.en => 'Downloading update...',
    _ when version.isNotEmpty => 'Скачиваю обновление $version...',
    _ => 'Скачиваю обновление...',
  };

  String get startingUpdater => switch (this) {
    _Strings.en => 'Starting installer as administrator...',
    _ => 'Запускаю установщик от имени администратора...',
  };

  String get updateInstallerMissing => switch (this) {
    _Strings.en => 'Release found, but Windows installer is missing.',
    _ => 'Релиз найден, но Windows-установщик не прикреплён.',
  };

  String get updateFailed => switch (this) {
    _Strings.en => 'Update failed',
    _ => 'Обновление не удалось',
  };

  String updateMessage(WindowsUpdateInfo info) => switch (this) {
    _Strings.en when info.available && info.latestVersion != null =>
      'Update available: ${info.latestVersion}',
    _Strings.en => info.message,
    _ when info.available && info.latestVersion != null =>
      'Доступно обновление: ${info.latestVersion}',
    _ when info.message.contains('not published') =>
      'Релизы GitHub пока не опубликованы.',
    _ when info.message.contains('up to date') =>
      'Установлена актуальная версия.',
    _ when info.message.contains('failed') =>
      'Не удалось проверить обновления.',
    _ => info.message,
  };

  static const ru = _Strings._(
    addProfileHint: 'Добавь Yurich ID, QR или отдельный ключ',
    nothingToImport: 'Нечего импортировать.',
    switchingProfile: 'Переключаю профиль...',
    importFirst: 'Сначала импортируй профиль.',
    configSaveFailed: 'Yurich Core не сохранил config.',
    vpnStartFailed: 'VPN не стартовал. Открой логи ниже.',
    disconnectingVpn: 'Отключаю VPN...',
    vpnStopServiceFailed: 'VPN-сервис не смог полностью остановиться.',
    vpnStopped: 'VPN остановлен',
    profileDeleted: 'Профиль удалён',
    linkCopied: 'Ссылка скопирована',
    close: 'Закрыть',
    working: 'Работаю...',
    report: 'Отчёт',
    cannotOpenLink: 'Не смог открыть ссылку.',
    mailSubject: 'Yurich Connect: диагностика VPN',
    mailFallback: 'Почта не открылась. Отчёт скопирован в буфер.',
    vpnStoppedUnexpectedly: 'VPN остановлен неожиданно',
    openLogsMessage: 'VPN остановлен. Открой логи Yurich Core.',
    languageChanged: 'Язык переключён',
    windowsEdition: 'Yurich Desktop',
    addProfile: 'Добавить профиль',
    importHint: 'https://sub... или vless://... или hysteria2://...',
    importAction: 'Импорт',
    clipboard: 'Буфер',
    scanQr: 'Сканировать QR',
    qrCameraUnavailable:
        'На Windows пока импортируй QR как текст: вставь ссылку вручную или из буфера.',
    pasteFromClipboard: 'Вставить из буфера',
    language: 'Язык',
    connected: 'Подключено',
    connecting: 'Подключаюсь',
    disconnecting: 'Отключаюсь',
    stopped: 'Остановлено',
    profiles: 'Профили',
    showQr: 'Показать QR',
    copy: 'Скопировать',
    delete: 'Удалить',
    emptyProfiles:
        'Пока нет профилей. Нажми +, вставь подписку или сканируй QR.',
    profileInsight: 'Пинг серверов',
    profileInsightEmpty: 'Импортируй подписку, чтобы проверить пинг серверов.',
    pingRefresh: 'Обновить пинг',
    pingChecking: 'Проверяю...',
    pingNotChecked: '—',
    pingFailed: 'тайм-аут',
    pingUnavailable: 'нет адреса',
    protocolLabel: 'Протокол',
    networkLabel: 'Сеть',
    dnsLabel: 'Yurich DNS',
    dnsCountryValue: 'Yurich DNS + split',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Yurich Desktop: Yurich DNS обрабатывается локально для быстрого старта вкладок, российские домены и GeoIP RU идут напрямую, остальное через VPN.',
    endpointLabel: 'Сервер',
    connect: 'Подключить',
    disconnect: 'Отключить',
    contact: 'Связь',
    support: 'Поддержка',
    donate: 'Донат',
    developer: 'Разработчику',
    faq: 'FAQ',
    faqItems: [
      _FaqItem(
        question: 'Как добавить подписку или ключ?',
        answer:
            'Нажми + вверху или в разделе профилей. Можно вставить ссылку вручную, из буфера или отсканировать QR.',
      ),
      _FaqItem(
        question: 'Какие протоколы поддерживаются?',
        answer:
            'Поддерживаются VLESS Reality, VLESS TLS, Hysteria 1/2, Yurich ID, naive+https и sing-box JSON.',
      ),
      _FaqItem(
        question: 'Что делать, если после смены профиля пропал интернет?',
        answer:
            'Нажми Отключить, подожди статус Остановлено и подключи профиль снова. Если проблема повторяется, отправь отчёт разработчику.',
      ),
      _FaqItem(
        question: 'Почему нужна шторка уведомления?',
        answer:
            'Android требует постоянное уведомление для VPN. Разреши уведомления, чтобы видеть статус и скорость в шторке.',
      ),
      _FaqItem(
        question: 'Почему NaiveProxy может быть быстрее?',
        answer:
            'Yurich Connect не переводит naive+https в HTTPS CONNECT без необходимости. Если профиль содержит QUIC, Yurich Core сможет использовать H3/QUIC вместо более медленного совместимого режима.',
      ),
      _FaqItem(
        question: 'Безопасно ли отправлять отчёт?',
        answer:
            'Отчёт открывается в твоей почте перед отправкой. Пароли, UUID и ключи скрываются автоматически.',
      ),
    ],
    logs: 'Логи Yurich Core',
    noLogs: 'Логов пока нет.',
    windowsTools: 'Yurich Desktop',
    autoStart: 'Автостарт с Windows',
    autoStartHint:
        'Запускает Yurich Connect при входе в Windows через планировщик задач с высшими правами.',
    autoStartEnabled: 'Автостарт включён',
    autoStartDisabled: 'Автостарт выключен',
    autoStartFailed: 'Не удалось изменить автостарт',
    autoConnect: 'Автоподключение',
    autoConnectHint: 'После запуска приложения подключает выбранный профиль.',
    autoConnectEnabled: 'Автоподключение включено',
    autoConnectDisabled: 'Автоподключение выключено',
    splitTunnelTitle: 'Исключения приложений',
    splitTunnelDescription:
        'Укажи exe-файлы, которые должны идти напрямую, минуя VPN. По одному в строке.',
    splitTunnelHint: 'chrome.exe\nsteam.exe\nqbittorrent.exe',
    pickExeButton: 'Выбрать exe',
    pickExeTitle: 'Выбери приложения для исключений',
    settingsSaved: 'Настройки сохранены',
    reconnectToApply: 'Настройки сохранены. Переподключи VPN, чтобы применить.',
    updates: 'Обновления',
    checkingUpdates: 'Проверяю...',
    openRelease: 'Открыть',
    save: 'Сохранить',
    cancel: 'Отмена',
    trayShow: 'Открыть Yurich Connect',
    trayHide: 'Свернуть в трей',
    trayQuit: 'Выход',
    notificationDescription: 'VPN подключение активно',
  );

  static const en = _Strings._(
    addProfileHint: 'Add a Yurich ID, QR code, or single key',
    nothingToImport: 'Nothing to import.',
    switchingProfile: 'Switching profile...',
    importFirst: 'Import a profile first.',
    configSaveFailed: 'Yurich Core did not save the config.',
    vpnStartFailed: 'VPN did not start. Check the logs below.',
    disconnectingVpn: 'Disconnecting VPN...',
    vpnStopServiceFailed: 'VPN service could not fully stop.',
    vpnStopped: 'VPN stopped',
    profileDeleted: 'Profile deleted',
    linkCopied: 'Link copied',
    close: 'Close',
    working: 'Working...',
    report: 'Report',
    cannotOpenLink: 'Could not open the link.',
    mailSubject: 'Yurich Connect: VPN diagnostics',
    mailFallback: 'Mail did not open. Report copied to clipboard.',
    vpnStoppedUnexpectedly: 'VPN stopped unexpectedly',
    openLogsMessage: 'VPN stopped. Open Yurich Core logs.',
    languageChanged: 'Language changed',
    windowsEdition: 'Yurich Desktop',
    addProfile: 'Add profile',
    importHint: 'https://sub... or vless://... or hysteria2://...',
    importAction: 'Import',
    clipboard: 'Clipboard',
    scanQr: 'Scan QR',
    qrCameraUnavailable:
        'On Windows, import QR content as text: paste the link manually or from clipboard.',
    pasteFromClipboard: 'Paste from clipboard',
    language: 'Language',
    connected: 'Connected',
    connecting: 'Connecting',
    disconnecting: 'Disconnecting',
    stopped: 'Stopped',
    profiles: 'Profiles',
    showQr: 'Show QR',
    copy: 'Copy',
    delete: 'Delete',
    emptyProfiles: 'No profiles yet. Tap +, paste a subscription, or scan QR.',
    profileInsight: 'Server ping',
    profileInsightEmpty: 'Import a subscription to check server latency.',
    pingRefresh: 'Refresh ping',
    pingChecking: 'Checking...',
    pingNotChecked: '—',
    pingFailed: 'timeout',
    pingUnavailable: 'no endpoint',
    protocolLabel: 'Protocol',
    networkLabel: 'Network',
    dnsLabel: 'Yurich DNS',
    dnsCountryValue: 'Yurich DNS + split',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Yurich Desktop: Yurich DNS is resolved locally for fast tab startup, Russian domains and GeoIP RU go direct, and everything else uses the VPN.',
    endpointLabel: 'Server',
    connect: 'Connect',
    disconnect: 'Disconnect',
    contact: 'Contact',
    support: 'Support',
    donate: 'Donate',
    developer: 'Developer',
    faq: 'FAQ',
    faqItems: [
      _FaqItem(
        question: 'How do I add a subscription or key?',
        answer:
            'Tap + at the top or in Profiles. You can paste manually, import from clipboard, or scan a QR code.',
      ),
      _FaqItem(
        question: 'Which protocols are supported?',
        answer:
            'VLESS Reality, VLESS TLS, Hysteria 1/2, Yurich ID, naive+https, and sing-box JSON are supported.',
      ),
      _FaqItem(
        question: 'What if internet stops after switching profiles?',
        answer:
            'Tap Disconnect, wait for Stopped, then connect again. If it repeats, send a developer report.',
      ),
      _FaqItem(
        question: 'Why does Android need a notification?',
        answer:
            'Android requires a persistent notification for VPN. Allow notifications to see status and speed in the shade.',
      ),
      _FaqItem(
        question: 'Why can NaiveProxy be faster now?',
        answer:
            'Yurich Connect no longer converts naive+https to HTTPS CONNECT unless needed. If the profile contains QUIC, Yurich Core can use H3/QUIC instead of the slower compatibility mode.',
      ),
      _FaqItem(
        question: 'Is sending a report safe?',
        answer:
            'The report opens in your email before sending. Passwords, UUIDs, and keys are hidden automatically.',
      ),
    ],
    logs: 'Yurich Core logs',
    noLogs: 'No logs yet.',
    windowsTools: 'Yurich Desktop',
    autoStart: 'Start with Windows',
    autoStartHint:
        'Starts Yurich Connect on Windows sign-in via Task Scheduler with highest privileges.',
    autoStartEnabled: 'Startup enabled',
    autoStartDisabled: 'Startup disabled',
    autoStartFailed: 'Could not change startup',
    autoConnect: 'Auto-connect',
    autoConnectHint: 'Connects the selected profile after the app starts.',
    autoConnectEnabled: 'Auto-connect enabled',
    autoConnectDisabled: 'Auto-connect disabled',
    splitTunnelTitle: 'App exclusions',
    splitTunnelDescription:
        'Enter exe files that should go directly and bypass the VPN. One per line.',
    splitTunnelHint: 'chrome.exe\nsteam.exe\nqbittorrent.exe',
    pickExeButton: 'Choose exe',
    pickExeTitle: 'Choose apps to exclude',
    settingsSaved: 'Settings saved',
    reconnectToApply: 'Settings saved. Reconnect the VPN to apply them.',
    updates: 'Updates',
    checkingUpdates: 'Checking...',
    openRelease: 'Open',
    save: 'Save',
    cancel: 'Cancel',
    trayShow: 'Open Yurich Connect',
    trayHide: 'Hide to tray',
    trayQuit: 'Quit',
    notificationDescription: 'VPN connection is active',
  );
}
