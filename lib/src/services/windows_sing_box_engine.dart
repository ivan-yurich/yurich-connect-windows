import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../branding.dart';
import 'secret_redactor.dart';
import 'sing_box_config_builder.dart';
import 'vpn_engine.dart';

class WindowsSingBoxEngine implements VpnEngine {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final _trafficController = StreamController<Map<String, dynamic>>.broadcast();
  final _logController = StreamController<Map<String, dynamic>>.broadcast();
  final _logs = <String>[];

  Process? _process;
  Process? _naiveProcess;
  int? _processPid;
  int? _naiveProcessPid;
  String _status = YurichConnectStatus.stopped;
  String _config = '{}';
  String? _naiveProxyConfig;
  String _notificationTitle = YurichBranding.appName;
  String _notificationDescription = 'VPN connection is active';
  Timer? _trafficTimer;
  WebSocket? _trafficSocket;
  bool _trafficSocketConnecting = false;
  bool _reportedAdminIssue = false;
  bool _transitioning = false;
  int _sessionTotalBytes = 0;
  static const _visualRuntimeDlls = [
    'MSVCP140.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
  ];

  @override
  SingBoxConfigTarget get configTarget => SingBoxConfigTarget.windows;

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
  Future<bool> saveConfig(String config, {String? naiveProxyConfig}) async {
    _config = config;
    _naiveProxyConfig = naiveProxyConfig;
    return config.trim().isNotEmpty;
  }

  @override
  Future<String> getConfig() async => _config;

