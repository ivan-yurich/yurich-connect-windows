import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sing_box_config_builder.dart';
import 'vpn_engine.dart';

class WindowsSingBoxEngine implements VpnEngine {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final _trafficController = StreamController<Map<String, dynamic>>.broadcast();
  final _logController = StreamController<Map<String, dynamic>>.broadcast();
  final _logs = <String>[];

  Process? _process;
  Process? _naiveProcess;
  String _status = AurumVpnStatus.stopped;
  String _config = '{}';
  String? _naiveProxyConfig;
  String _notificationTitle = 'Aurum VPN';
  String _notificationDescription = 'VPN connection is active';
  Timer? _trafficTimer;
  WebSocket? _trafficSocket;
  bool _trafficSocketConnecting = false;
  bool _reportedAdminIssue = false;
  int _sessionTotalBytes = 0;

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
    if (_process == null && _status != AurumVpnStatus.stopped) {
      _setStatus(AurumVpnStatus.stopped);
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
      return true;
    }

    _setStatus(AurumVpnStatus.starting);
    _reportedAdminIssue = false;
    try {
      final runtimeDir = await _runtimeDir();
      final configDir = await _configDir();
      await _stopStaleRuntimeProcesses(runtimeDir);

      final configFile = File('${configDir.path}\\config.json');
      await configFile.writeAsString(_config, encoding: utf8);

      if (_naiveProxyConfig != null) {
        final started = await _startNaiveProxy(runtimeDir, configDir);
        if (!started) {
          _setStatus(AurumVpnStatus.stopped);
          return false;
        }
      }

      final exe = File('${runtimeDir.path}\\sing-box.exe');
      if (!await exe.exists()) {
        _appendLog('sing-box.exe не найден в ${runtimeDir.path}');
        _setStatus(AurumVpnStatus.stopped);
        return false;
      }
      if (!await _checkConfig(exe, configFile, runtimeDir)) {
        _setStatus(AurumVpnStatus.stopped);
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
      _pipeProcess(process);
      _startTrafficTicker();

      unawaited(
        process.exitCode.then((code) {
          _appendLog('sing-box exited with code $code');
          _process = null;
          _stopNaiveProxy();
          _stopTrafficTicker();
          if (_status != AurumVpnStatus.stopping) {
            _setStatus(AurumVpnStatus.stopped);
          }
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (_process == process) {
        _setStatus(AurumVpnStatus.started);
        return true;
      }
    } on Object catch (e) {
      _appendLog('Не удалось запустить sing-box: $e');
    }

    _stopNaiveProxy();
    _setStatus(AurumVpnStatus.stopped);
    return false;
  }

  @override
  Future<bool> stopVPN() async {
    final process = _process;
    if (process == null) {
      try {
        await _stopStaleRuntimeProcesses(await _runtimeDir());
      } on Object {
        // Best-effort cleanup for untracked processes after app restarts.
      }
      _setStatus(AurumVpnStatus.stopped);
      return true;
    }

    _setStatus(AurumVpnStatus.stopping);
    _appendLog('Stopping sing-box...');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    _process = null;
    _stopNaiveProxy();
    _stopTrafficTicker();
    _setStatus(AurumVpnStatus.stopped);
    return true;
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
    } on Object catch (e) {
      _appendLog('sing-box config check failed: $e');
    }
    return false;
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
        _appendLog('Stopped stale Aurum runtime processes: $stopped');
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
        .listen(_appendLog);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_appendLog);
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
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('naive: $line'));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('naive: $line'));

    unawaited(
      process.exitCode.then((code) {
        _appendLog('naive exited with code $code');
        if (_naiveProcess == process) {
          _naiveProcess = null;
        }
        if (_process != null && _status != AurumVpnStatus.stopping) {
          _appendLog('NaiveProxy core stopped while VPN was running.');
          _process?.kill();
        }
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 700));
    return _naiveProcess == process;
  }

  void _stopNaiveProxy() {
    final process = _naiveProcess;
    if (process == null) {
      return;
    }
    _appendLog('Stopping NaiveProxy core...');
    process.kill();
    _naiveProcess = null;
  }

  void _setStatus(String status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add({'status': status});
    }
  }

  void _appendLog(String message) {
    final trimmed = message.trim();
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
              'Windows не дал доступ к TUN. Запусти Aurum VPN от имени администратора или переустанови свежий установщик.',
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
        ? Directory('${Platform.environment['USERPROFILE']}\\.aurum_vpn')
        : Directory('$appData\\Aurum VPN');
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }
}
