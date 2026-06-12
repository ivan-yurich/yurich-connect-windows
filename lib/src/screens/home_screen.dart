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
import '../services/secret_redactor.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import '../services/windows_integration_service.dart';
import 'qr_scan_screen.dart';

const _gold = Color(0xFF15B8FF);
const _goldSoft = Color(0xFFEAF7FF);
const _ink = Color(0xFF07101C);
const _surface = Color(0xFF0D1A2B);
const _surfaceMetric = Color(0xFF112B45);
const _mutedGold = Color(0xFF8BAEC7);
const _appName = YurichBranding.appName;
const _telegramUrl = 'https://t.me/ivan_it_net';
const _vkUrl = 'https://vk.com/ivan_yurievich_it';
const _donateUrl = 'https://dzen.ru/ivanyurievich?donate=true';
const _supportEmail = 'ai@ivan-it.net';
const _appVersion = '1.0.35';
const _collapsedProfileLimit = 4;
const _maxConcurrentPingChecks = 6;
const _statusPanelHeight = 228.0;
const _healthWatchdogTick = Duration(seconds: 45);
const _healthWatchdogStartupGrace = Duration(seconds: 75);
const _healthWatchdogRetryGrace = Duration(minutes: 2);
const _healthWatchdogFailureLimit = 4;
const _healthWatchdogActiveTrafficFailureWindow = Duration(minutes: 5);
const _healthWatchdogProbeAttempts = 2;
const _healthWatchdogProbeDelay = Duration(milliseconds: 800);
const _serverLatencyCacheTtl = Duration(minutes: 8);
const _healthProbeHistoryWindow = Duration(hours: 1);
const _healthProbeHistoryLimit = 240;
const _codexProcessProbeTimeout = Duration(seconds: 5);

class _HealthProbeAttempt {
  const _HealthProbeAttempt({
    required this.timestamp,
    required this.endpoint,
    required this.endpointIndex,
    required this.attempt,
    required this.duration,
    required this.success,
    this.statusCode,
    this.errorType,
    this.errorMessage,
  });

  final DateTime timestamp;
  final Uri endpoint;
  final int endpointIndex;
  final int attempt;
  final Duration duration;
  final bool success;
  final int? statusCode;
  final String? errorType;
  final String? errorMessage;
}

class _HealthProbeResult {
  const _HealthProbeResult({
    required this.success,
    required this.attempts,
    required this.lastFailure,
  });

  final bool success;
  final List<_HealthProbeAttempt> attempts;
  final _HealthProbeAttempt? lastFailure;
}

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