  @override
  Future<bool> startVPN() async {
    if (_process != null) {
      _appendLog(
        'Start skipped: sing-box is already tracked with PID $_processPid.',
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
    try {
      final runtimeDir = await _runtimeDir();
      final configDir = await _configDir();
      await _stopStaleRuntimeProcesses(runtimeDir);

      final configFile = File('${configDir.path}\\config.json');
      final effectiveConfig = await _prepareConfigWithGeoIpFallback(
        runtimeDir,
        configDir,
        _config,
      );
      await configFile.writeAsString(effectiveConfig, encoding: utf8);

      final needsNaiveProxy = _naiveProxyConfig != null;
      final preflightOk = await _runPreflight(
        runtimeDir,
        configFile,
        needsNaiveProxy: needsNaiveProxy,
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

      final exe = File('${runtimeDir.path}\\sing-box.exe');
      if (!await exe.exists()) {
        _appendLog('sing-box.exe не найден в ${runtimeDir.path}');
        _setStatus(YurichConnectStatus.stopped);
        return false;
      }

      _appendLog('Starting sing-box ${exe.path}');
      _appendLog('Windows TUN mode requires administrator privileges.');
      final process = await Process.start(
        exe.path,
        ['run', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        runInShell: false,
      );
      _process = process;
      _processPid = process.pid;
      _appendLog('sing-box PID ${process.pid}');
      _pipeProcess(process);
      _startTrafficTicker();

      unawaited(
        process.exitCode.then((code) async {
          _appendLog('sing-box exited with code $code');
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

      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (_process == process) {
        _setStatus(YurichConnectStatus.started);
        return true;
      }

      await _stopNaiveProxy();
      if (_status != YurichConnectStatus.adminRequired) {
        _setStatus(YurichConnectStatus.error);
      }
      return false;
    } on Object catch (e) {
      _appendLog('Не удалось запустить sing-box: $e');
      await _stopNaiveProxy();
      if (_status != YurichConnectStatus.adminRequired) {
        _setStatus(YurichConnectStatus.error);
      }
      return false;
    } finally {
      _transitioning = false;
    }
  }

  @override
  Future<bool> stopVPN() async {
    if (_transitioning && _status == YurichConnectStatus.starting) {
      _appendLog('Stop requested while VPN is starting; waiting for cleanup.');
    }
    final process = _process;
    if (process == null) {
      try {
        await _stopStaleRuntimeProcesses(await _runtimeDir());
      } on Object {
        // Best-effort cleanup for untracked processes after app restarts.
      }
      await _stopNaiveProxy();
      _setStatus(YurichConnectStatus.stopped);
      return true;
    }

    _setStatus(YurichConnectStatus.stopping);
    _appendLog('Stopping sing-box...');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _appendLog('sing-box did not exit in time; killing PID $_processPid.');
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _appendLog('sing-box kill timeout for PID $_processPid.');
      }
    }
    _process = null;
    _processPid = null;
    await _stopNaiveProxy();
    _stopTrafficTicker();
    _setStatus(YurichConnectStatus.stopped);
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

      final wintun = File('${runtimeDir.path}\\wintun.dll');
      if (!await wintun.exists()) {
        needsReboot = true;
        _appendLog('Repair warning: wintun.dll is missing.');
      } else {
        _appendLog('Repair check: wintun.dll found.');
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

  Future<void> _cleanupTemporaryConfigs(Directory configDir) async {
    final names = ['config.json', 'naive.json', 'geoip-ru.srs.download'];
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
  }) async {
    _appendLog('Windows preflight check started.');

    if (!await _isAdministrator()) {
      _setStatus(YurichConnectStatus.adminRequired);
      _appendLog(
        'Preflight failed: Yurich Connect запущен без прав администратора.',
      );
      if (!_statusController.isClosed) {
        _statusController.add({
          'type': 'alert',
          'code': 'adminRequired',
          'message': 'Для подключения требуются права администратора.',
        });
      }
      return false;
    }

    final missingRuntime = await _missingRuntimeFiles(
      runtimeDir,
      needsNaiveProxy: needsNaiveProxy,
    );
    if (missingRuntime.isNotEmpty) {
      _appendLog(
        'Preflight failed: отсутствуют runtime-файлы: ${missingRuntime.join(', ')}.',
      );
      return false;
    }

    final missingVisualRuntime = await _missingVisualRuntimeDlls();
    if (missingVisualRuntime.isNotEmpty) {
      _appendLog(
        'Preflight failed: отсутствуют Microsoft Visual C++ Runtime DLL: ${missingVisualRuntime.join(', ')}. Установи Microsoft Visual C++ Redistributable 2015-2022 x64: https://aka.ms/vs/17/release/vc_redist.x64.exe',
      );
      return false;
    }

    final busyPorts = await _busyLocalPorts(needsNaiveProxy: needsNaiveProxy);
    if (busyPorts.isNotEmpty) {
      _appendLog(
        'Preflight failed: заняты локальные порты ${busyPorts.join(', ')}. Закрой другой прокси/VPN или перезапусти Windows.',
      );
      return false;
    }

    final exe = File('${runtimeDir.path}\\sing-box.exe');
    if (!await _checkConfig(exe, configFile, runtimeDir)) {
      return false;
    }

    _appendLog('Windows preflight check passed.');
    return true;
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
  }) async {
    final names = [
      'sing-box.exe',
      'wintun.dll',
      'libcronet.dll',
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

  Future<List<int>> _busyLocalPorts({required bool needsNaiveProxy}) async {
    final ports = <int>[
      SingBoxConfigBuilder.localMixedProxyPort,
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
    try {
      final result = await Process.run(
        exe.path,
        ['check', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        runInShell: false,
      ).timeout(const Duration(seconds: 12));
      final output = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode == 0) {
        return true;
      }
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

  String _friendlyConfigError(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('server') && lower.contains('missing')) {
      return 'В профиле отсутствует адрес сервера.';
    }
    if (lower.contains('uuid')) {
      return 'В профиле отсутствует UUID.';
    }
    if (lower.contains('public_key') || lower.contains('publickey')) {
      return 'Ошибка Reality: отсутствует publicKey.';
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

  void _emitUserAlert(String message) {
    if (_statusController.isClosed || message.isEmpty) {
      return;
    }
    _statusController.add({'type': 'alert', 'message': message});
  }

  Future<void> _stopStaleRuntimeProcesses(Directory runtimeDir) async {
    final runtimePrefix = runtimeDir.absolute.path.endsWith('\\')
        ? runtimeDir.absolute.path
        : '${runtimeDir.absolute.path}\\';
    final script =
        '''
\$runtimePrefix = ${_quotePowerShell(runtimePrefix)}
\$names = @('sing-box.exe', 'naive.exe')
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
        .listen((line) => _appendLog(line, fileName: 'sing-box.log'));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog(line, fileName: 'sing-box.log'));
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
          _appendLog('NaiveProxy core stopped while VPN was running.');
          _process?.kill();
        }
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 700));
    return _naiveProcess == process;
  }

  Future<void> _stopNaiveProxy() async {
    final process = _naiveProcess;
    if (process == null) {
      _naiveProcessPid = null;
      return;
    }
    _appendLog('Stopping NaiveProxy core PID $_naiveProcessPid...');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      _appendLog(
        'NaiveProxy did not exit in time; killing PID $_naiveProcessPid.',
      );
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
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
    if (!_reportedAdminIssue &&
        trimmed.toLowerCase().contains('access is denied')) {
      _reportedAdminIssue = true;
      if (!_statusController.isClosed) {
        _statusController.add({
          'type': 'alert',
          'message':
              'Windows не дал доступ к TUN. Запусти Yurich Connect от имени администратора или переустанови свежий установщик.',
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

  Future<void> _writeLogFile(String fileName, String message) async {
    try {
      final base = await _configDir();
      final dir = Directory('${base.path}\\logs');
      await dir.create(recursive: true);
      final file = File('${dir.path}\\$fileName');
      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$timestamp] $message${Platform.lineTerminator}',
        mode: FileMode.append,
        encoding: utf8,
        flush: false,
      );
    } on Object {
      // File logging must never break the VPN control flow.
    }
  }

  String _redactSensitive(String value) {
    return SecretRedactor.redact(value);
  }

  void _startTrafficTicker() {
    _stopTrafficTicker();
    _sessionTotalBytes = 0;
    _emitTraffic(0, 0);
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
      await Future<void>.delayed(const Duration(milliseconds: 650));
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
    if (await File('${bundledRuntime.path}\\sing-box.exe').exists()) {
      return bundledRuntime;
    }

    final projectRuntime = Directory('assets\\windows\\sing-box');
    if (await File('${projectRuntime.path}\\sing-box.exe').exists()) {
      return projectRuntime.absolute;
    }

    throw StateError(
      'Windows runtime не найден. Нужны sing-box.exe и wintun.dll.',
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
