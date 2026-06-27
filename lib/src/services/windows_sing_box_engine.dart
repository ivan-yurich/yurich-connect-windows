import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../branding.dart';
import '../models/vpn_profile.dart';
import 'runtime_log_classifier.dart';
import 'secret_redactor.dart';
import 'sing_box_config_builder.dart';
import 'vpn_engine.dart';

class WindowsSingBoxEngine implements VpnEngine {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final _trafficController = StreamController<Map<String, dynamic>>.broadcast();
  final _logController = StreamController<Map<String, dynamic>>.broadcast();
  final _logs = <String>[];
  final Map<String, Future<void>> _logWriteChains = {};

  Process? _process;
  Process? _naiveProcess;
  int? _processPid;
  int? _naiveProcessPid;
  String _status = YurichConnectStatus.stopped;
  String _config = '{}';
  String? _naiveProxyConfig;
  VpnCoreBackend _coreBackend = VpnCoreBackend.singBox;
  String _notificationTitle = YurichBranding.appName;
  String _notificationDescription = 'VPN connection is active';
  Timer? _trafficTimer;
  WebSocket? _trafficSocket;
  bool _trafficSocketConnecting = false;
  bool _reportedAdminIssue = false;
  bool _transitioning = false;
  bool _lastConfigNeedsTun = false;
  int _runtimeFailureCount = 0;
  int _suppressedDiagnosticLogCount = 0;
  DateTime? _lastRuntimeFailureAt;
  String? _lastRuntimeFailureReason;
  bool _lastStartupFailureIsFatal = false;
  bool _lastStartupFailureSuggestsDnsFallback = false;
  String? _lastStartupFailureMessage;
  int _sessionTotalBytes = 0;
  final Map<String, bool> _configCheckCache = {};
  static const _visualRuntimeDlls = [
    'MSVCP140.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
  ];
  static const _maxLogFileBytes = 8 * 1024 * 1024;
  static const _maxLogBackups = 4;

  @override
  SingBoxConfigTarget get configTarget => SingBoxConfigTarget.windows;

  bool get lastStartupFailureIsFatal => _lastStartupFailureIsFatal;

  bool get lastStartupFailureSuggestsDnsFallback =>
      _lastStartupFailureSuggestsDnsFallback;

  String? get lastStartupFailureMessage => _lastStartupFailureMessage;

  @override
  Stream<Map<String, dynamic>> get onStatusChanged => _statusController.stream;

  @override
  Stream<Map<String, dynamic>> get onTrafficUpdate => _trafficController.stream;

  @override
  Stream<Map<String, dynamic>> get onLogMessage => _logController.stream;

  @override
  Future<bool> setNotificationTitle(String title) async {
    _notificationTitle = title;
    return true;
  }

  @override
  Future<String> getNotificationTitle() async => _notificationTitle;

  @override
  Future<bool> setNotificationDescription(String description) async {
    _notificationDescription = description;
    return true;
  }

  @override
  Future<String> getNotificationDescription() async => _notificationDescription;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<String> getVPNStatus() async {
    if (_process == null &&
        (_status == YurichConnectStatus.started ||
            _status == YurichConnectStatus.starting ||
            _status == YurichConnectStatus.stopping ||
            _status == YurichConnectStatus.reconnecting)) {
      _setStatus(YurichConnectStatus.stopped);
    }
    return _status;
  }

  @override
  Future<bool> saveConfig(
    String config, {
    String? naiveProxyConfig,
    VpnCoreBackend coreBackend = VpnCoreBackend.singBox,
  }) async {
    _config = config;
    _naiveProxyConfig = naiveProxyConfig;
    _coreBackend = coreBackend == VpnCoreBackend.auto
        ? VpnCoreBackend.singBox
        : coreBackend;
    _lastConfigNeedsTun = _usesXrayCore ? false : _configNeedsTun(config);
    return config.trim().isNotEmpty;
  }

  @override
  Future<String> getConfig() async => _config;