enum _ProfileFilter { all, vless, naive, hysteria }

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
  Timer? _sessionTimer;
  DateTime? _ignoreStoppedUntil;
  DateTime? _healthWatchdogWarmupUntil;
  DateTime? _lastTrafficUpdateAt;
  DateTime? _connectedAt;

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
  bool _codexDirect = ProfileStore.defaultCodexDirect;
  bool _autoConnectAttempted = false;
  bool _isWindowsAdmin = !Platform.isWindows;
  bool _showAllProfiles = false;
  _ProfileFilter _profileFilter = _ProfileFilter.all;
  bool _healthWatchdogRestarting = false;
  int _healthWatchdogFailures = 0;
  DateTime? _healthWatchdogCooldownUntil;
  bool _quitFromTray = false;
  List<String> _splitTunnelExcludedProcesses = const [];
  List<String> _vpnOnlyProcesses = ProfileStore.defaultVpnOnlyProcesses;
  List<String> _subscriptionSources = const [];
  WindowsUpdateInfo? _updateInfo;
  Map<String, _ServerLatencyResult> _serverLatencies = const {};
  DateTime? _serverLatencyLastUpdated;
  bool _checkingServerLatency = false;
  bool _refreshingSubscriptions = false;
  bool _codexDiagnosticsBusy = false;
  String? _dismissedUpdateVersion;
  String? _lastConfigSummary;
  DateTime? _lastVpnReconnectAt;
  String? _lastVpnReconnectReason;
  bool _lastReconnectDuringCodex = false;
  final List<_HealthProbeAttempt> _healthProbeHistory = [];
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

  bool get _codexDirectSupported {
    final profile = _selectedProfile;
    return profile == null || _codexDirectSupportedForProfile(profile);
  }

  bool _codexDirectSupportedForProfile(VpnProfile profile) {
    return Platform.isWindows &&
        _vpnEngine.configTarget == SingBoxConfigTarget.windows &&
        profile.kind != VpnProfileKind.singBoxConfig;
  }

  bool get _connected =>
      _status == YurichConnectStatus.started ||
      _status == YurichConnectStatus.starting;

  Duration get _sessionDuration {
    final connectedAt = _connectedAt;
    if (connectedAt == null) {
      return Duration.zero;
    }
    final duration = DateTime.now().difference(connectedAt);
    return duration.isNegative ? Duration.zero : duration;
  }

  void _startSessionTimer() {
    _sessionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (_status != YurichConnectStatus.started) {
        _stopSessionTimer();
        return;
      }
      setState(() {});
    });
  }

  void _stopSessionTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }

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
    _sessionTimer?.cancel();
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
    final codexDirect = await _store.loadCodexDirect();
    final splitTunnelExcludedProcesses = await _store
        .loadSplitTunnelExcludedProcesses();
    final vpnOnlyProcesses = await _store.loadVpnOnlyProcesses();
    var subscriptionSources = await _store.loadSubscriptionSources();
    final inferredSubscriptionSources = _extractSubscriptionSourcesFromProfiles(
      profiles,
    );
    if (inferredSubscriptionSources.isNotEmpty) {
      final mergedSources = _mergeSubscriptionSources([
        ...subscriptionSources,
        ...inferredSubscriptionSources,
      ]);
      if (mergedSources.length != subscriptionSources.length) {
        subscriptionSources = mergedSources;
        await _store.saveSubscriptionSources(subscriptionSources);
      }
    }
    if (Platform.isWindows) {
      await _windowsIntegration.repairAutoStartIfNeeded();
    }
    final isWindowsAdmin = Platform.isWindows
        ? await _windowsIntegration.isCurrentProcessElevated()
        : true;
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
      _codexDirect = codexDirect;
      _autoStart = autoStart;
      _isWindowsAdmin = isWindowsAdmin;
      _splitTunnelExcludedProcesses = splitTunnelExcludedProcesses;
      _vpnOnlyProcesses = vpnOnlyProcesses;
      _subscriptionSources = subscriptionSources;
      _message = profiles.isEmpty
          ? strings.addProfileHint
          : strings.loadedProfiles(profiles.length);
    });
    if (profiles.isNotEmpty) {
      unawaited(_refreshServerLatencies());
    }
    if (Platform.isWindows) {
      unawaited(_checkForUpdates(silent: true, installIfAvailable: false));
    }

    if (Platform.isWindows &&
        autoConnect &&
        resolvedSelectedId != null &&
        !_autoConnectAttempted) {
      _autoConnectAttempted = true;
      _scheduleStartupAutoConnect(resolvedSelectedId);
    }
  }

  void _scheduleStartupAutoConnect(String profileId) {
    unawaited(_autoConnectWithRetry(profileId));
  }

  Future<void> _autoConnectWithRetry(String profileId) async {
    const delays = [
      Duration.zero,
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 32),
    ];

    for (var attempt = 0; attempt < delays.length; attempt += 1) {
      await Future<void>.delayed(delays[attempt]);
      if (!mounted || !_autoConnect || _connected) {
        return;
      }
      if (_selectedProfileId != profileId || _busy) {
        continue;
      }

      _queueLog(
        'Startup auto-connect attempt ${attempt + 1}/${delays.length}.',
      );
      await _connect();
      if (!mounted || _connected) {
        return;
      }
    }
  }

  Future<void> _initVpn() async {
    _statusSubscription = _vpnEngine.onStatusChanged.listen((event) {
      if (event['type'] == 'alert') {
        final message = event['message'] as String?;
        if (message != null && message.isNotEmpty && mounted) {
          setState(() {
            _message = message;
            _lastError = message;
            if (event['code'] == 'adminRequired') {
              _status = YurichConnectStatus.adminRequired;
              _isWindowsAdmin = false;
            }
          });
          if (event['code'] == 'adminRequired') {
            _showSnack(
              message,
              action: SnackBarAction(
                label: s.restartAsAdmin,
                onPressed: () => unawaited(_restartAsAdministrator()),
              ),
            );
          } else {
            _showSnack(message);
          }
        }
        return;
      }

      if (event['type'] == 'repair') {
        final message = event['message'] as String?;
        if (message != null && message.isNotEmpty && mounted) {
          setState(() {
            _message = message;
            _lastError = event['result'] == 'ok' ? null : message;
          });
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
            _connectedAt ??= DateTime.now();
            _ignoreStoppedUntil = DateTime.now().add(
              const Duration(seconds: 4),
            );
            _startSessionTimer();
            _startHealthWatchdog(warmup: const Duration(seconds: 30));
          } else if (status == YurichConnectStatus.stopped ||
              status == YurichConnectStatus.stopping) {
            if (status == YurichConnectStatus.stopped) {
              _connectedAt = null;
              _stopSessionTimer();
            }
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
          if (status == YurichConnectStatus.started) {
            _connectedAt ??= DateTime.now();
            _startSessionTimer();
          }
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
      final subscriptionSource = _normalizeSubscriptionSource(text);
      final imported = await _importer.importFromText(text);
      if (imported.isEmpty) {
        throw ProfileImportException(s.nothingToImport);
      }

      final subscriptionSources = subscriptionSource == null
          ? _subscriptionSources
          : _mergeSubscriptionSources([
              ..._subscriptionSources,
              subscriptionSource,
            ]);
      final merged = <String, VpnProfile>{
        for (final profile in _profiles) profile.id: profile,
        for (final profile in imported) profile.id: profile,
      }.values.toList();

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(imported.first.id);
      if (subscriptionSource != null) {
        await _store.saveSubscriptionSources(subscriptionSources);
      }
      _manualController.clear();

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = merged;
        _subscriptionSources = subscriptionSources;
        _selectedProfileId = imported.first.id;
        _serverLatencyLastUpdated = null;
        _message = s.imported(imported.length);
      });
      unawaited(_refreshTrayMenu());
      unawaited(_refreshServerLatencies());
      _showSnack(s.importedProfiles(imported.length));
    });
  }

  Future<void> _refreshSubscriptions() async {
    if (_busy || _refreshingSubscriptions) {
      return;
    }

    final sources = _mergeSubscriptionSources([
      ..._subscriptionSources,
      ..._extractSubscriptionSourcesFromProfiles(_profiles),
    ]);
    if (sources.isEmpty) {
      _showSnack(s.noSubscriptionSources);
      await _showImportSheet();
      return;
    }

    setState(() {
      _refreshingSubscriptions = true;
      _message = s.refreshingSubscriptions;
    });

    final imported = <VpnProfile>[];
    final errors = <String>[];
    try {
      for (final source in sources) {
        try {
          imported.addAll(await _importer.importFromText(source));
        } on Object catch (error) {
          errors.add(
            '${_redactSensitive(source)}: ${_redactSensitive('$error')}',
          );
        }
      }

      if (imported.isEmpty) {
        final message = errors.isEmpty ? s.nothingToImport : errors.first;
        throw ProfileImportException(message);
      }

      final merged = <String, VpnProfile>{
        for (final profile in _profiles) profile.id: profile,
        for (final profile in imported) profile.id: profile,
      }.values.toList();
      final selectedProfileId =
          _selectedProfileId != null &&
              merged.any((profile) => profile.id == _selectedProfileId)
          ? _selectedProfileId
          : imported.first.id;

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(selectedProfileId);
      await _store.saveSubscriptionSources(sources);

      if (!mounted) {
        return;
      }
      final message = errors.isEmpty
          ? s.subscriptionsUpdated(imported.length, sources.length)
          : s.subscriptionsUpdatedPartial(imported.length, errors.length);
      setState(() {
        _profiles = merged;
        _subscriptionSources = sources;
        _selectedProfileId = selectedProfileId;
        _serverLatencyLastUpdated = null;
        _message = message;
      });
      for (final error in errors.take(3)) {
        _queueLog('Subscription refresh warning: $error');
      }
      unawaited(_refreshTrayMenu());
      unawaited(_refreshServerLatencies());
      _showSnack(message);
    } on Object catch (error) {
      final message = _redactSensitive('$error');
      if (mounted) {
        setState(() {
          _lastError = message;
          _message = message;
        });
        _showSnack(message);
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingSubscriptions = false);
      }
    }
  }

  Future<void> _refreshServerLatencies({bool force = false}) async {
    if (_checkingServerLatency || _profiles.isEmpty) {
      return;
    }
    final lastUpdated = _serverLatencyLastUpdated;
    if (!force &&
        lastUpdated != null &&
        DateTime.now().difference(lastUpdated) < _serverLatencyCacheTtl) {
      return;
    }
    if (mounted) {
      setState(() => _checkingServerLatency = true);
    }
    final profiles = List<VpnProfile>.of(_profiles);
    try {
      final results = await _measureServerLatencies(profiles);
      if (!mounted) {
        return;
      }
      setState(() {
        _serverLatencies = results;
        _serverLatencyLastUpdated = DateTime.now();
      });
    } finally {
      if (mounted) {
        setState(() => _checkingServerLatency = false);
      }
    }
  }

  Future<Map<String, _ServerLatencyResult>> _measureServerLatencies(
    List<VpnProfile> profiles,
  ) async {
    final results = <String, _ServerLatencyResult>{};
    var nextIndex = 0;
    final workerCount = profiles.length < _maxConcurrentPingChecks
        ? profiles.length
        : _maxConcurrentPingChecks;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        nextIndex += 1;
        if (index >= profiles.length) {
          return;
        }
        final profile = profiles[index];
        results[profile.id] = await _measureServerLatency(profile);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results;
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
      if (mounted) {
        setState(() => _status = YurichConnectStatus.noProfile);
      }
      return;
    }

    if (Platform.isWindows && !_isWindowsAdmin) {
      await _showAdminRequiredDialog();
      return;
    }

    await _runBusy(
      () => _startVpnCore(profile),
      message: s.connectingTo(profile.name),
    );
  }

  Future<void> _showAdminRequiredDialog() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _status = YurichConnectStatus.adminRequired;
      _lastError = s.adminRightsRequired;
      _message = s.adminRightsRequired;
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.adminRightsRequiredTitle),
        content: Text(s.adminRightsRequiredBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.cancel),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_restartAsAdministrator());
            },
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: Text(s.restartAsAdmin),
          ),
        ],
      ),
    );
  }

  Future<void> _restartAsAdministrator() async {
    if (!Platform.isWindows) {
      return;
    }
    final started = await _windowsIntegration
        .restartCurrentProcessAsAdministrator();
    if (!started) {
      if (!mounted) {
        return;
      }
      _showSnack(s.adminRestartDeclined);
      return;
    }

    try {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object {
      // The elevated copy has already been requested; process exit is enough.
    }
    exit(0);
  }

  Future<void> _startVpnCore(VpnProfile profile) async {
    _validateProfileForStart(profile);
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
      String? lastProbeFailureReason;
      final config = _configBuilder.build(
        profile,
        target: _vpnEngine.configTarget,
        naiveMode: plan.naiveMode,
        splitTunnelExcludedProcesses: _splitTunnelExcludedProcesses,
        vpnOnlyProcesses: _vpnOnlyProcesses,
        codexDirect: _codexDirect && _codexDirectSupportedForProfile(profile),
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
            final probeResult =
                _vpnEngine.configTarget != SingBoxConfigTarget.windows
                ? const _HealthProbeResult(
                    success: true,
                    attempts: <_HealthProbeAttempt>[],
                    lastFailure: null,
                  )
                : await _probeLocalMixedProxy();
            if (probeResult.success) {
              connected = true;
              break;
            }
            final probeInfo = _healthProbeDescription(probeResult.lastFailure);
            final p99Latency = _healthProbeP99LatencyMs();
            final attemptCount = probeResult.attempts.length;
            lastProbeFailureReason = probeInfo;
            _queueLog(
              'VPN start probe failed for ${plan.label}: $probeInfo. '
              'attempts=$attemptCount, p99=${_formatLatency(p99Latency)}.',
            );
            final guardedSessionReason = await _healthReconnectGuardReason();
            if (guardedSessionReason != null) {
              _queueLog(
                'VPN start probe failed during $guardedSessionReason; keeping tunnel alive '
                'to preserve long-lived connections. Reason: $probeInfo.',
              );
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
            'VPN start retry [attempt=$attempt/2 · ${plan.label}]: '
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
        final fallbackProbeInfo = _healthProbeP99LatencyMs();
        _queueLog(
          'Naive mode fallback: ${plan.label} did not pass probe. '
          '${lastProbeFailureReason == null ? '' : 'Last failure: $lastProbeFailureReason. '}'
          'p99=${_formatLatency(fallbackProbeInfo)}.',
        );
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

  void _validateProfileForStart(VpnProfile profile) {
    if (profile.kind == VpnProfileKind.singBoxConfig) {
      final raw = profile.rawConfig?.trim();
      if (raw == null || raw.isEmpty) {
        throw StateError('Конфиг повреждён. Импортируйте профиль заново.');
      }
      try {
        jsonDecode(raw);
      } on Object {
        throw StateError('Конфиг повреждён. Импортируйте профиль заново.');
      }
      return;
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      throw StateError('Конфиг повреждён. Импортируйте профиль заново.');
    }

    final serverValue = profile.server ?? outbound['server'];
    final server = serverValue == null ? '' : '$serverValue'.trim();
    if (server.isEmpty) {
      throw StateError('В профиле отсутствует адрес сервера.');
    }

    switch (profile.kind) {
      case VpnProfileKind.vlessReality:
      case VpnProfileKind.vlessTls:
        final uuid = '${outbound['uuid'] ?? ''}'.trim();
        if (uuid.isEmpty) {
          throw StateError('В профиле отсутствует UUID.');
        }
        final tls = (outbound['tls'] as Map?)?.cast<String, dynamic>();
        if (profile.kind == VpnProfileKind.vlessReality) {
          final reality = (tls?['reality'] as Map?)?.cast<String, dynamic>();
          final publicKey = '${reality?['public_key'] ?? ''}'.trim();
          final serverName = '${tls?['server_name'] ?? ''}'.trim();
          if (publicKey.isEmpty) {
            throw StateError('Ошибка Reality: отсутствует publicKey.');
          }
          if (serverName.isEmpty) {
            throw StateError('Ошибка Reality: отсутствует serverName.');
          }
        }
        break;
      case VpnProfileKind.naive:
        final password = '${outbound['password'] ?? ''}'.trim();
        final username = '${outbound['username'] ?? ''}'.trim();
        if (username.isEmpty && password.isEmpty) {
          throw StateError('Ошибка NaiveProxy: неверный формат ссылки.');
        }
        break;
      case VpnProfileKind.hysteria:
        final auth = '${outbound['auth_str'] ?? outbound['auth'] ?? ''}'.trim();
        if (auth.isEmpty) {
          throw StateError('Ошибка Hysteria: отсутствует пароль.');
        }
        break;
      case VpnProfileKind.hysteria2:
        final password = '${outbound['password'] ?? ''}'.trim();
        if (password.isEmpty) {
          throw StateError('Ошибка Hysteria2: отсутствует пароль.');
        }
        break;
      case VpnProfileKind.singBoxConfig:
        break;
    }
  }

  List<_ConnectionConfigPlan> _connectionPlans(VpnProfile profile) {
    if (profile.kind != VpnProfileKind.naive) {
      return const [_ConnectionConfigPlan(NaiveOutboundMode.auto, 'auto')];
    }

    final outboundType = (profile.outbound?['type'] as String?)?.toLowerCase();
    if (_vpnEngine.configTarget == SingBoxConfigTarget.windows) {
      if (outboundType == 'http') {
        return const [
          _ConnectionConfigPlan(NaiveOutboundMode.externalCore, 'naive-core'),
          _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
          _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
        ];
      }

      return const [
        _ConnectionConfigPlan(NaiveOutboundMode.externalCore, 'naive-core'),
        _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
        _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
      ];
    }

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

  Future<_HealthProbeResult> _probeLocalMixedProxy({
    bool logFailures = true,
  }) async {
    final endpoints = <({Uri uri, bool allowCertificateMismatch})>[
      (
        uri: Uri.https('cp.cloudflare.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
      (
        uri: Uri.https('connectivitycheck.gstatic.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
      (
        uri: Uri.https('www.msftconnecttest.com', '/connecttest.txt'),
        allowCertificateMismatch: false,
      ),
      (uri: Uri.https('chatgpt.com', '/'), allowCertificateMismatch: false),
    ];

    final attempts = <_HealthProbeAttempt>[];

    for (
      var endpointIndex = 0;
      endpointIndex < endpoints.length;
      endpointIndex += 1
    ) {
      final endpoint = endpoints[endpointIndex];
      for (
        var attempt = 1;
        attempt <= _healthWatchdogProbeAttempts;
        attempt += 1
      ) {
        final startedAt = DateTime.now();
        final stopwatch = Stopwatch()..start();
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 6)
          ..badCertificateCallback = endpoint.allowCertificateMismatch
              ? (_, host, _) => host == endpoint.uri.host
              : null
          ..findProxy = (_) =>
              'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
        _HealthProbeAttempt? attemptLog;
        try {
          final request = await client
              .getUrl(endpoint.uri)
              .timeout(const Duration(seconds: 6));
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'YurichConnect/$_appVersion',
          );
          request.followRedirects = false;
          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          await response.drain<void>().timeout(
            const Duration(seconds: 4),
            onTimeout: () {},
          );
          attemptLog = _HealthProbeAttempt(
            timestamp: startedAt,
            endpoint: endpoint.uri,
            endpointIndex: endpointIndex,
            attempt: attempt,
            duration: stopwatch.elapsed,
            success: response.statusCode >= 200 && response.statusCode < 400,
            statusCode: response.statusCode,
          );
        } on TimeoutException catch (error) {
          attemptLog = _HealthProbeAttempt(
            timestamp: startedAt,
            endpoint: endpoint.uri,
            endpointIndex: endpointIndex,
            attempt: attempt,
            duration: stopwatch.elapsed,
            success: false,
            errorType: 'timeout',
            errorMessage: _redactSensitive('$error'),
          );
        } on SocketException catch (error) {
          attemptLog = _HealthProbeAttempt(
            timestamp: startedAt,
            endpoint: endpoint.uri,
            endpointIndex: endpointIndex,
            attempt: attempt,
            duration: stopwatch.elapsed,
            success: false,
            errorType: 'socket',
            errorMessage: _redactSensitive('$error'),
          );
        } on HandshakeException catch (error) {
          attemptLog = _HealthProbeAttempt(
            timestamp: startedAt,
            endpoint: endpoint.uri,
            endpointIndex: endpointIndex,
            attempt: attempt,
            duration: stopwatch.elapsed,
            success: false,
            errorType: 'tls',
            errorMessage: _redactSensitive('$error'),
          );
        } on HttpException catch (error) {
          attemptLog = _HealthProbeAttempt(
            timestamp: startedAt,
            endpoint: endpoint.uri,
            endpointIndex: endpointIndex,
            attempt: attempt,
            duration: stopwatch.elapsed,
            success: false,
            errorType: 'http',
            errorMessage: _redactSensitive('$error'),
          );
        } on Object catch (error) {
          attemptLog = _HealthProbeAttempt(
            timestamp: startedAt,
            endpoint: endpoint.uri,
            endpointIndex: endpointIndex,
            attempt: attempt,
            duration: stopwatch.elapsed,
            success: false,
            errorType: 'unknown',
            errorMessage: _redactSensitive('$error'),
          );
        } finally {
          client.close(force: true);
          stopwatch.stop();
        }

        attempts.add(attemptLog);
        _recordHealthProbeAttempt(attemptLog);

        if (attemptLog.success) {
          return _HealthProbeResult(
            success: true,
            attempts: List.unmodifiable(attempts),
            lastFailure: null,
          );
        }

        if (logFailures &&
            attempt == _healthWatchdogProbeAttempts &&
            endpointIndex == endpoints.length - 1) {
          _queueLog(
            'VPN health probe failed: ${_healthProbeDescription(attemptLog)}.',
          );
        }

        if (attempt < _healthWatchdogProbeAttempts) {
          await Future<void>.delayed(_healthWatchdogProbeDelay);
        }
      }
    }

    _HealthProbeAttempt? lastFailure;
    for (final attempt in attempts.reversed) {
      if (!attempt.success) {
        lastFailure = attempt;
        break;
      }
    }
    return _HealthProbeResult(
      success: false,
      attempts: List.unmodifiable(attempts),
      lastFailure: lastFailure,
    );
  }

  void _recordHealthProbeAttempt(_HealthProbeAttempt attempt) {
    _healthProbeHistory.add(attempt);
    final cutoff = DateTime.now().subtract(_healthProbeHistoryWindow);
    _healthProbeHistory.removeWhere(
      (entry) => entry.timestamp.isBefore(cutoff),
    );
    if (_healthProbeHistory.length > _healthProbeHistoryLimit) {
      _healthProbeHistory.removeRange(
        0,
        _healthProbeHistory.length - _healthProbeHistoryLimit,
      );
    }
  }

  int _healthProbeP99LatencyMs() {
    final cutoff = DateTime.now().subtract(_healthProbeHistoryWindow);
    final durations =
        _healthProbeHistory
            .where((entry) => entry.timestamp.isAfter(cutoff))
            .map((entry) => entry.duration.inMilliseconds)
            .where((value) => value > 0)
            .toList()
          ..sort();
    if (durations.isEmpty) {
      return 0;
    }
    final index = ((durations.length - 1) * 99 / 100).round();
    final safeIndex = index.clamp(0, durations.length - 1).toInt();
    return durations[safeIndex];
  }

  String _healthProbeDescription(_HealthProbeAttempt? attempt) {
    if (attempt == null) {
      return 'unknown probe issue';
    }
    if (attempt.statusCode != null) {
      return 'HTTP ${attempt.statusCode} on ${attempt.endpoint.host} '
          '(probe #${attempt.endpointIndex + 1}-${attempt.attempt})';
    }
    final errorType = attempt.errorType ?? 'error';
    final detail = attempt.errorMessage;
    return '[$errorType] on ${attempt.endpoint.host} '
        '(probe #${attempt.endpointIndex + 1}-${attempt.attempt})'
        '${detail == null || detail.isEmpty ? '' : ': $detail'}';
  }

  String _formatLatency(int ms) => ms <= 0 ? 'n/a' : '${ms}ms';

  void _startHealthWatchdog({Duration warmup = _healthWatchdogStartupGrace}) {
    if (!Platform.isWindows) {
      return;
    }
    _healthWatchdogTimer?.cancel();
    _healthWatchdogFailures = 0;
    _healthWatchdogCooldownUntil = null;
    _healthWatchdogWarmupUntil = DateTime.now().add(warmup);
    _healthWatchdogTimer = Timer.periodic(_healthWatchdogTick, (_) {
      unawaited(_runHealthWatchdogTick());
    });
  }

  void _stopHealthWatchdog() {
    _healthWatchdogTimer?.cancel();
    _healthWatchdogTimer = null;
    _healthWatchdogWarmupUntil = null;
    _healthWatchdogFailures = 0;
    _healthWatchdogCooldownUntil = null;
  }

  Future<void> _runHealthWatchdogTick() async {
    if (!mounted ||
        !Platform.isWindows ||
        _busy ||
        _healthWatchdogRestarting ||
        _status != YurichConnectStatus.started) {
      return;
    }

    final cooldownUntil = _healthWatchdogCooldownUntil;
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      return;
    }

    final warmupUntil = _healthWatchdogWarmupUntil;
    if (warmupUntil != null && DateTime.now().isBefore(warmupUntil)) {
      return;
    }

    final probeResult = await _probeLocalMixedProxy(logFailures: false);
    if (probeResult.success) {
      if (_healthWatchdogFailures > 0) {
        _queueLog(
          'VPN health watchdog recovered. '
          'p99=${_formatLatency(_healthProbeP99LatencyMs())}.',
        );
      }
      _healthWatchdogFailures = 0;
      return;
    }

    final probeDescription = _healthProbeDescription(probeResult.lastFailure);
    final probeP99 = _healthProbeP99LatencyMs();
    final probeAttempts = probeResult.attempts.length;

    final guardedSessionReason = await _healthReconnectGuardReason();
    if (guardedSessionReason != null) {
      _healthWatchdogFailures = 0;
      _healthWatchdogCooldownUntil = DateTime.now().add(
        _healthWatchdogActiveTrafficFailureWindow,
      );
      _queueLog(
        'VPN health watchdog probe failed during $guardedSessionReason: $probeDescription. '
        'attempts=$probeAttempts, p99=${_formatLatency(probeP99)}. '
        'Reconnect skipped to preserve long-lived connections.',
      );
      return;
    }

    _healthWatchdogFailures += 1;
    _queueLog(
      'VPN health watchdog failed $_healthWatchdogFailures/'
      '$_healthWatchdogFailureLimit: $probeDescription. '
      'attempts=$probeAttempts, p99=${_formatLatency(probeP99)}.',
    );
    if (_healthWatchdogFailures < _healthWatchdogFailureLimit) {
      _healthWatchdogCooldownUntil = DateTime.now().add(
        _healthWatchdogRetryGrace,
      );
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      _healthWatchdogFailures = 0;
      _healthWatchdogCooldownUntil = null;
      return;
    }

    final codexActive = await _hasActiveCodexProcess();
    if (codexActive) {
      _healthWatchdogFailures = 0;
      _healthWatchdogCooldownUntil = DateTime.now().add(
        _healthWatchdogActiveTrafficFailureWindow,
      );
      _queueLog(
        'Codex WebSocket may be interrupted by VPN reconnect; reconnect skipped. '
        'Reason: $probeDescription. attempts=$probeAttempts, '
        'p99=${_formatLatency(probeP99)}.',
      );
      return;
    }

    _healthWatchdogRestarting = true;
    _healthWatchdogCooldownUntil = DateTime.now().add(
      _healthWatchdogActiveTrafficFailureWindow,
    );
    _lastVpnReconnectAt = DateTime.now();
    _lastVpnReconnectReason = probeDescription;
    _lastReconnectDuringCodex = codexActive;
    _queueLog(
      'VPN health watchdog restarting tunnel after repeated probe failures: '
      '$probeDescription. attempts=$probeAttempts, p99=${_formatLatency(probeP99)}.',
    );
    if (mounted) {
      setState(() {
        _status = YurichConnectStatus.reconnecting;
        _message = s.reconnecting;
      });
    }
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
        DateTime.now().difference(lastUpdateAt) > const Duration(seconds: 20)) {
      return false;
    }
    return _uplinkBytesPerSecond + _downlinkBytesPerSecond > 2048;
  }

  Future<String?> _healthReconnectGuardReason() async {
    if (_hasActiveTraffic()) {
      return 'active traffic';
    }
    if (_codexDirect && await _hasActiveCodexProcess()) {
      return 'active Codex session';
    }
    return null;
  }

  Future<bool> _hasActiveCodexProcess() async {
    if (!Platform.isWindows) {
      return false;
    }
    const script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$codexNames = @('codex.exe', 'Codex.exe', 'openai-codex.exe', 'OpenAI Codex.exe')
$match = Get-CimInstance Win32_Process | Where-Object {
  $name = [string]$_.Name
  $path = [string]$_.ExecutablePath
  $command = [string]$_.CommandLine
  ($codexNames -contains $name) -or
    ($name -ieq 'node.exe' -and (($path -match '(?i)(codex|openai)') -or ($command -match '(?i)(codex|openai)')))
} | Select-Object -First 1
if ($null -ne $match) { 'true' } else { 'false' }
''';
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(_codexProcessProbeTimeout);
      return '${result.stdout}'.toLowerCase().contains('true');
    } on Object {
      return false;
    }
  }

  Future<String> _diagnoseDnsHost(String host) async {
    final stopwatch = Stopwatch()..start();
    try {
      final addresses = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 6));
      stopwatch.stop();
      final preview = addresses
          .take(3)
          .map((address) => address.address)
          .join(', ');
      return 'Codex DNS $host: ok in ${stopwatch.elapsedMilliseconds}ms'
          '${preview.isEmpty ? '' : ' -> $preview'}.';
    } on Object catch (error) {
      stopwatch.stop();
      return 'Codex DNS $host: failed in ${stopwatch.elapsedMilliseconds}ms: '
          '${_redactSensitive('$error')}.';
    }
  }

  Future<String> _diagnoseTcp443(String host) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        443,
        timeout: const Duration(seconds: 8),
      );
      stopwatch.stop();
      return 'Codex TCP $host:443: ok in ${stopwatch.elapsedMilliseconds}ms.';
    } on Object catch (error) {
      stopwatch.stop();
      return 'Codex TCP $host:443: failed in ${stopwatch.elapsedMilliseconds}ms: '
          '${_redactSensitive('$error')}.';
    } finally {
      socket?.destroy();
    }
  }

  Future<String> _diagnoseCodexWebSocket() async {
    final stopwatch = Stopwatch()..start();
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(
        'wss://chatgpt.com/Codex',
        headers: {HttpHeaders.userAgentHeader: 'YurichConnect/$_appVersion'},
      ).timeout(const Duration(seconds: 8));
      stopwatch.stop();
      return 'Codex WebSocket upgrade: ok in ${stopwatch.elapsedMilliseconds}ms.';
    } on Object catch (error) {
      stopwatch.stop();
      return 'Codex WebSocket upgrade: not established in '
          '${stopwatch.elapsedMilliseconds}ms: ${_redactSensitive('$error')}. '
          'If DNS/TCP are ok, ChatGPT may reject unauthenticated diagnostic upgrades.';
    } finally {
      unawaited(socket?.close());
    }
  }

  String _formatDurationAgo(DateTime timestamp) {
    final elapsed = DateTime.now().difference(timestamp);
    if (elapsed.inMinutes >= 1) {
      return '${elapsed.inMinutes}m';
    }
    return '${elapsed.inSeconds}s';
  }

  Future<void> _disconnect() async {
    await _runBusy(() => _stopVpnCore(), message: s.disconnectingVpn);
  }

  Future<void> _repairConnection() async {
    await _runBusy(() async {
      final ok = await _vpnEngine.repairConnection();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = ok ? YurichConnectStatus.stopped : YurichConnectStatus.error;
        _connectedAt = null;
        _uplink = '0 B/s';
        _downlink = '0 B/s';
        _sessionTotal = '0 B';
        _lastError = ok ? null : s.repairFailed;
        _message = ok ? s.repairOk : s.repairFailed;
      });
      if (ok) {
        _showSnack(s.repairOk);
      } else {
        _showSnack(
          s.repairFailed,
          action: SnackBarAction(
            label: s.report,
            onPressed: () => unawaited(_emailDeveloper()),
          ),
        );
      }
    }, message: s.repairingConnection);
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
          const Duration(seconds: 16),
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

  Future<void> _setCodexDirect(bool value) async {
    if (!Platform.isWindows) {
      return;
    }
    if (!_codexDirectSupported) {
      _showSnack(s.codexDirectTunOnly);
      return;
    }
    await _store.saveCodexDirect(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _codexDirect = value;
      _message = _connected ? s.reconnectToApply : s.settingsSaved;
    });
    _queueLog(
      value
          ? 'Codex direct mode enabled: ChatGPT/OpenAI domains and Codex executables will bypass the VPN in Windows TUN mode.'
          : 'Codex direct mode disabled: Codex will follow the regular VPN routing rules.',
    );
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
      final enabled = await _windowsIntegration.isAutoStartEnabled();
      if (mounted) {
        setState(() => _autoStart = enabled);
        _showSnack('${s.autoStartFailed}: ${_redactSensitive('$e')}');
      }
    } finally {
      if (mounted) {
        setState(() => _windowsSettingsBusy = false);
      }
    }
  }

  Future<void> _runCodexDiagnostics() async {
    if (_codexDiagnosticsBusy) {
      return;
    }
    setState(() => _codexDiagnosticsBusy = true);
    final lines = <String>[
      'Codex diagnostics started. direct=$_codexDirect, supported=$_codexDirectSupported, status=$_status.',
    ];
    try {
      final codexProcessActive = await _hasActiveCodexProcess();
      lines.add(
        'Codex process: ${codexProcessActive ? 'active' : 'not detected'}.',
      );
      for (final host in const ['chatgpt.com', 'ws.chatgpt.com']) {
        lines.add(await _diagnoseDnsHost(host));
      }
      lines.add(await _diagnoseTcp443('chatgpt.com'));
      lines.add(await _diagnoseCodexWebSocket());
      final reconnectAt = _lastVpnReconnectAt;
      if (reconnectAt == null) {
        lines.add('VPN reconnect during this app session: none recorded.');
      } else {
        lines.add(
          'Last VPN reconnect: ${_formatDurationAgo(reconnectAt)} ago; '
          'reason=${_redactSensitive(_lastVpnReconnectReason ?? 'unknown')}; '
          'during_codex=$_lastReconnectDuringCodex.',
        );
      }
    } on Object catch (error) {
      lines.add('Codex diagnostics failed: ${_redactSensitive('$error')}');
    } finally {
      for (final line in lines) {
        _queueLog(line);
      }
      if (mounted) {
        setState(() {
          _codexDiagnosticsBusy = false;
          _message = s.codexDiagnosticsDone;
        });
        _showSnack(s.codexDiagnosticsDone);
      }
    }
  }

  Future<void> _checkForUpdates({
    bool silent = false,
    bool installIfAvailable = true,
  }) async {
    if (_checkingUpdate || _installingUpdate) {
      return;
    }
    setState(() {
      _checkingUpdate = true;
      if (!silent) {
        _updateInfo = null;
        _message = s.checkingUpdates;
      }
    });
    try {
      final info = await _windowsIntegration.checkForUpdate(_appVersion);
      if (!mounted) {
        return;
      }
      setState(() {
        _checkingUpdate = false;
        _updateInfo = info;
        if (!silent) {
          _message = s.updateMessage(info);
        }
      });

      if (!info.available || !installIfAvailable) {
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
      if (mounted && !silent) {
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
    final value = await _showProcessListSheet(
      current: _splitTunnelExcludedProcesses,
      title: s.splitTunnelTitle,
      description: s.splitTunnelDescription,
      hint: s.splitTunnelHint,
      pickExeTitle: s.splitTunnelPickExeTitle,
    );

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

  Future<void> _showVpnOnlySheet() async {
    final value = await _showProcessListSheet(
      current: _vpnOnlyProcesses,
      title: s.vpnOnlyTitle,
      description: s.vpnOnlyDescription,
      hint: s.vpnOnlyHint,
      pickExeTitle: s.vpnOnlyPickExeTitle,
    );

    if (value == null) {
      return;
    }
    await _store.saveVpnOnlyProcesses(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _vpnOnlyProcesses = value;
      _message = _connected ? s.reconnectToApply : s.settingsSaved;
    });
  }

  Future<List<String>?> _showProcessListSheet({
    required List<String> current,
    required String title,
    required String description,
    required String hint,
    required String pickExeTitle,
  }) async {
    final controller = TextEditingController(text: current.join('\n'));
    final value = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        Future<void> pickExecutables() async {
          final result = await FilePicker.pickFiles(
            dialogTitle: pickExeTitle,
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
          title: Text(title),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  minLines: 4,
                  maxLines: 8,
                  decoration: InputDecoration(hintText: hint),
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
    return value;
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

  List<String> _extractSubscriptionSourcesFromProfiles(
    List<VpnProfile> profiles,
  ) {
    return _mergeSubscriptionSources(
      profiles
          .map((profile) => profile.originalInput)
          .map(_normalizeSubscriptionSource)
          .whereType<String>(),
    );
  }

  List<String> _mergeSubscriptionSources(Iterable<String> sources) {
    final normalized =
        sources
            .map(_normalizeSubscriptionSource)
            .whereType<String>()
            .toSet()
            .toList()
          ..sort();
    return normalized;
  }

  String? _normalizeSubscriptionSource(String value) {
    final text = value.trim();
    if (text.isEmpty ||
        text.length > 4096 ||
        text.contains(RegExp(r'\s')) ||
        text.contains(RegExp(r'^(?:vless|naive|hysteria2|hy2|hysteria)://'))) {
      return null;
    }

    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri.toString();
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

  Future<void> _deleteProfile(VpnProfile profile) async {
    final next = _profiles
        .where((savedProfile) => savedProfile.id != profile.id)
        .toList();
    final deletingSelected = _selectedProfileId == profile.id;
    final nextSelectedId = deletingSelected
        ? (next.isEmpty ? null : next.first.id)
        : _selectedProfileId;
    await _store.saveProfiles(next);
    await _store.saveSelectedProfileId(nextSelectedId);
    if (!mounted) {
      return;
    }
    setState(() {
      _profiles = next;
      _selectedProfileId = nextSelectedId;
      _serverLatencyLastUpdated = null;
      _serverLatencies = Map<String, _ServerLatencyResult>.of(_serverLatencies)
        ..remove(profile.id);
      _message = s.profileDeleted;
    });
    if (_profiles.isNotEmpty) {
      unawaited(_refreshServerLatencies());
    }
    unawaited(_refreshTrayMenu());
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
      'codex_direct: $_codexDirect',
      'codex_direct_supported: $_codexDirectSupported',
      if (_lastVpnReconnectAt != null)
        'last_reconnect: ${_formatDurationAgo(_lastVpnReconnectAt!)} ago; '
            'reason=${_redactSensitive(_lastVpnReconnectReason ?? 'unknown')}; '
            'during_codex=$_lastReconnectDuringCodex',
      if (_lastError != null) 'last_error: $_lastError',
      if (profile != null) ...[
        'profile: ${_redactSensitive(profile.name)}',
        'protocol: ${_profileKindLabel(profile.kind)}',
        'endpoint: ${_redactSensitive(profile.endpoint)}',
      ],
      'traffic: up=$_uplink down=$_downlink total=$_sessionTotal',
      'health_probe_p99_ms: ${_healthProbeP99LatencyMs()}'
          ' (${_healthProbeHistory.length} probes in window)',
      if (_healthProbeHistory.isNotEmpty)
        'health_probe_last: ${_healthProbeDescription(_healthProbeHistory.last)}',
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
    return SecretRedactor.redact(value);
  }

  String _formatLogTimestamp(DateTime time) {
    return '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }

  void _queueLog(String message) {
    final cleaned = _cleanLog(message);
    if (cleaned.isEmpty) {
      return;
    }

    final timestamped = '${_formatLogTimestamp(DateTime.now())} $cleaned';
    _pendingLogs.add(timestamped);
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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Column(
                children: [
                  _buildConnectButton(context, selected),
                  if (_shouldShowUpdateBanner()) ...[
                    const SizedBox(height: 10),
                    _UpdateBanner(
                      strings: s,
                      updateInfo: _updateInfo!,
                      checkingUpdate: _checkingUpdate,
                      installingUpdate: _installingUpdate,
                      onUpdate: () => unawaited(_checkForUpdates()),
                      onDismiss: () {
                        setState(() {
                          _dismissedUpdateVersion = _updateInfo!.latestVersion;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                children: [
                  _StatusPanel(
                    strings: s,
                    status: _status,
                    message: _message,
                    uplink: _uplink,
                    downlink: _downlink,
                    sessionTotal: _sessionTotal,
                    sessionDuration: _sessionDuration,
                  ),
                  if (_status == YurichConnectStatus.adminRequired ||
                      _lastError != null) ...[
                    const SizedBox(height: 10),
                    _IssueActionPanel(
                      strings: s,
                      status: _status,
                      error: _lastError,
                      busy: _busy,
                      canRetry: selected != null,
                      onRetry: () => unawaited(_connect()),
                      onRestartAsAdmin: Platform.isWindows
                          ? () => unawaited(_restartAsAdministrator())
                          : null,
                      onRepair: () => unawaited(_repairConnection()),
                      onReport: () => unawaited(_emailDeveloper()),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _ProfilePanel(
                    strings: s,
                    profiles: _profiles,
                    selectedId: selected?.id,
                    serverLatencies: _serverLatencies,
                    checkingServerLatency: _checkingServerLatency,
                    refreshingSubscriptions: _refreshingSubscriptions,
                    showAllProfiles: _showAllProfiles,
                    selectedFilter: _profileFilter,
                    onSelect: _selectProfile,
                    onAdd: _showImportSheet,
                    onRefreshSubscriptions: () =>
                        unawaited(_refreshSubscriptions()),
                    onCopy: selected == null ? null : _copySelected,
                    onQr: selected == null ? null : _showQr,
                    onDeleteProfile: (profile) =>
                        unawaited(_deleteProfile(profile)),
                    onToggleShowAllProfiles: () =>
                        setState(() => _showAllProfiles = !_showAllProfiles),
                    onFilterChanged: (filter) => setState(() {
                      _profileFilter = filter;
                      _showAllProfiles = false;
                    }),
                    onRefreshLatency: () =>
                        unawaited(_refreshServerLatencies(force: true)),
                    kindLabel: _profileKindLabel,
                  ),
                  if (Platform.isWindows) ...[
                    const SizedBox(height: 14),
                    _WindowsToolsPanel(
                      strings: s,
                      autoStart: _autoStart,
                      autoConnect: _autoConnect,
                      codexDirect: _codexDirect,
                      codexDirectSupported: _codexDirectSupported,
                      busy: _windowsSettingsBusy,
                      checkingUpdate: _checkingUpdate,
                      installingUpdate: _installingUpdate,
                      codexDiagnosticsBusy: _codexDiagnosticsBusy,
                      excludedProcessCount:
                          _splitTunnelExcludedProcesses.length,
                      vpnOnlyProcessCount: _vpnOnlyProcesses.length,
                      updateInfo: _updateInfo,
                      onAutoStartChanged: (value) =>
                          unawaited(_setAutoStart(value)),
                      onAutoConnectChanged: (value) =>
                          unawaited(_setAutoConnect(value)),
                      onCodexDirectChanged: (value) =>
                          unawaited(_setCodexDirect(value)),
                      onEditSplitTunnel: _showSplitTunnelSheet,
                      onEditVpnOnly: _showVpnOnlySheet,
                      onCodexDiagnostics: () =>
                          unawaited(_runCodexDiagnostics()),
                      onCheckUpdate: _checkForUpdates,
                      onOpenReleases: () =>
                          _openUrl(WindowsIntegrationService.releasesUrl),
                      onRepairConnection: () => unawaited(_repairConnection()),
                    ),
                  ],
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
          ],
        ),
      ),
    );
  }

  Widget _buildConnectButton(BuildContext context, VpnProfile? selected) {
    final label = switch (_status) {
      YurichConnectStatus.starting => s.connecting,
      YurichConnectStatus.stopping => s.disconnecting,
      YurichConnectStatus.reconnecting => s.reconnecting,
      YurichConnectStatus.started => s.disconnect,
      _ => s.connect,
    };
    final icon = switch (_status) {
      YurichConnectStatus.starting ||
      YurichConnectStatus.reconnecting => Icons.sync,
      YurichConnectStatus.stopping => Icons.power_settings_new,
      YurichConnectStatus.started => Icons.power_settings_new,
      _ => Icons.shield,
    };
    return FilledButton.icon(
      onPressed: _busy || selected == null ? null : _toggleVpn,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        textStyle: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  bool _shouldShowUpdateBanner() {
    final info = _updateInfo;
    return Platform.isWindows &&
        info != null &&
        info.available &&
        info.latestVersion != null &&
        _dismissedUpdateVersion != info.latestVersion;
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.strings,
    required this.updateInfo,
    required this.checkingUpdate,
    required this.installingUpdate,
    required this.onUpdate,
    required this.onDismiss,
  });

  final _Strings strings;
  final WindowsUpdateInfo updateInfo;
  final bool checkingUpdate;
  final bool installingUpdate;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final busy = checkingUpdate || installingUpdate;
    final version = updateInfo.latestVersion ?? '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surfaceMetric,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.54)),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            const Icon(Icons.system_update_alt, color: _goldSoft, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.updateBannerTitle(version),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: _goldSoft,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    strings.updateBannerBody,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _mutedGold, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : onUpdate,
              style: FilledButton.styleFrom(
                minimumSize: const Size(88, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(
                busy ? strings.checkingUpdates : strings.updateNow,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: strings.close,
              onPressed: busy ? null : onDismiss,
              icon: const Icon(Icons.close, size: 18),
            ),
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
    required this.sessionDuration,
  });

  final _Strings strings;
  final String status;
  final String message;
  final String uplink;
  final String downlink;
  final String sessionTotal;
  final Duration sessionDuration;

  @override
  Widget build(BuildContext context) {
    final connected = status == YurichConnectStatus.started;
    final statusLabel = switch (status) {
      YurichConnectStatus.started => strings.connected,
      YurichConnectStatus.starting => strings.connecting,
      YurichConnectStatus.stopping => strings.disconnecting,
      YurichConnectStatus.reconnecting => strings.reconnecting,
      YurichConnectStatus.adminRequired => strings.adminRequiredStatus,
      YurichConnectStatus.noProfile => strings.noProfileStatus,
      YurichConnectStatus.noInternet => strings.noInternetStatus,
      YurichConnectStatus.error => strings.errorStatus,
      _ => strings.stopped,
    };

    return SizedBox(
      height: _statusPanelHeight,
      child: DecoratedBox(
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
                    status == YurichConnectStatus.error
                        ? Icons.error_outline
                        : status == YurichConnectStatus.adminRequired
                        ? Icons.admin_panel_settings_outlined
                        : connected
                        ? Icons.verified_user
                        : Icons.shield_outlined,
                    color: status == YurichConnectStatus.error
                        ? Colors.redAccent
                        : status == YurichConnectStatus.adminRequired
                        ? Colors.orangeAccent
                        : connected
                        ? _goldSoft
                        : _mutedGold,
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
              SizedBox(
                height: 36,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _mutedGold),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _Metric(label: '↑', value: uplink),
                      ),
                    ),
                    const SizedBox(width: 14),
                    _SessionDial(
                      connected: connected,
                      duration: sessionDuration,
                      total: sessionTotal,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _Metric(label: '↓', value: downlink),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IssueActionPanel extends StatelessWidget {
  const _IssueActionPanel({
    required this.strings,
    required this.status,
    required this.error,
    required this.busy,
    required this.canRetry,
    required this.onRetry,
    required this.onRestartAsAdmin,
    required this.onRepair,
    required this.onReport,
  });

  final _Strings strings;
  final String status;
  final String? error;
  final bool busy;
  final bool canRetry;
  final VoidCallback onRetry;
  final VoidCallback? onRestartAsAdmin;
  final VoidCallback onRepair;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final adminRequired = status == YurichConnectStatus.adminRequired;
    final title = adminRequired
        ? strings.adminRightsRequiredTitle
        : strings.connectionErrorTitle;
    final body = adminRequired
        ? strings.adminRightsRequiredBody
        : (error == null || error!.isEmpty
              ? strings.connectionErrorBody
              : error!);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF22171B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.34)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  adminRequired
                      ? Icons.admin_panel_settings_outlined
                      : Icons.error_outline,
                  color: Colors.orangeAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFE4C9B4), height: 1.25),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (adminRequired && onRestartAsAdmin != null)
                  FilledButton.icon(
                    onPressed: busy ? null : onRestartAsAdmin,
                    icon: const Icon(Icons.restart_alt),
                    label: Text(strings.restartAsAdmin),
                  ),
                if (!adminRequired)
                  OutlinedButton.icon(
                    onPressed: busy || !canRetry ? null : onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(strings.tryAgain),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onRepair,
                  icon: const Icon(Icons.healing_outlined),
                  label: Text(strings.repairConnection),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onReport,
                  icon: const Icon(Icons.description_outlined),
                  label: Text(strings.sendReport),
                ),
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

  static const _width = 100.0;
  static const _height = 38.0;

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      height: _height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surfaceMetric,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _gold.withValues(alpha: 0.18)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$label $value',
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDial extends StatelessWidget {
  const _SessionDial({
    required this.connected,
    required this.duration,
    required this.total,
  });

  final bool connected;
  final Duration duration;
  final String total;

  @override
  Widget build(BuildContext context) {
    final durationLabel = _formatSessionDuration(duration);
    return Container(
      width: 116,
      height: 116,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: connected
              ? const [Color(0xFF9BE7FF), Color(0xFF1EC8FF), Color(0xFF0B6ED7)]
              : const [Color(0xFF294560), Color(0xFF19344E), Color(0xFF0E2237)],
        ),
        border: Border.all(color: _goldSoft.withValues(alpha: 0.86), width: 2),
        boxShadow: [
          BoxShadow(
            color: connected
                ? _gold.withValues(alpha: 0.42)
                : Colors.black.withValues(alpha: 0.18),
            blurRadius: 28,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.timer_outlined,
            color: connected ? _ink : _mutedGold,
            size: 24,
          ),
          const SizedBox(height: 4),
          Text(
            durationLabel,
            style: TextStyle(
              color: connected ? _ink : _goldSoft,
              fontWeight: FontWeight.w800,
              fontSize: 22,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            total,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: connected ? _ink.withValues(alpha: 0.7) : _mutedGold,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
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
    required this.refreshingSubscriptions,
    required this.showAllProfiles,
    required this.selectedFilter,
    required this.onSelect,
    required this.onAdd,
    required this.onRefreshSubscriptions,
    required this.onCopy,
    required this.onQr,
    required this.onDeleteProfile,
    required this.onToggleShowAllProfiles,
    required this.onFilterChanged,
    required this.onRefreshLatency,
    required this.kindLabel,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final String? selectedId;
  final Map<String, _ServerLatencyResult> serverLatencies;
  final bool checkingServerLatency;
  final bool refreshingSubscriptions;
  final bool showAllProfiles;
  final _ProfileFilter selectedFilter;
  final ValueChanged<VpnProfile> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onRefreshSubscriptions;
  final VoidCallback? onCopy;
  final VoidCallback? onQr;
  final ValueChanged<VpnProfile> onDeleteProfile;
  final VoidCallback onToggleShowAllProfiles;
  final ValueChanged<_ProfileFilter> onFilterChanged;
  final VoidCallback onRefreshLatency;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
    final filteredProfiles = _filteredProfiles();
    final visibleProfiles = _visibleProfiles(filteredProfiles);
    final hiddenCount = filteredProfiles.length - visibleProfiles.length;
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
              tooltip: strings.refreshSubscriptions,
              onPressed: refreshingSubscriptions
                  ? null
                  : onRefreshSubscriptions,
              icon: refreshingSubscriptions
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
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
              tooltip: strings.pingRefresh,
              onPressed: checkingServerLatency || profiles.isEmpty
                  ? null
                  : onRefreshLatency,
              icon: checkingServerLatency
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ProfileFilterBar(
          strings: strings,
          profiles: profiles,
          selectedFilter: selectedFilter,
          onChanged: onFilterChanged,
        ),
        const SizedBox(height: 12),
        if (profiles.isEmpty)
          _EmptyProfiles(strings: strings)
        else if (filteredProfiles.isEmpty)
          _EmptyProfiles(
            strings: strings,
            message: _profileFilterEmptyLabel(selectedFilter, strings),
          )
        else
          ...visibleProfiles.map(
            (profile) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProfileTile(
                profile: profile,
                selected: profile.id == selectedId,
                latency: serverLatencies[profile.id],
                checkingLatency: checkingServerLatency,
                onTap: () => onSelect(profile),
                onRefreshLatency: onRefreshLatency,
                onDelete: () => onDeleteProfile(profile),
                strings: strings,
                kindLabel: kindLabel,
              ),
            ),
          ),
        if (hiddenCount > 0 ||
            (showAllProfiles &&
                filteredProfiles.length > _collapsedProfileLimit))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: OutlinedButton.icon(
              onPressed: onToggleShowAllProfiles,
              icon: Icon(
                showAllProfiles ? Icons.expand_less : Icons.expand_more,
              ),
              label: Text(
                showAllProfiles
                    ? strings.collapseProfiles
                    : strings.showAllProfiles(hiddenCount),
              ),
            ),
          ),
      ],
    );
  }

  List<VpnProfile> _filteredProfiles() {
    return profiles
        .where((profile) => _profileMatchesFilter(profile, selectedFilter))
        .toList();
  }

  List<VpnProfile> _visibleProfiles(List<VpnProfile> profiles) {
    if (showAllProfiles || profiles.length <= _collapsedProfileLimit) {
      return profiles;
    }

    final selected = <VpnProfile>[];
    final others = <VpnProfile>[];
    for (final profile in profiles) {
      if (profile.id == selectedId) {
        selected.add(profile);
      } else {
        others.add(profile);
      }
    }

    return [
      ...selected,
      ...others.take(_collapsedProfileLimit - selected.length),
    ];
  }
}

class _ProfileFilterBar extends StatelessWidget {
  const _ProfileFilterBar({
    required this.strings,
    required this.profiles,
    required this.selectedFilter,
    required this.onChanged,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final _ProfileFilter selectedFilter;
  final ValueChanged<_ProfileFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _ProfileFilter.values
            .map(
              (filter) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ChoiceChip(
                  label: Text(
                    _profileFilterLabel(
                      filter,
                      strings,
                      _profileFilterCount(filter),
                    ),
                  ),
                  selected: selectedFilter == filter,
                  showCheckmark: false,
                  onSelected: (_) => onChanged(filter),
                  selectedColor: _gold,
                  backgroundColor: _surface,
                  side: BorderSide(
                    color: selectedFilter == filter
                        ? _goldSoft
                        : _gold.withValues(alpha: 0.24),
                  ),
                  labelStyle: TextStyle(
                    color: selectedFilter == filter ? _ink : _goldSoft,
                    fontWeight: FontWeight.w700,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  int _profileFilterCount(_ProfileFilter filter) {
    return profiles
        .where((profile) => _profileMatchesFilter(profile, filter))
        .length;
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.selected,
    required this.latency,
    required this.checkingLatency,
    required this.onTap,
    required this.onRefreshLatency,
    required this.onDelete,
    required this.strings,
    required this.kindLabel,
  });

  final VpnProfile profile;
  final bool selected;
  final _ServerLatencyResult? latency;
  final bool checkingLatency;
  final VoidCallback onTap;
  final VoidCallback onRefreshLatency;
  final VoidCallback onDelete;
  final _Strings strings;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
    final pingLabel = latency == null
        ? (checkingLatency ? strings.pingChecking : strings.pingNotChecked)
        : latency!.label(strings);
    final pingColor = latency == null
        ? _mutedGold
        : latency!.ok
        ? _goldSoft
        : Colors.redAccent.shade100;
    final expiryLabel = _formatProfileExpiry(profile.expiresAt, strings);

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
                  if (expiryLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        expiryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB8D3EF),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: strings.pingRefresh,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: checkingLatency ? null : onRefreshLatency,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 70),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _surfaceMetric.withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected
                                ? _gold.withValues(alpha: 0.55)
                                : Colors.white10,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          child: Text(
                            pingLabel,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: pingColor,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox.square(
                  dimension: 32,
                  child: IconButton(
                    tooltip: strings.delete,
                    padding: EdgeInsets.zero,
                    onPressed: onDelete,
                    iconSize: 18,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

bool _profileMatchesFilter(VpnProfile profile, _ProfileFilter filter) {
  return switch (filter) {
    _ProfileFilter.all => true,
    _ProfileFilter.vless =>
      profile.kind == VpnProfileKind.vlessReality ||
          profile.kind == VpnProfileKind.vlessTls,
    _ProfileFilter.naive => profile.kind == VpnProfileKind.naive,
    _ProfileFilter.hysteria =>
      profile.kind == VpnProfileKind.hysteria ||
          profile.kind == VpnProfileKind.hysteria2,
  };
}

String _profileFilterLabel(_ProfileFilter filter, _Strings strings, int count) {
  final label = switch (filter) {
    _ProfileFilter.all => _isRu(strings) ? 'Все' : 'All',
    _ProfileFilter.vless => 'VLESS',
    _ProfileFilter.naive => 'Naive',
    _ProfileFilter.hysteria => 'Hysteria',
  };
  return '$label $count';
}

String _profileFilterEmptyLabel(_ProfileFilter filter, _Strings strings) {
  final label = _profileFilterLabel(filter, strings, 0).replaceFirst(' 0', '');
  return _isRu(strings) ? 'Нет профилей $label.' : 'No $label profiles.';
}

String _formatSessionDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String? _formatProfileExpiry(DateTime? expiresAt, _Strings strings) {
  if (expiresAt == null) {
    return null;
  }
  final date = DateTime(expiresAt.year, expiresAt.month, expiresAt.day);
  final today = DateTime.now();
  final now = DateTime(today.year, today.month, today.day);
  final daysLeft = date.difference(now).inDays;
  final formattedDate =
      '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';

  if (_isRu(strings)) {
    if (daysLeft < 0) {
      return 'Подписка истекла $formattedDate';
    }
    if (daysLeft == 0) {
      return 'Подписка до $formattedDate (истекает сегодня)';
    }
    if (daysLeft == 1) {
      return 'Подписка до $formattedDate (1 день)';
    }
    return 'Подписка до $formattedDate (осталось $daysLeft дн.)';
  }

  if (daysLeft < 0) {
    return 'Subscription expired on $formattedDate';
  }
  if (daysLeft == 0) {
    return 'Subscription until $formattedDate (expires today)';
  }
  if (daysLeft == 1) {
    return 'Subscription until $formattedDate (1 day)';
  }
  return 'Subscription until $formattedDate ($daysLeft days left)';
}

bool _isRu(_Strings strings) {
  return strings == _Strings.ru;
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({required this.strings, this.message});

  final _Strings strings;
  final String? message;

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
      child: Text(message ?? strings.emptyProfiles),
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
    required this.codexDirect,
    required this.codexDirectSupported,
    required this.busy,
    required this.checkingUpdate,
    required this.installingUpdate,
    required this.codexDiagnosticsBusy,
    required this.excludedProcessCount,
    required this.vpnOnlyProcessCount,
    required this.updateInfo,
    required this.onAutoStartChanged,
    required this.onAutoConnectChanged,
    required this.onCodexDirectChanged,
    required this.onEditSplitTunnel,
    required this.onEditVpnOnly,
    required this.onCodexDiagnostics,
    required this.onCheckUpdate,
    required this.onOpenReleases,
    required this.onRepairConnection,
  });

  final _Strings strings;
  final bool autoStart;
  final bool autoConnect;
  final bool codexDirect;
  final bool codexDirectSupported;
  final bool busy;
  final bool checkingUpdate;
  final bool installingUpdate;
  final bool codexDiagnosticsBusy;
  final int excludedProcessCount;
  final int vpnOnlyProcessCount;
  final WindowsUpdateInfo? updateInfo;
  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onAutoConnectChanged;
  final ValueChanged<bool> onCodexDirectChanged;
  final VoidCallback onEditSplitTunnel;
  final VoidCallback onEditVpnOnly;
  final VoidCallback onCodexDiagnostics;
  final VoidCallback onCheckUpdate;
  final VoidCallback onOpenReleases;
  final VoidCallback onRepairConnection;

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
                const Icon(
                  Icons.desktop_windows_outlined,
                  color: _goldSoft,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.windowsTools,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SettingsSwitchRow(
              icon: Icons.rocket_launch_outlined,
              value: autoStart,
              onChanged: busy ? null : onAutoStartChanged,
              title: Text(strings.autoStart),
              subtitle: Text(strings.autoStartHint),
            ),
            const SizedBox(height: 8),
            _SettingsSwitchRow(
              icon: Icons.shield_outlined,
              value: autoConnect,
              onChanged: onAutoConnectChanged,
              title: Text(strings.autoConnect),
              subtitle: Text(strings.autoConnectHint),
            ),
            const SizedBox(height: 8),
            _SettingsSwitchRow(
              icon: Icons.code_outlined,
              value: codexDirect,
              onChanged: codexDirectSupported ? onCodexDirectChanged : null,
              title: Text(strings.codexDirect),
              subtitle: Text(
                codexDirectSupported
                    ? strings.codexDirectHint
                    : strings.codexDirectTunOnly,
              ),
            ),
            const SizedBox(height: 12),
            _ActionGrid(
              children: [
                _ActionTile(
                  onPressed: onEditSplitTunnel,
                  icon: const Icon(Icons.call_split_outlined),
                  label: Text(strings.splitTunnelButton(excludedProcessCount)),
                ),
                _ActionTile(
                  onPressed: onEditVpnOnly,
                  icon: const Icon(Icons.vpn_lock_outlined),
                  label: Text(strings.vpnOnlyButton(vpnOnlyProcessCount)),
                ),
                _ActionTile(
                  onPressed: busy ? null : onRepairConnection,
                  icon: const Icon(Icons.healing_outlined),
                  label: Text(strings.repairConnection),
                ),
                _ActionTile(
                  onPressed: codexDiagnosticsBusy ? null : onCodexDiagnostics,
                  icon: codexDiagnosticsBusy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bug_report_outlined),
                  label: Text(strings.codexDiagnostics),
                ),
                _ActionTile(
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
                _ActionTile(
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
                      ? const Color(0xFF7DEBFF)
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

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _ink.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            Icon(icon, color: _mutedGold, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: DefaultTextStyle.merge(
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.titleSmall,
                      child: title,
                    ),
                    const SizedBox(height: 3),
                    DefaultTextStyle.merge(
                      style: const TextStyle(
                        color: _mutedGold,
                        fontSize: 12,
                        height: 1.25,
                      ),
                      child: subtitle,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final columns = constraints.maxWidth < 330 ? 1 : 2;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: 42,
      child: Material(
        color: enabled
            ? _surfaceMetric.withValues(alpha: 0.64)
            : _ink.withValues(alpha: 0.28),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: enabled
                ? _gold.withValues(alpha: 0.34)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: IconTheme.merge(
              data: IconThemeData(
                size: 18,
                color: enabled ? _goldSoft : _mutedGold.withValues(alpha: 0.5),
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: enabled
                      ? _goldSoft
                      : _mutedGold.withValues(alpha: 0.55),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: Row(
                  children: [
                    icon,
                    const SizedBox(width: 8),
                    Expanded(child: label),
                  ],
                ),
              ),
            ),
          ),
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
                const Icon(Icons.link_outlined, color: _goldSoft, size: 22),
                const SizedBox(width: 10),
                Text(
                  strings.contact,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _ActionGrid(
              children: [
                _ActionTile(
                  onPressed: onSupport,
                  icon: const Icon(Icons.support_agent),
                  label: Text(strings.support),
                ),
                _ActionTile(
                  onPressed: onTelegram,
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Telegram'),
                ),
                _ActionTile(
                  onPressed: onVk,
                  icon: const Icon(Icons.groups_outlined),
                  label: const Text('VK'),
                ),
                _ActionTile(
                  onPressed: onDonate,
                  icon: const Icon(Icons.volunteer_activism_outlined),
                  label: Text(strings.donate),
                ),
                _ActionTile(
                  onPressed: onDeveloper,
                  icon: const Icon(Icons.mail_outline),
                  label: Text(strings.developer),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FaqPanel extends StatelessWidget {
  const _FaqPanel({required this.strings});

  final _Strings strings;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.help_outline, color: _goldSoft),
        title: Text(strings.faq),
        children: [
          for (var i = 0; i < strings.faqItems.length; i++) ...[
            Padding(
              padding: EdgeInsets.only(
                top: i == 0 ? 2 : 10,
                bottom: i == strings.faqItems.length - 1 ? 0 : 10,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.faqItems[i].question,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    strings.faqItems[i].answer,
                    style: const TextStyle(color: _mutedGold, height: 1.35),
                  ),
                ],
              ),
            ),
            if (i != strings.faqItems.length - 1)
              Divider(color: _gold.withValues(alpha: 0.12), height: 1),
          ],
        ],
      ),
    );
  }
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({required this.strings, required this.logs});

  final _Strings strings;
  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.terminal_outlined, color: _goldSoft),
        title: Text(strings.logs),
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _gold.withValues(alpha: 0.16)),
            ),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  logs.isEmpty ? strings.noLogs : logs.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
    required this.refreshSubscriptions,
    required this.refreshingSubscriptions,
    required this.noSubscriptionSources,
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
    required this.codexDirect,
    required this.codexDirectHint,
    required this.codexDirectTunOnly,
    required this.codexDiagnostics,
    required this.codexDiagnosticsDone,
    required this.splitTunnelTitle,
    required this.splitTunnelDescription,
    required this.splitTunnelHint,
    required this.splitTunnelPickExeTitle,
    required this.vpnOnlyTitle,
    required this.vpnOnlyDescription,
    required this.vpnOnlyHint,
    required this.vpnOnlyPickExeTitle,
    required this.pickExeButton,
    required this.settingsSaved,
    required this.reconnectToApply,
    required this.updates,
    required this.checkingUpdates,
    required this.updateNow,
    required this.updateBannerBody,
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
  final String refreshSubscriptions;
  final String refreshingSubscriptions;
  final String noSubscriptionSources;
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
  final String codexDirect;
  final String codexDirectHint;
  final String codexDirectTunOnly;
  final String codexDiagnostics;
  final String codexDiagnosticsDone;
  final String splitTunnelTitle;
  final String splitTunnelDescription;
  final String splitTunnelHint;
  final String splitTunnelPickExeTitle;
  final String vpnOnlyTitle;
  final String vpnOnlyDescription;
  final String vpnOnlyHint;
  final String vpnOnlyPickExeTitle;
  final String pickExeButton;
  final String settingsSaved;
  final String reconnectToApply;
  final String updates;
  final String checkingUpdates;
  final String updateNow;
  final String updateBannerBody;
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

  String subscriptionsUpdated(
    int profileCount,
    int sourceCount,
  ) => switch (this) {
    _Strings.en =>
      'Subscriptions updated: $profileCount profiles from $sourceCount sources',
    _ =>
      'Подписки обновлены: $profileCount профилей из $sourceCount источников',
  };

  String subscriptionsUpdatedPartial(int profileCount, int errorCount) =>
      switch (this) {
        _Strings.en =>
          'Updated $profileCount profiles. Subscription errors: $errorCount',
        _ => 'Обновлено профилей: $profileCount. Ошибок подписок: $errorCount',
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

  String showAllProfiles(int hiddenCount) => switch (this) {
    _Strings.en => 'Show all profiles (+$hiddenCount)',
    _ => 'Показать все профили (+$hiddenCount)',
  };

  String get collapseProfiles => switch (this) {
    _Strings.en => 'Collapse profiles',
    _ => 'Свернуть профили',
  };

  String vpnOnlyButton(int count) => switch (this) {
    _Strings.en when count == 0 => 'Always VPN',
    _Strings.en => 'Always VPN: $count',
    _ when count == 0 => 'Всегда через VPN',
    _ => 'VPN всегда: $count',
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

  String updateBannerTitle(String version) => switch (this) {
    _Strings.en when version.isNotEmpty => 'New version available: $version',
    _Strings.en => 'New version available',
    _ when version.isNotEmpty => 'Доступна новая версия: $version',
    _ => 'Доступна новая версия',
  };

  String updateMessage(WindowsUpdateInfo info) => switch (this) {
    _Strings.en when info.available && info.latestVersion != null =>
      'Update available: ${info.latestVersion}',
    _Strings.en
        when info.latestIsOlder &&
            info.latestVersion != null &&
            info.currentVersion != null =>
      'GitHub latest is ${info.latestVersion}, installed build is ${info.currentVersion}. Publish a newer Windows release.',
    _Strings.en => info.message,
    _ when info.available && info.latestVersion != null =>
      'Доступно обновление: ${info.latestVersion}',
    _
        when info.latestIsOlder &&
            info.latestVersion != null &&
            info.currentVersion != null =>
      'На GitHub пока ${info.latestVersion}, установлена ${info.currentVersion}. Опубликуй более новый Windows-релиз.',
    _ when info.message.contains('not published') =>
      'Релизы GitHub пока не опубликованы.',
    _ when info.message.contains('up to date') =>
      'Установлена актуальная версия.',
    _ when info.message.contains('failed') =>
      'Не удалось проверить обновления.',
    _ => info.message,
  };

  String get reconnecting => switch (this) {
    _Strings.en => 'Reconnecting...',
    _ => 'Переподключение...',
  };

  String get adminRequiredStatus => switch (this) {
    _Strings.en => 'Administrator rights required',
    _ => 'Требуются права администратора',
  };

  String get noProfileStatus => switch (this) {
    _Strings.en => 'No profile',
    _ => 'Нет профиля',
  };

  String get noInternetStatus => switch (this) {
    _Strings.en => 'No internet',
    _ => 'Нет интернета',
  };

  String get errorStatus => switch (this) {
    _Strings.en => 'Error',
    _ => 'Ошибка',
  };

  String get adminRightsRequiredTitle => switch (this) {
    _Strings.en => 'Administrator rights required',
    _ => 'Для подключения требуются права администратора',
  };

  String get adminRightsRequired => switch (this) {
    _Strings.en => 'Administrator rights are required to connect.',
    _ => 'Для подключения требуются права администратора.',
  };

  String get adminRightsRequiredBody => switch (this) {
    _Strings.en =>
      'Yurich Connect uses Windows TUN/Wintun mode. Restart the app as administrator and try connecting again.',
    _ =>
      'Yurich Connect использует режим Windows TUN/Wintun. Перезапустите приложение от имени администратора и подключитесь снова.',
  };

  String get restartAsAdmin => switch (this) {
    _Strings.en => 'Restart as administrator',
    _ => 'Перезапустить от имени администратора',
  };

  String get adminRestartDeclined => switch (this) {
    _Strings.en => 'Windows UAC did not allow administrator restart.',
    _ => 'Windows UAC не разрешил перезапуск от имени администратора.',
  };

  String get repairConnection => switch (this) {
    _Strings.en => 'Repair connection',
    _ => 'Починить подключение',
  };

  String get repairingConnection => switch (this) {
    _Strings.en => 'Repairing connection...',
    _ => 'Восстанавливаю подключение...',
  };

  String get repairOk => switch (this) {
    _Strings.en => 'Connection repaired',
    _ => 'Подключение восстановлено',
  };

  String get repairFailed => switch (this) {
    _Strings.en => 'Could not repair automatically. Send a report.',
    _ => 'Не удалось исправить автоматически, отправьте отчёт.',
  };

  String get connectionErrorTitle => switch (this) {
    _Strings.en => 'Could not connect',
    _ => 'Не удалось подключиться',
  };

  String get connectionErrorBody => switch (this) {
    _Strings.en =>
      'The profile is not responding or the server is temporarily unavailable.',
    _ => 'Профиль не отвечает или сервер временно недоступен.',
  };

  String get tryAgain => switch (this) {
    _Strings.en => 'Try again',
    _ => 'Попробовать ещё раз',
  };

  String get sendReport => switch (this) {
    _Strings.en => 'Send report',
    _ => 'Отправить отчёт',
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
    refreshSubscriptions: 'Обновить подписки',
    refreshingSubscriptions: 'Обновляю подписки...',
    noSubscriptionSources:
        'Сначала добавь подписку ссылкой. Я пока не вижу сохранённого URL.',
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
    codexDirect: 'Codex напрямую',
    codexDirectHint:
        'ChatGPT/OpenAI WebSocket и Codex exe идут напрямую, без перезапуска туннеля из-за health-check.',
    codexDirectTunOnly:
        'Исключения Codex доступны только в Windows TUN-режиме для обычных профилей.',
    codexDiagnostics: 'Диагностика Codex',
    codexDiagnosticsDone: 'Диагностика Codex записана в логи',
    splitTunnelTitle: 'Исключения приложений',
    splitTunnelDescription:
        'Укажи exe-файлы, которые должны идти напрямую, минуя VPN. По одному в строке.',
    splitTunnelHint: 'chrome.exe\nsteam.exe\nqbittorrent.exe',
    splitTunnelPickExeTitle: 'Выбери приложения для исключений',
    vpnOnlyTitle: 'Постоянный VPN для приложений',
    vpnOnlyDescription:
        'Укажи exe-файлы, которые всегда должны идти через VPN. Локальные адреса останутся напрямую, чтобы не ломать работу приложения.',
    vpnOnlyHint: 'Codex.exe\ncodex.exe\nChatGPT.exe',
    vpnOnlyPickExeTitle: 'Выбери приложения для постоянного VPN',
    pickExeButton: 'Выбрать exe',
    settingsSaved: 'Настройки сохранены',
    reconnectToApply: 'Настройки сохранены. Переподключи VPN, чтобы применить.',
    updates: 'Обновления',
    checkingUpdates: 'Проверяю...',
    updateNow: 'Обновить',
    updateBannerBody:
        'Пора обновить Yurich Connect. Установщик скачается и запустится от администратора.',
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
    refreshSubscriptions: 'Refresh subscriptions',
    refreshingSubscriptions: 'Refreshing subscriptions...',
    noSubscriptionSources:
        'Add a subscription URL first. No saved subscription source was found.',
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
    codexDirect: 'Codex direct',
    codexDirectHint:
        'ChatGPT/OpenAI WebSocket and Codex executables go direct, without tunnel restarts from health checks.',
    codexDirectTunOnly:
        'Codex exclusions are available only in Windows TUN mode for generated profiles.',
    codexDiagnostics: 'Codex diagnostics',
    codexDiagnosticsDone: 'Codex diagnostics written to logs',
    splitTunnelTitle: 'App exclusions',
    splitTunnelDescription:
        'Enter exe files that should go directly and bypass the VPN. One per line.',
    splitTunnelHint: 'chrome.exe\nsteam.exe\nqbittorrent.exe',
    splitTunnelPickExeTitle: 'Choose apps to exclude',
    vpnOnlyTitle: 'Always-on VPN for apps',
    vpnOnlyDescription:
        'Enter exe files that should always use the VPN. Local addresses stay direct so the app can keep its local IPC working.',
    vpnOnlyHint: 'Codex.exe\ncodex.exe\nChatGPT.exe',
    vpnOnlyPickExeTitle: 'Choose always-on VPN apps',
    pickExeButton: 'Choose exe',
    settingsSaved: 'Settings saved',
    reconnectToApply: 'Settings saved. Reconnect the VPN to apply them.',
    updates: 'Updates',
    checkingUpdates: 'Checking...',
    updateNow: 'Update',
    updateBannerBody:
        'Time to update Yurich Connect. The installer will download and run as administrator.',
    openRelease: 'Open',
    save: 'Save',
    cancel: 'Cancel',
    trayShow: 'Open Yurich Connect',
    trayHide: 'Hide to tray',
    trayQuit: 'Quit',
    notificationDescription: 'VPN connection is active',
  );
}