  bool _configNeedsTun(String config) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return false;
      }
      final inbounds = decoded['inbounds'];
      if (inbounds is! List) {
        return false;
      }
      return inbounds.whereType<Map>().any(
        (inbound) => '${inbound['type']}'.toLowerCase() == 'tun',
      );
    } on Object {
      return false;
    }
  }

  bool get _usesXrayCore => _coreBackend == VpnCoreBackend.xray;

  String get _coreProcessName => _usesXrayCore ? 'xray' : 'sing-box';

  String get _coreExeName => _usesXrayCore ? 'xray.exe' : 'sing-box.exe';

  String get _coreLogFileName => _usesXrayCore ? 'xray.log' : 'sing-box.log';

  @override
  Future<bool> startVPN() async {
    final startStopwatch = Stopwatch()..start();
    if (_process != null) {
      _appendLog(
        'Start skipped: $_coreProcessName is already tracked with PID $_processPid.',
      );
      return true;
    }
    if (_transitioning) {
      _appendLog('Start skipped: VPN transition is already in progress.');
      return false;
    }

    _transitioning = true;
    _setStatus(YurichConnectStatus.starting);
    _reportedAdminIssue = false;
    _clearStartupFailure();
    try {
      await _applyRuntimeBackoff();
      final runtimeDir = await _runtimeDir();
      final configDir = await _configDir();
      final staleStopwatch = Stopwatch()..start();
      await _stopStaleRuntimeProcesses(runtimeDir);
      _appendLog(
        'Startup stale process cleanup finished in ${staleStopwatch.elapsedMilliseconds}ms.',
      );

      final configFile = File(
        '${configDir.path}\\${_usesXrayCore ? 'xray.json' : 'config.json'}',
      );
      final effectiveConfig = _usesXrayCore
          ? _config
          : await _prepareConfigWithGeoIpFallback(
              runtimeDir,
              configDir,
              _config,
            );
      final needsTun = !_usesXrayCore && _configNeedsTun(effectiveConfig);
      _lastConfigNeedsTun = needsTun;
      await configFile.writeAsString(effectiveConfig, encoding: utf8);

      final needsNaiveProxy = !_usesXrayCore && _naiveProxyConfig != null;
      final preflightOk = await _runPreflight(
        runtimeDir,
        configFile,
        needsNaiveProxy: needsNaiveProxy,
        needsTun: needsTun,
        coreBackend: _coreBackend,
      );
      if (!preflightOk) {
        if (_status != YurichConnectStatus.adminRequired) {
          _setStatus(YurichConnectStatus.error);
        }
        return false;
      }

      if (needsNaiveProxy) {
        final started = await _startNaiveProxy(runtimeDir, configDir);
        if (!started) {
          _setStatus(YurichConnectStatus.stopped);
          return false;
        }
      }

      final exe = File('${runtimeDir.path}\\$_coreExeName');
      if (!await exe.exists()) {
        _appendLog('$_coreExeName не найден в ${runtimeDir.path}');
        _setStatus(YurichConnectStatus.stopped);
        return false;
      }

      if (!_usesXrayCore && _shouldRunStartupCanary(effectiveConfig)) {
        var canary = await _runStartupCanary(exe, configFile, runtimeDir);
        if (!canary.ok && canary.suggestsDnsFallback) {
          final fallbackConfig = _safeDnsFallbackConfig(effectiveConfig);
          if (fallbackConfig != null) {
            _appendLog(
              'Safe DNS fallback applied before start: strict bootstrap DNS disabled after canary failure.',
            );
            await configFile.writeAsString(fallbackConfig, encoding: utf8);
            _lastConfigNeedsTun = _configNeedsTun(fallbackConfig);
            _configCheckCache.clear();
            final fallbackPreflightOk = await _runPreflight(
              runtimeDir,
              configFile,
              needsNaiveProxy: needsNaiveProxy,
              needsTun: _lastConfigNeedsTun,
              coreBackend: _coreBackend,
            );
            if (!fallbackPreflightOk) {
              if (_status != YurichConnectStatus.adminRequired) {
                _setStatus(YurichConnectStatus.error);
              }
              return false;
            }
            _emitUserAlert(
              'DNS only through VPN временно отключён: строгий DNS мешал старту Yurich Core. VPN запускается в безопасном DNS-режиме.',
              code: 'dnsFallbackApplied',
            );
            canary = await _runStartupCanary(exe, configFile, runtimeDir);
          }
        }

        if (!canary.ok) {
          _setStartupFailure(
            canary.message ?? 'sing-box canary failed before start.',
            fatal: canary.fatal,
            suggestsDnsFallback: canary.suggestsDnsFallback,
          );
          _emitUserAlert(
            _lastStartupFailureMessage ??
                'Yurich Core не стартовал. Открой логи ниже.',
            code: canary.fatal ? 'startupFatal' : null,
          );
          await _stopNaiveProxy();
          if (_status != YurichConnectStatus.adminRequired) {
            _setStatus(YurichConnectStatus.error);
          }
          return false;
        }
      }

      _appendLog('Starting $_coreProcessName ${exe.path}');
      _appendLog(
        needsTun
            ? 'Advanced TUN Mode preflight passed.'
            : _usesXrayCore
            ? 'Stable Proxy Mode preflight passed for Xray-core backend.'
            : 'Stable Proxy Mode preflight passed.',
      );
      final process = await Process.start(
        exe.path,
        _usesXrayCore
            ? ['-c', configFile.path]
            : ['run', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        runInShell: false,
      );
      _process = process;
      _processPid = process.pid;
      _appendLog('$_coreProcessName PID ${process.pid}');
      _pipeProcess(process);
      _startTrafficTicker();

      unawaited(
        process.exitCode.then((code) async {
          _appendLog('$_coreProcessName exited with code $code');
          if (_status != YurichConnectStatus.stopping) {
            _recordRuntimeFailure(_coreProcessName, code);
          }
          if (_process == process) {
            _process = null;
            _processPid = null;
          }
          await _stopNaiveProxy();
          _stopTrafficTicker();
          if (_status != YurichConnectStatus.stopping) {
            _setStatus(YurichConnectStatus.stopped);
          }
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (_process == process) {
        _resetRuntimeBackoff();
        _setStatus(YurichConnectStatus.started);
        _appendLog(
          'Windows VPN start completed in ${startStopwatch.elapsedMilliseconds}ms.',
        );
        return true;
      }

      await _stopNaiveProxy();
      if (_status != YurichConnectStatus.adminRequired) {
        _setStatus(YurichConnectStatus.error);
      }
      return false;
    } on Object catch (e) {
      _appendLog('Не удалось запустить $_coreProcessName: $e');
      await _stopNaiveProxy();
      if (_status != YurichConnectStatus.adminRequired) {
        _setStatus(YurichConnectStatus.error);
      }
      return false;
    } finally {
      _transitioning = false;
      if (_status != YurichConnectStatus.started) {
        _appendLog(
          'Windows VPN start finished with status $_status in ${startStopwatch.elapsedMilliseconds}ms.',
        );
      }
    }
  }

  Future<bool> prepareConfigForStart() async {
    final stopwatch = Stopwatch()..start();
    try {
      final runtimeDir = await _runtimeDir();
      final configDir = await _configDir();
      final configFile = File(
        '${configDir.path}\\${_usesXrayCore ? 'xray.json' : 'config.json'}',
      );
      final effectiveConfig = _usesXrayCore
          ? _config
          : await _prepareConfigWithGeoIpFallback(
              runtimeDir,
              configDir,
              _config,
            );
      _lastConfigNeedsTun = !_usesXrayCore && _configNeedsTun(effectiveConfig);
      await configFile.writeAsString(effectiveConfig, encoding: utf8);

      final exe = File('${runtimeDir.path}\\$_coreExeName');
      if (!await exe.exists()) {
        _appendLog('Warm config check failed: $_coreExeName не найден.');
        return false;
      }

      final ok = _usesXrayCore
          ? await _checkXrayConfig(exe, configFile, runtimeDir)
          : await _checkConfig(exe, configFile, runtimeDir);
      _appendLog(
        'Warm config check ${ok ? 'passed' : 'failed'} in ${stopwatch.elapsedMilliseconds}ms.',
      );
      return ok;
    } on Object catch (e) {
      _appendLog(
        'Warm config check failed in ${stopwatch.elapsedMilliseconds}ms: $e',
      );
      return false;
    }
  }

  @override
  Future<bool> stopVPN() {
    return _stopVPN(
      gracefulTimeout: const Duration(seconds: 5),
      killTimeout: const Duration(seconds: 3),
      stopStaleWhenUntracked: true,
    );
  }

  Future<bool> stopVPNFast() {
    return _stopVPN(
      gracefulTimeout: const Duration(milliseconds: 1200),
      killTimeout: const Duration(milliseconds: 800),
      stopStaleWhenUntracked: false,
    );
  }

  Future<bool> _stopVPN({
    required Duration gracefulTimeout,
    required Duration killTimeout,
    required bool stopStaleWhenUntracked,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (_transitioning && _status == YurichConnectStatus.starting) {
      _appendLog('Stop requested while VPN is starting; waiting for cleanup.');
    }
    final process = _process;
    if (process == null) {
      if (stopStaleWhenUntracked) {
        try {
          await _stopStaleRuntimeProcesses(await _runtimeDir());
        } on Object {
          // Best-effort cleanup for untracked processes after app restarts.
        }
      }
      await _stopNaiveProxy(
        gracefulTimeout: gracefulTimeout,
        killTimeout: killTimeout,
      );
      _setStatus(YurichConnectStatus.stopped);
      _appendLog(
        'Windows VPN stop completed without tracked process in ${stopwatch.elapsedMilliseconds}ms.',
      );
      return true;
    }

    _setStatus(YurichConnectStatus.stopping);
    _appendLog('Stopping $_coreProcessName...');
    process.kill();
    try {
      await process.exitCode.timeout(gracefulTimeout);
    } on TimeoutException {
      _appendLog(
        '$_coreProcessName did not exit in time; killing PID $_processPid.',
      );
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(killTimeout);
      } on TimeoutException {
        _appendLog('$_coreProcessName kill timeout for PID $_processPid.');
      }
    }
    _process = null;
    _processPid = null;
    await _stopNaiveProxy(
      gracefulTimeout: gracefulTimeout,
      killTimeout: killTimeout,
    );
    _stopTrafficTicker();
    _setStatus(YurichConnectStatus.stopped);
    _appendLog(
      'Windows VPN stop completed in ${stopwatch.elapsedMilliseconds}ms.',
    );
    return true;
  }

  @override
  Future<bool> repairConnection() async {
    _appendLog('Connection repair started.');
    var needsReboot = false;
    try {
      await stopVPN();

      final runtimeDir = await _runtimeDir();
      final configDir = await _configDir();
      await _stopStaleRuntimeProcesses(runtimeDir);
      await _cleanupTemporaryConfigs(configDir);
      await _flushDnsCache();

      if (_lastConfigNeedsTun) {
        final wintun = File('${runtimeDir.path}\\wintun.dll');
        if (!await wintun.exists()) {
          needsReboot = true;
          _appendLog(
            'Repair warning: wintun.dll is missing for Advanced TUN Mode.',
          );
        } else {
          _appendLog('Repair check: wintun.dll found.');
        }
      } else {
        _appendLog('Repair check: Stable Proxy Mode does not require Wintun.');
      }

      _setStatus(YurichConnectStatus.stopped);
      _appendLog(
        needsReboot
            ? 'Connection repair finished: Windows reboot or reinstall may be required.'
            : 'Connection repair finished successfully.',
      );
      if (!_statusController.isClosed) {
        _statusController.add({
          'type': 'repair',
          'result': needsReboot ? 'reboot' : 'ok',
          'message': needsReboot
              ? 'Нужна перезагрузка Windows или переустановка приложения.'
              : 'Подключение восстановлено.',
        });
      }
      return !needsReboot;
    } on Object catch (e) {
      _appendLog('Connection repair failed: $e');
      _setStatus(YurichConnectStatus.error);
      if (!_statusController.isClosed) {
        _statusController.add({
          'type': 'repair',
          'result': 'failed',
          'message':
              'Не удалось исправить автоматически, отправьте отчёт разработчику.',
        });
      }
      return false;
    }
  }

  Future<bool> softRecoverConnection() async {
    _appendLog('Soft recovery started: no core restart.');
    if (_process == null) {
      _appendLog('Soft recovery skipped: $_coreProcessName is not tracked.');
      return false;
    }

    await _flushDnsCache();
    if (!_usesXrayCore) {
      unawaited(_trafficSocket?.close());
      _trafficSocket = null;
      _trafficSocketConnecting = false;
      unawaited(_connectTrafficSocket());
    }

    final ports = <int>[
      SingBoxConfigBuilder.localMixedProxyPort,
      SingBoxConfigBuilder.localSocksProxyPort,
      if (!_usesXrayCore) SingBoxConfigBuilder.windowsClashApiPort,
    ];
    final checks = await Future.wait(
      ports.map((port) => _checkTcpPortOpen('127.0.0.1', port)),
    );
    final ok = checks.every((value) => value);
    _appendLog(
      'Soft recovery ${ok ? 'passed' : 'degraded'}: '
      'mixed=${checks[0]} socks=${checks[1]}'
      '${_usesXrayCore ? '' : ' clash=${checks[2]}'}.',
    );
    return ok;
  }

  Future<bool> _checkTcpPortOpen(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _applyRuntimeBackoff() async {
    final lastFailureAt = _lastRuntimeFailureAt;
    if (lastFailureAt == null || _runtimeFailureCount <= 0) {
      return;
    }

    final delay = _runtimeBackoffDelay(_runtimeFailureCount);
    final elapsed = DateTime.now().difference(lastFailureAt);
    final remaining = delay - elapsed;
    if (remaining <= Duration.zero) {
      return;
    }

    _appendLog(
      'Runtime backoff active for ${remaining.inMilliseconds}ms after '
      '${_lastRuntimeFailureReason ?? 'runtime failure'}.',
    );
    await Future<void>.delayed(remaining);
  }

  Duration _runtimeBackoffDelay(int failureCount) {
    if (failureCount <= 1) {
      return const Duration(seconds: 1);
    }
    if (failureCount == 2) {
      return const Duration(seconds: 3);
    }
    return const Duration(seconds: 10);
  }

  void _recordRuntimeFailure(String component, int exitCode) {
    if (exitCode == 0) {
      return;
    }
    _runtimeFailureCount = (_runtimeFailureCount + 1).clamp(1, 6).toInt();
    _lastRuntimeFailureAt = DateTime.now();
    _lastRuntimeFailureReason = '$component process_exit code=$exitCode';
    _appendLog(
      'Runtime failure recorded: $_lastRuntimeFailureReason; '
      'next start backoff=${_runtimeBackoffDelay(_runtimeFailureCount).inSeconds}s.',
    );
  }

  void _resetRuntimeBackoff() {
    if (_runtimeFailureCount == 0 &&
        _lastRuntimeFailureAt == null &&
        _lastRuntimeFailureReason == null) {
      return;
    }
    _runtimeFailureCount = 0;
    _lastRuntimeFailureAt = null;
    _lastRuntimeFailureReason = null;
    _appendLog('Runtime backoff cleared after successful start.');
  }

  void _clearStartupFailure() {
    _lastStartupFailureIsFatal = false;
    _lastStartupFailureSuggestsDnsFallback = false;
    _lastStartupFailureMessage = null;
  }

  void _setStartupFailure(
    String message, {
    required bool fatal,
    required bool suggestsDnsFallback,
  }) {
    _lastStartupFailureIsFatal = fatal;
    _lastStartupFailureSuggestsDnsFallback = suggestsDnsFallback;
    _lastStartupFailureMessage = _friendlyStartupFailure(message);
  }

  Future<void> _cleanupTemporaryConfigs(Directory configDir) async {
    final names = [
      'config.json',
      'xray.json',
      'naive.json',
      'geoip-ru.srs.download',
    ];
    for (final name in names) {
      final file = File('${configDir.path}\\$name');
      try {
        if (await file.exists()) {
          await file.delete();
          _appendLog('Repair removed temporary file: $name');
        }
      } on Object catch (e) {
        _appendLog('Repair could not remove $name: $e');
      }
    }
  }

  Future<void> _flushDnsCache() async {
    try {
      final result = await Process.run('ipconfig.exe', [
        '/flushdns',
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode == 0) {
        _appendLog('Repair flushed Windows DNS cache.');
      } else {
        final output = '${result.stdout}${result.stderr}'.trim();
        _appendLog(
          'Repair DNS flush failed: ${output.isEmpty ? result.exitCode : output}',
        );
      }
    } on Object catch (e) {
      _appendLog('Repair DNS flush skipped: $e');
    }
  }

  Future<bool> _runPreflight(
    Directory runtimeDir,
    File configFile, {
    required bool needsNaiveProxy,
    required bool needsTun,
    required VpnCoreBackend coreBackend,
  }) async {
    final stopwatch = Stopwatch()..start();
    _appendLog('Windows preflight check started.');

    bool fail(String message) {
      _appendLog(message);
      _appendLog(
        'Windows preflight check failed in ${stopwatch.elapsedMilliseconds}ms.',
      );
      return false;
    }

    if (needsTun && !await _isAdministrator()) {
      _setStatus(YurichConnectStatus.adminRequired);
      if (!_statusController.isClosed) {
        _statusController.add({
          'type': 'alert',
          'code': 'adminRequired',
          'message':
              'Продвинутый TUN-режим требует права администратора. Стабильный proxy-режим работает без UAC.',
        });
      }
      return fail(
        'Preflight failed: Advanced TUN Mode requires administrator rights.',
      );
    }

    final missingRuntime = await _missingRuntimeFiles(
      runtimeDir,
      needsNaiveProxy: needsNaiveProxy,
      needsTun: needsTun,
      coreBackend: coreBackend,
    );
    if (missingRuntime.isNotEmpty) {
      return fail(
        'Preflight failed: отсутствуют runtime-файлы: ${missingRuntime.join(', ')}.',
      );
    }

    final missingVisualRuntime = await _missingVisualRuntimeDlls();
    if (missingVisualRuntime.isNotEmpty) {
      return fail(
        'Preflight failed: отсутствуют Microsoft Visual C++ Runtime DLL: ${missingVisualRuntime.join(', ')}. Установи Microsoft Visual C++ Redistributable 2015-2022 x64: https://aka.ms/vs/17/release/vc_redist.x64.exe',
      );
    }

    final busyPorts = await _busyLocalPorts(
      needsNaiveProxy: needsNaiveProxy,
      coreBackend: coreBackend,
    );
    if (busyPorts.isNotEmpty) {
      return fail(
        'Preflight failed: заняты локальные порты ${busyPorts.join(', ')}. Закрой другой прокси/VPN или перезапусти Windows.',
      );
    }

    final usesXrayCore = coreBackend == VpnCoreBackend.xray;
    final exe = File(
      '${runtimeDir.path}\\${usesXrayCore ? 'xray.exe' : 'sing-box.exe'}',
    );
    final configOk = usesXrayCore
        ? await _checkXrayConfig(exe, configFile, runtimeDir)
        : await _checkConfig(exe, configFile, runtimeDir);
    if (!configOk) {
      return fail(
        'Preflight failed: ${usesXrayCore ? 'Xray' : 'sing-box'} config check failed.',
      );
    }

    if (!usesXrayCore) {
      final dnsAudit = await _auditSingBoxDnsConfig(configFile);
      for (final warning in dnsAudit.warnings) {
        _appendLog('DNS config audit warning: $warning');
      }
      _appendLog('DNS config audit: ${dnsAudit.summary}');
      if (dnsAudit.fatalIssues.isNotEmpty) {
        _emitUserAlert(
          'DNS-конфиг небезопасен или рекурсивен. Отключи строгий DNS-режим или импортируй профиль заново.',
          code: 'dnsConfigAuditFailed',
        );
        return fail(
          'Preflight failed: DNS config audit failed: ${dnsAudit.fatalIssues.join('; ')}.',
        );
      }
    }

    _appendLog(
      'Windows preflight check passed in ${stopwatch.elapsedMilliseconds}ms.',
    );
    return true;
  }

  Future<_DnsConfigAuditResult> _auditSingBoxDnsConfig(File configFile) async {
    try {
      final decoded = jsonDecode(await configFile.readAsString(encoding: utf8));
      if (decoded is! Map) {
        return const _DnsConfigAuditResult(
          summary: 'raw/non-object config',
          warnings: ['DNS audit skipped: config root is not an object'],
        );
      }
      final map = decoded.cast<String, dynamic>();
      final dns = (map['dns'] as Map?)?.cast<String, dynamic>();
      final route = (map['route'] as Map?)?.cast<String, dynamic>();
      final outbounds = (map['outbounds'] as List?)
          ?.whereType<Map>()
          .map((outbound) => outbound.cast<String, dynamic>())
          .toList();
      if (dns == null || route == null || outbounds == null) {
        return const _DnsConfigAuditResult(
          summary: 'missing dns/route/outbounds',
          warnings: [
            'DNS audit skipped: config has no dns, route or outbounds',
          ],
        );
      }

      final servers = (dns['servers'] as List?)
          ?.whereType<Map>()
          .map((server) => server.cast<String, dynamic>())
          .toList();
      final byTag = <String, Map<String, dynamic>>{};
      for (final server in servers ?? const <Map<String, dynamic>>[]) {
        final tag = '${server['tag'] ?? ''}'.trim();
        if (tag.isNotEmpty) {
          byTag[tag] = server;
        }
      }

      final globalDns = byTag['global-dns'];
      final bootstrapDns = byTag['bootstrap-dns'];
      final finalDns = '${dns['final'] ?? 'unknown'}';
      final routeResolver = _dnsResolverTag(route['default_domain_resolver']);
      final proxyResolvers = outbounds
          .where((outbound) => outbound['tag'] == 'proxy')
          .map((outbound) => _dnsResolverTag(outbound['domain_resolver']))
          .where((tag) => tag.isNotEmpty)
          .toSet();
      final fatalIssues = <String>[];
      final warnings = <String>[];

      final globalDetour = '${globalDns?['detour'] ?? 'direct'}';
      final bootstrapDetour = '${bootstrapDns?['detour'] ?? 'direct'}';
      if (globalDns == null) {
        warnings.add('global-dns server is missing');
      }
      if (finalDns == 'local-dns') {
        warnings.add('dns.final uses local-dns; Windows DNS may leak locally');
      }
      if (bootstrapDns != null && bootstrapDns.containsKey('detour')) {
        fatalIssues.add('bootstrap-dns must be direct, not detoured');
      }
      if (globalDns?['detour'] == 'proxy' &&
          (routeResolver == 'global-dns' ||
              proxyResolvers.contains('global-dns'))) {
        fatalIssues.add(
          'global-dns detours through proxy while proxy/route resolver points back to global-dns',
        );
      }
      if (finalDns == 'global-dns' &&
          globalDns != null &&
          !globalDns.containsKey('detour') &&
          !proxyResolvers.contains('global-dns')) {
        warnings.add(
          'global-dns is direct; acceptable only for bootstrap/external-core profiles',
        );
      }

      return _DnsConfigAuditResult(
        summary: [
          'final=$finalDns',
          'global=${globalDns?['type'] ?? 'missing'}/$globalDetour',
          'bootstrap=${bootstrapDns?['type'] ?? 'missing'}/$bootstrapDetour',
          'route_resolver=${routeResolver.isEmpty ? 'none' : routeResolver}',
          'proxy_resolver=${proxyResolvers.isEmpty ? 'none' : proxyResolvers.join(',')}',
        ].join('; '),
        fatalIssues: fatalIssues,
        warnings: warnings,
      );
    } on Object catch (e) {
      return _DnsConfigAuditResult(
        summary: 'failed: $e',
        warnings: ['DNS audit failed: $e'],
      );
    }
  }

  String _dnsResolverTag(Object? resolver) {
    if (resolver is String) {
      return resolver.trim();
    }
    if (resolver is Map) {
      return '${resolver['server'] ?? ''}'.trim();
    }
    return '';
  }

  bool _shouldRunStartupCanary(String config) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return false;
      }
      final dns = decoded['dns'];
      if (dns is! Map) {
        return false;
      }
      final servers = dns['servers'];
      if (servers is! List) {
        return false;
      }
      return servers.whereType<Map>().any(
        (server) => server['tag'] == 'bootstrap-dns',
      );
    } on Object {
      return config.contains('bootstrap-dns');
    }
  }

  Future<_StartupCanaryResult> _runStartupCanary(
    File exe,
    File configFile,
    Directory runtimeDir,
  ) async {
    final stopwatch = Stopwatch()..start();
    Process? process;
    StreamSubscription<String>? stdoutSub;
    StreamSubscription<String>? stderrSub;
    final lines = <String>[];
    try {
      _appendLog('sing-box startup canary started.');
      process = await Process.start(
        exe.path,
        ['run', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        runInShell: false,
      );
      stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty && lines.length < 40) {
              lines.add(line.trim());
            }
          });
      stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty && lines.length < 40) {
              lines.add(line.trim());
            }
          });

      try {
        final exitCode = await process.exitCode.timeout(
          const Duration(milliseconds: 750),
        );
        await stdoutSub.cancel();
        await stderrSub.cancel();
        final output = lines.join('\n').trim();
        final message = output.isEmpty
            ? 'sing-box canary exited early with code $exitCode.'
            : output;
        _appendLog(
          'sing-box startup canary failed in ${stopwatch.elapsedMilliseconds}ms: $message',
        );
        return _StartupCanaryResult.failed(
          message,
          suggestsDnsFallback: _suggestsDnsFallback(message),
        );
      } on TimeoutException {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
        await stdoutSub.cancel();
        await stderrSub.cancel();
        _appendLog(
          'sing-box startup canary passed in ${stopwatch.elapsedMilliseconds}ms.',
        );
        return const _StartupCanaryResult.ok();
      }
    } on Object catch (e) {
      final message = 'sing-box canary could not start: $e';
      _appendLog(message);
      try {
        process?.kill(ProcessSignal.sigkill);
      } on Object {
        // Best-effort cleanup.
      }
      await stdoutSub?.cancel();
      await stderrSub?.cancel();
      return _StartupCanaryResult.failed(
        message,
        suggestsDnsFallback: _suggestsDnsFallback(message),
      );
    }
  }

  String? _safeDnsFallbackConfig(String config) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return null;
      }
      final map = decoded.cast<String, dynamic>();
      final dns = (map['dns'] as Map?)?.cast<String, dynamic>();
      final route = (map['route'] as Map?)?.cast<String, dynamic>();
      if (dns == null || route == null) {
        return null;
      }

      var changed = false;
      final servers = (dns['servers'] as List?)?.whereType<Map>().toList();
      if (servers != null) {
        final nextServers = servers
            .where((server) => server['tag'] != 'bootstrap-dns')
            .map((server) => server.cast<String, dynamic>())
            .toList();
        if (nextServers.length != servers.length) {
          dns['servers'] = nextServers;
          changed = true;
        }
      }

      final localResolver = {'server': 'local-dns', 'strategy': 'ipv4_only'};
      route['default_domain_resolver'] = localResolver;
      final outbounds = map['outbounds'];
      if (outbounds is List) {
        for (final outbound in outbounds.whereType<Map>()) {
          if (outbound['tag'] == 'proxy') {
            outbound['domain_resolver'] = localResolver;
            changed = true;
          }
        }
      }

      final rules = (dns['rules'] as List?)?.whereType<Map>().toList();
      if (rules != null) {
        final hasRussianLocalRule = rules.any(
          (rule) =>
              rule['server'] == 'local-dns' && rule['domain_suffix'] is List,
        );
        if (!hasRussianLocalRule) {
          dns['rules'] = [
            ...rules.map((rule) => rule.cast<String, dynamic>()),
            {
              'domain_suffix': SingBoxConfigBuilder.russianDirectDomains,
              'action': 'route',
              'server': 'local-dns',
            },
          ];
          changed = true;
        }
      }

      return changed ? const JsonEncoder.withIndent('  ').convert(map) : null;
    } on Object catch (e) {
      _appendLog('Safe DNS fallback config rewrite failed: $e');
      return null;
    }
  }

  Future<bool> _isAdministrator() async {
    if (!Platform.isWindows) {
      return true;
    }
    const script =
        r"([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)";
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 5));
      return '${result.stdout}'.trim().toLowerCase() == 'true';
    } on Object {
      return false;
    }
  }

  Future<List<String>> _missingRuntimeFiles(
    Directory runtimeDir, {
    required bool needsNaiveProxy,
    required bool needsTun,
    required VpnCoreBackend coreBackend,
  }) async {
    final names = coreBackend == VpnCoreBackend.xray
        ? ['xray.exe']
        : [
            'sing-box.exe',
            'libcronet.dll',
            if (needsTun) 'wintun.dll',
            if (needsNaiveProxy) 'naive.exe',
          ];
    final missing = <String>[];
    for (final name in names) {
      if (!await File('${runtimeDir.path}\\$name').exists()) {
        missing.add(name);
      }
    }
    return missing;
  }

  Future<List<String>> _missingVisualRuntimeDlls() async {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final system32 = Directory('$systemRoot\\System32');
    final missing = <String>[];
    for (final name in _visualRuntimeDlls) {
      final bundled = File('${executableDir.path}\\$name');
      final installed = File('${system32.path}\\$name');
      if (!await bundled.exists() && !await installed.exists()) {
        missing.add(name);
      }
    }
    return missing;
  }

  Future<List<int>> _busyLocalPorts({
    required bool needsNaiveProxy,
    required VpnCoreBackend coreBackend,
  }) async {
    final ports = <int>[
      SingBoxConfigBuilder.localMixedProxyPort,
      SingBoxConfigBuilder.localSocksProxyPort,
      if (coreBackend != VpnCoreBackend.xray)
        SingBoxConfigBuilder.windowsClashApiPort,
      if (needsNaiveProxy) SingBoxConfigBuilder.naiveProxySocksPort,
    ];
    final busy = <int>[];
    for (final port in ports) {
      ServerSocket? socket;
      try {
        socket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
          shared: false,
        ).timeout(const Duration(seconds: 2));
      } on Object {
        busy.add(port);
      } finally {
        await socket?.close();
      }
    }
    return busy;
  }

  Future<String> _prepareConfigWithGeoIpFallback(
    Directory runtimeDir,
    Directory configDir,
    String config,
  ) async {
    Object? decoded;
    try {
      decoded = jsonDecode(config);
    } on Object {
      return config;
    }
    if (decoded is! Map) {
      return config;
    }

    final map = decoded.cast<String, dynamic>();
    final route = (map['route'] as Map?)?.cast<String, dynamic>();
    if (route == null) {
      return config;
    }

    final ruleSets = (route['rule_set'] as List?)?.whereType<Map>().toList();
    if (ruleSets == null ||
        !ruleSets.any(
          (item) => item['tag'] == SingBoxConfigBuilder.russianGeoIpRuleSet,
        )) {
      return config;
    }

    final rulesDir = Directory('${configDir.path}\\rules');
    final cacheFile = File('${rulesDir.path}\\geoip-ru.srs');
    final hasGeoIp = await _ensureGeoIpRuleSet(runtimeDir, cacheFile);

    if (hasGeoIp) {
      route['rule_set'] = ruleSets.map((item) {
        final normalized = item.cast<String, dynamic>();
        if (normalized['tag'] == SingBoxConfigBuilder.russianGeoIpRuleSet) {
          return {
            'type': 'local',
            'tag': SingBoxConfigBuilder.russianGeoIpRuleSet,
            'format': 'binary',
            'path': cacheFile.path,
          };
        }
        return normalized;
      }).toList();
      return const JsonEncoder.withIndent('  ').convert(map);
    }

    _appendLog(
      'Warning: geoip-ru.srs недоступен. VPN запускается без RU-IP rule-set; домены .ru/.рф/.su всё равно идут напрямую.',
    );
    route['rule_set'] = ruleSets
        .where(
          (item) => item['tag'] != SingBoxConfigBuilder.russianGeoIpRuleSet,
        )
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final rules = (route['rules'] as List?)?.whereType<Map>().toList();
    if (rules != null) {
      route['rules'] = rules
          .where(
            (rule) =>
                rule['rule_set'] != SingBoxConfigBuilder.russianGeoIpRuleSet,
          )
          .map((item) => item.cast<String, dynamic>())
          .toList();
    }
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  Future<bool> _ensureGeoIpRuleSet(Directory runtimeDir, File cacheFile) async {
    final bundled = File('${runtimeDir.path}\\geoip-ru.srs');
    try {
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        final age = DateTime.now().difference(await cacheFile.lastModified());
        if (age > const Duration(days: 7)) {
          unawaited(_refreshGeoIpRuleSet(cacheFile));
        }
        return true;
      }

      if (await bundled.exists() && await bundled.length() > 0) {
        await cacheFile.parent.create(recursive: true);
        await bundled.copy(cacheFile.path);
        unawaited(_refreshGeoIpRuleSet(cacheFile));
        _appendLog('geoip-ru.srs loaded from bundled fallback.');
        return true;
      }

      return await _refreshGeoIpRuleSet(cacheFile);
    } on Object catch (e) {
      _appendLog('Warning: geoip-ru.srs fallback failed: $e');
      return await cacheFile.exists() && await cacheFile.length() > 0;
    }
  }

  Future<bool> _refreshGeoIpRuleSet(File cacheFile) async {
    final tempFile = File('${cacheFile.path}.download');
    try {
      await cacheFile.parent.create(recursive: true);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client
            .getUrl(Uri.parse(SingBoxConfigBuilder.russianGeoIpRuleSetUrl))
            .timeout(const Duration(seconds: 8));
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        final bytes = await response
            .fold<List<int>>(<int>[], (buffer, data) => buffer..addAll(data))
            .timeout(const Duration(seconds: 8));
        if (bytes.length < 1024) {
          throw const FormatException('geoip-ru.srs is too small');
        }
        await tempFile.writeAsBytes(bytes, flush: true);
        if (await cacheFile.exists()) {
          await cacheFile.delete();
        }
        await tempFile.rename(cacheFile.path);
        _appendLog('geoip-ru.srs cache refreshed.');
        return true;
      } finally {
        client.close(force: true);
      }
    } on Object catch (e) {
      _appendLog('Warning: geoip-ru.srs download skipped: $e');
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } on Object {
        // Ignore partial download cleanup errors.
      }
      return await cacheFile.exists() && await cacheFile.length() > 0;
    }
  }

  Future<bool> _checkConfig(
    File exe,
    File configFile,
    Directory runtimeDir,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final fingerprint = await _configCheckFingerprint(exe, configFile);
      final cached = _configCheckCache[fingerprint];
      if (cached == true) {
        _appendLog(
          'sing-box config check cache hit in ${stopwatch.elapsedMilliseconds}ms.',
        );
        return true;
      }

      final result = await Process.run(
        exe.path,
        ['check', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        runInShell: false,
      ).timeout(const Duration(seconds: 12));
      final output = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode == 0) {
        _configCheckCache[fingerprint] = true;
        if (_configCheckCache.length > 24) {
          _configCheckCache.remove(_configCheckCache.keys.first);
        }
        _appendLog(
          'sing-box config check passed in ${stopwatch.elapsedMilliseconds}ms.',
        );
        return true;
      }
      _configCheckCache.remove(fingerprint);
      _appendLog(
        output.isEmpty
            ? 'sing-box config check failed with code ${result.exitCode}'
            : 'sing-box config check failed: $output',
      );
      _emitUserAlert(_friendlyConfigError(output));
    } on Object catch (e) {
      _appendLog('sing-box config check failed: $e');
      _emitUserAlert('Конфиг повреждён. Импортируйте профиль заново.');
    }
    return false;
  }

  Future<bool> _checkXrayConfig(
    File exe,
    File configFile,
    Directory runtimeDir,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final fingerprint = await _configCheckFingerprint(exe, configFile);
      final cached = _configCheckCache[fingerprint];
      if (cached == true) {
        _appendLog(
          'Xray config check cache hit in ${stopwatch.elapsedMilliseconds}ms.',
        );
        return true;
      }

      final attempts = <List<String>>[
        ['-test', '-c', configFile.path],
        ['run', '-test', '-c', configFile.path],
      ];
      var lastOutput = '';
      var unsupportedCli = false;
      for (final args in attempts) {
        final result = await Process.run(
          exe.path,
          args,
          workingDirectory: runtimeDir.path,
          runInShell: false,
        ).timeout(const Duration(seconds: 12));
        final output = '${result.stdout}${result.stderr}'.trim();
        if (result.exitCode == 0) {
          _configCheckCache[fingerprint] = true;
          if (_configCheckCache.length > 24) {
            _configCheckCache.remove(_configCheckCache.keys.first);
          }
          _appendLog(
            'Xray config check passed in ${stopwatch.elapsedMilliseconds}ms.',
          );
          return true;
        }
        lastOutput = output.isEmpty
            ? 'Xray config check failed with code ${result.exitCode}'
            : output;
        final lower = lastOutput.toLowerCase();
        unsupportedCli =
            lower.contains('unknown command') ||
            lower.contains('flag provided but not defined') ||
            lower.contains('unknown shorthand') ||
            lower.contains('unknown flag');
        if (!unsupportedCli) {
          break;
        }
      }

      _configCheckCache.remove(fingerprint);
      _appendLog('Xray config check failed: $lastOutput');
      _emitUserAlert(_friendlyXrayConfigError(lastOutput));
    } on Object catch (e) {
      _appendLog('Xray config check failed: $e');
      _emitUserAlert(
        'Xray-конфиг повреждён. Импортируйте VLESS профиль заново.',
      );
    }
    return false;
  }

  Future<String> _configCheckFingerprint(File exe, File configFile) async {
    final exeStat = await exe.stat();
    final config = await configFile.readAsString(encoding: utf8);
    final raw =
        '${_fnv1a64(config)}|${exeStat.size}|${exeStat.modified.millisecondsSinceEpoch}';
    return _fnv1a64(raw);
  }

  String _fnv1a64(String value) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  String _friendlyConfigError(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('server') && lower.contains('missing')) {
      return 'В профиле отсутствует адрес сервера.';
    }
    if (lower.contains('uuid')) {
      return 'В профиле отсутствует UUID.';
    }
    if (lower.contains('xhttp') || lower.contains('splithttp')) {
      return 'VLESS XHTTP требует Xray-core. В текущей Windows-сборке bundled sing-box поддерживает TCP/WS/gRPC/HTTP/HTTPUpgrade.';
    }
    if (lower.contains('flow')) {
      return 'Ошибка VLESS: неподдерживаемый flow. Поддерживается xtls-rprx-vision.';
    }
    if (lower.contains('packet_encoding') ||
        lower.contains('packet encoding')) {
      return 'Ошибка VLESS: неподдерживаемый packet_encoding. Доступны packetaddr или xudp.';
    }
    if (lower.contains('transport')) {
      return 'Ошибка VLESS: неподдерживаемый transport.';
    }
    if (lower.contains('public_key') || lower.contains('publickey')) {
      return 'Ошибка Reality: отсутствует publicKey.';
    }
    if (lower.contains('short_id') || lower.contains('shortid')) {
      return 'Ошибка Reality: неверный shortId.';
    }
    if (lower.contains('server_name') || lower.contains('servername')) {
      return 'Ошибка Reality: отсутствует serverName.';
    }
    if (lower.contains('password') || lower.contains('auth')) {
      return 'В профиле отсутствует пароль или токен авторизации.';
    }
    if (lower.contains('naive')) {
      return 'Ошибка NaiveProxy: неверный формат ссылки.';
    }
    return 'Конфиг повреждён. Импортируйте профиль заново.';
  }

  String _friendlyXrayConfigError(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('xhttp')) {
      return 'Ошибка VLESS XHTTP: проверь path, host, mode и настройки сервера.';
    }
    if (lower.contains('reality')) {
      return 'Ошибка Reality для Xray: проверь SNI, publicKey, shortId и fingerprint.';
    }
    if (lower.contains('vless')) {
      return 'Ошибка VLESS профиля для Xray. Импортируйте ссылку заново.';
    }
    if (lower.contains('address') || lower.contains('port')) {
      return 'В Xray профиле отсутствует адрес или порт сервера.';
    }
    return 'Xray-конфиг повреждён. Импортируйте VLESS профиль заново.';
  }

  String _friendlyStartupFailure(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('start dns') ||
        lower.contains('dns/https') ||
        lower.contains('bootstrap-dns') ||
        lower.contains('global-dns')) {
      return 'Yurich Core не стартовал из-за DNS-конфига. Включён безопасный DNS fallback или отключи режим DNS только через VPN.';
    }
    if (lower.contains('address already in use') ||
        lower.contains('bind') ||
        lower.contains('listen')) {
      return 'Yurich Core не стартовал: локальный порт уже занят другим приложением.';
    }
    if (lower.contains('tun') || lower.contains('wintun')) {
      return 'Yurich Core не стартовал: проблема TUN/Wintun. Проверь права администратора или Stable Proxy Mode.';
    }
    if (lower.contains('reality') &&
        (lower.contains('handshake') || lower.contains('tls'))) {
      return 'VLESS Reality не прошёл handshake. Проверь SNI, publicKey, shortId, fingerprint и сервер.';
    }
    if (lower.contains('vless') &&
        (lower.contains('handshake') || lower.contains('tls'))) {
      return 'VLESS TLS не прошёл handshake. Проверь SNI, сертификат, fingerprint и сервер.';
    }
    if (lower.contains('fatal') || lower.contains('start service')) {
      return 'Yurich Core не стартовал из-за fatal-ошибки конфигурации. Повторный retry остановлен.';
    }
    return _friendlyConfigError(output);
  }

  bool _suggestsDnsFallback(String output) {
    final lower = output.toLowerCase();
    return lower.contains('start dns') ||
        lower.contains('dns/https') ||
        lower.contains('bootstrap-dns') ||
        lower.contains('global-dns') ||
        lower.contains('dns server');
  }

  void _emitUserAlert(String message, {String? code}) {
    if (_statusController.isClosed || message.isEmpty) {
      return;
    }
    final event = <String, dynamic>{'type': 'alert', 'message': message};
    if (code != null) {
      event['code'] = code;
    }
    _statusController.add(event);
  }

  Future<void> _stopStaleRuntimeProcesses(Directory runtimeDir) async {
    final runtimePrefix = runtimeDir.absolute.path.endsWith('\\')
        ? runtimeDir.absolute.path
        : '${runtimeDir.absolute.path}\\';
    final script =
        '''
\$runtimePrefix = ${_quotePowerShell(runtimePrefix)}
\$names = @('sing-box.exe', 'naive.exe', 'xray.exe')
\$stopped = 0
Get-CimInstance Win32_Process |
  Where-Object {
    \$names -contains \$_.Name -and (
      (\$_.ExecutablePath -and \$_.ExecutablePath.StartsWith(\$runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) -or
      (\$_.CommandLine -and \$_.CommandLine.IndexOf(\$runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    )
  } |
  ForEach-Object {
    try {
      Stop-Process -Id \$_.ProcessId -Force -ErrorAction Stop
      \$stopped += 1
    } catch {}
  }
Write-Output \$stopped
''';
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 8));
      final stopped = int.tryParse('${result.stdout}'.trim()) ?? 0;
      if (stopped > 0) {
        _appendLog('Stopped stale Yurich Core runtime processes: $stopped');
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } on Object catch (e) {
      _appendLog('Stale process cleanup skipped: $e');
    }
  }

  @override
  Future<List<String>> getLogs() async => List.unmodifiable(_logs);

  @override
  Future<bool> clearLogs() async {
    _logs.clear();
    return true;
  }

  @override
  Future<void> dispose() async {
    await stopVPN();
    await _statusController.close();
    await _trafficController.close();
    await _logController.close();
  }

  void _pipeProcess(Process process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog(line, fileName: _coreLogFileName));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog(line, fileName: _coreLogFileName));
  }

  Future<bool> _startNaiveProxy(
    Directory runtimeDir,
    Directory configDir,
  ) async {
    final exe = File('${runtimeDir.path}\\naive.exe');
    if (!await exe.exists()) {
      _appendLog('naive.exe не найден в ${runtimeDir.path}');
      return false;
    }

    final configFile = File('${configDir.path}\\naive.json');
    await configFile.writeAsString(_naiveProxyConfig!, encoding: utf8);
    _appendLog('Starting NaiveProxy core ${exe.path}');
    final process = await Process.start(
      exe.path,
      [configFile.path],
      workingDirectory: runtimeDir.path,
      runInShell: false,
    );
    _naiveProcess = process;
    _naiveProcessPid = process.pid;
    _appendLog('NaiveProxy PID ${process.pid}');
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('naive: $line', fileName: 'naive.log'));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('naive: $line', fileName: 'naive.log'));

    unawaited(
      process.exitCode.then((code) {
        _appendLog('naive exited with code $code');
        if (_naiveProcess == process) {
          _naiveProcess = null;
          _naiveProcessPid = null;
        }
        if (_process != null && _status != YurichConnectStatus.stopping) {
          _recordRuntimeFailure('naive', code);
          _appendLog(
            'NaiveProxy core stopped while VPN was running; keeping Yurich Core alive and reporting a degraded Naive runtime event. Reconnect manually or try another Naive mode.',
          );
          if (!_statusController.isClosed) {
            _statusController.add({
              'type': 'alert',
              'code': 'naiveRuntimeStopped',
              'message':
                  'NaiveProxy остановился. VPN не перезапущен автоматически, чтобы не рвать активные сессии. Переподключи профиль вручную или выбери другой режим Naive.',
            });
          }
        }
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 350));
    return _naiveProcess == process;
  }

  Future<void> _stopNaiveProxy({
    Duration gracefulTimeout = const Duration(seconds: 4),
    Duration killTimeout = const Duration(seconds: 2),
  }) async {
    final process = _naiveProcess;
    if (process == null) {
      _naiveProcessPid = null;
      return;
    }
    _appendLog('Stopping NaiveProxy core PID $_naiveProcessPid...');
    process.kill();
    try {
      await process.exitCode.timeout(gracefulTimeout);
    } on TimeoutException {
      _appendLog(
        'NaiveProxy did not exit in time; killing PID $_naiveProcessPid.',
      );
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(killTimeout);
      } on TimeoutException {
        _appendLog('NaiveProxy kill timeout for PID $_naiveProcessPid.');
      }
    } finally {
      if (_naiveProcess == process) {
        _naiveProcess = null;
      }
      _naiveProcessPid = null;
    }
  }

  void _setStatus(String status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add({'status': status});
    }
  }

  void _appendLog(String message, {String fileName = 'yurich.log'}) {
    final trimmed = _redactSensitive(message.trim());
    if (trimmed.isEmpty) {
      return;
    }
    if (_isSuppressedDiagnosticLog(trimmed)) {
      return;
    }
    if (!_reportedAdminIssue &&
        trimmed.toLowerCase().contains('access is denied')) {
      _reportedAdminIssue = true;
      if (!_statusController.isClosed) {
        _statusController.add({
          'type': 'alert',
          'message':
              'Windows не дал доступ к TUN. Перезапусти Yurich Connect от имени администратора только для продвинутого TUN-режима.',
        });
      }
    }
    _logs.add(trimmed);
    if (_logs.length > 300) {
      _logs.removeRange(0, _logs.length - 300);
    }
    if (!_logController.isClosed) {
      _logController.add({'type': 'log', 'message': trimmed});
    }
    unawaited(_writeLogFile('yurich.log', trimmed));
    if (fileName != 'yurich.log') {
      unawaited(_writeLogFile(fileName, trimmed));
    }
  }

  bool _isSuppressedDiagnosticLog(String message) {
    if (!RuntimeLogClassifier.isDiagnosticNoise(message)) {
      return false;
    }
    _suppressedDiagnosticLogCount += 1;
    if (_suppressedDiagnosticLogCount == 1 ||
        _suppressedDiagnosticLogCount % 100 == 0) {
      final summary =
          'Suppressed repetitive runtime diagnostic noise: $_suppressedDiagnosticLogCount entries.';
      _logs.add(summary);
      if (_logs.length > 300) {
        _logs.removeRange(0, _logs.length - 300);
      }
      if (!_logController.isClosed) {
        _logController.add({'type': 'log', 'message': summary});
      }
      unawaited(_writeLogFile('yurich.log', summary));
    }
    return true;
  }

  Future<void> _writeLogFile(String fileName, String message) async {
    final previous = _logWriteChains[fileName] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((_) {})
        .then((_) => _writeLogFileLocked(fileName, message));
    _logWriteChains[fileName] = next;
    try {
      await next;
    } on Object {
      // File logging must never break the VPN control flow.
    } finally {
      if (_logWriteChains[fileName] == next) {
        _logWriteChains.remove(fileName);
      }
    }
  }

  Future<void> _writeLogFileLocked(String fileName, String message) async {
    final base = await _configDir();
    final dir = Directory('${base.path}\\logs');
    await dir.create(recursive: true);
    final file = File('${dir.path}\\$fileName');
    await _rotateLogFileIfNeeded(file);
    final timestamp = DateTime.now().toIso8601String();
    await file.writeAsString(
      '[$timestamp] $message${Platform.lineTerminator}',
      mode: FileMode.append,
      encoding: utf8,
      flush: false,
    );
  }

  Future<void> _rotateLogFileIfNeeded(File file) async {
    if (!await file.exists()) {
      return;
    }
    final length = await file.length();
    if (length < _maxLogFileBytes) {
      return;
    }

    for (var index = _maxLogBackups - 1; index >= 1; index -= 1) {
      final source = File('${file.path}.$index');
      if (!await source.exists()) {
        continue;
      }
      final target = File('${file.path}.${index + 1}');
      if (await target.exists()) {
        await target.delete();
      }
      await source.rename(target.path);
    }

    final firstBackup = File('${file.path}.1');
    if (await firstBackup.exists()) {
      await firstBackup.delete();
    }
    await file.rename(firstBackup.path);
  }

  String _redactSensitive(String value) {
    return SecretRedactor.redact(value);
  }

  void _startTrafficTicker() {
    _stopTrafficTicker();
    _sessionTotalBytes = 0;
    _emitTraffic(0, 0);
    if (_usesXrayCore) {
      _appendLog(
        'Traffic monitor: Xray backend has no Clash API traffic feed.',
      );
      return;
    }
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_process != null &&
          _trafficSocket == null &&
          !_trafficSocketConnecting) {
        unawaited(_connectTrafficSocket());
      }
    });
    unawaited(_connectTrafficSocket());
  }

  void _stopTrafficTicker() {
    _trafficTimer?.cancel();
    _trafficTimer = null;
    unawaited(_trafficSocket?.close());
    _trafficSocket = null;
    _trafficSocketConnecting = false;
    _sessionTotalBytes = 0;
    _emitTraffic(0, 0);
  }

  Future<void> _connectTrafficSocket() async {
    if (_trafficSocketConnecting ||
        _trafficSocket != null ||
        _process == null) {
      return;
    }
    _trafficSocketConnecting = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_process == null) {
        return;
      }
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${SingBoxConfigBuilder.windowsClashApiPort}/traffic',
      ).timeout(const Duration(seconds: 3));
      _trafficSocket = socket;
      socket.listen(
        _handleTrafficMessage,
        onDone: () {
          if (_trafficSocket == socket) {
            _trafficSocket = null;
          }
        },
        onError: (_) {
          if (_trafficSocket == socket) {
            _trafficSocket = null;
          }
        },
        cancelOnError: true,
      );
    } on Object catch (e) {
      _appendLog('Traffic monitor unavailable: $e');
    } finally {
      _trafficSocketConnecting = false;
    }
  }

  void _handleTrafficMessage(Object? message) {
    if (message is! String || message.isEmpty) {
      return;
    }
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final up = (json['up'] as num?)?.round() ?? 0;
      final down = (json['down'] as num?)?.round() ?? 0;
      _sessionTotalBytes += up + down;
      _emitTraffic(up, down);
    } on Object {
      // Ignore malformed traffic frames from external controller.
    }
  }

  void _emitTraffic(int up, int down) {
    if (_trafficController.isClosed) {
      return;
    }
    _trafficController.add({
      'uplinkSpeed': up,
      'downlinkSpeed': down,
      'sessionTotal': _sessionTotalBytes,
      'formattedUplinkSpeed': '${_formatBytes(up)}/s',
      'formattedDownlinkSpeed': '${_formatBytes(down)}/s',
      'formattedSessionTotal': _formatBytes(_sessionTotalBytes),
    });
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    if (unit == 0) {
      return '${value.round()} ${units[unit]}';
    }
    final text = value >= 10
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(2);
    return '${text.replaceAll('.', ',')} ${units[unit]}';
  }

  String _quotePowerShell(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  Future<Directory> _runtimeDir() async {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final bundledRuntime = Directory('${executableDir.path}\\runtime');
    if (await File('${bundledRuntime.path}\\sing-box.exe').exists() ||
        await File('${bundledRuntime.path}\\xray.exe').exists()) {
      return bundledRuntime;
    }

    final projectRuntime = Directory('assets\\windows\\sing-box');
    if (await File('${projectRuntime.path}\\sing-box.exe').exists() ||
        await File('${projectRuntime.path}\\xray.exe').exists()) {
      return projectRuntime.absolute;
    }

    throw StateError(
      'Windows runtime не найден. Нужен sing-box.exe или xray.exe.',
    );
  }

  Future<Directory> _configDir() async {
    final appData = Platform.environment['APPDATA'];
    final base = appData == null || appData.isEmpty
        ? Directory('${Platform.environment['USERPROFILE']}\\.yurich_connect')
        : Directory('$appData\\Yurich Connect');
    await _migrateLegacyConfigDir(base);
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }

  Future<void> _migrateLegacyConfigDir(Directory target) async {
    if (await target.exists()) {
      return;
    }
    final appData = Platform.environment['APPDATA'];
    final legacy = appData == null || appData.isEmpty
        ? Directory('${Platform.environment['USERPROFILE']}\\.aurum_vpn')
        : Directory('$appData\\Aurum VPN');
    if (!await legacy.exists()) {
      return;
    }

    await for (final entity in legacy.list(recursive: true)) {
      final relative = entity.path.substring(legacy.path.length);
      final destination = '${target.path}$relative';
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await File(destination).parent.create(recursive: true);
        await entity.copy(destination);
      }
    }
  }
}

class _StartupCanaryResult {
  const _StartupCanaryResult._({
    required this.ok,
    required this.fatal,
    required this.suggestsDnsFallback,
    this.message,
  });

  const _StartupCanaryResult.ok()
    : this._(ok: true, fatal: false, suggestsDnsFallback: false);

  const _StartupCanaryResult.failed(
    String message, {
    required bool suggestsDnsFallback,
  }) : this._(
         ok: false,
         fatal: true,
         suggestsDnsFallback: suggestsDnsFallback,
         message: message,
       );

  final bool ok;
  final bool fatal;
  final bool suggestsDnsFallback;
  final String? message;
}

class _DnsConfigAuditResult {
  const _DnsConfigAuditResult({
    required this.summary,
    this.fatalIssues = const [],
    this.warnings = const [],
  });

  final String summary;
  final List<String> fatalIssues;
  final List<String> warnings;
}
