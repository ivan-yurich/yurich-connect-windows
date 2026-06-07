import 'dart:convert';
import 'dart:io';

import '../branding.dart';

class WindowsUpdateInfo {
  const WindowsUpdateInfo({
    required this.message,
    this.latestVersion,
    this.releaseUrl,
    this.installerUrl,
    this.installerName,
    this.installerSize,
    this.available = false,
  });

  final String message;
  final String? latestVersion;
  final Uri? releaseUrl;
  final Uri? installerUrl;
  final String? installerName;
  final int? installerSize;
  final bool available;

  bool get canInstall => available && installerUrl != null;
}

class WindowsIntegrationService {
  static const githubOwner = 'ivan-yurich';
  static const githubRepo = 'aurum-vpn-windows';
  static const releasesUrl =
      'https://github.com/$githubOwner/$githubRepo/releases';
  static final latestReleaseApi = Uri.https(
    'api.github.com',
    '/repos/$githubOwner/$githubRepo/releases/latest',
  );

  static const _taskName = YurichBranding.appName;
  static const _legacyTaskName = 'Aurum VPN';
  static const _startupDelayIso8601 = 'PT5S';

  Future<bool> isAutoStartEnabled() async {
    if (!Platform.isWindows) {
      return false;
    }
    final xml =
        await _queryTaskXml(_taskName) ?? await _queryTaskXml(_legacyTaskName);
    return xml != null && isAutoStartTaskHealthyXml(xml);
  }

  Future<void> repairAutoStartIfNeeded() async {
    if (!Platform.isWindows) {
      return;
    }

    final currentXml = await _queryTaskXml(_taskName);
    if (currentXml != null &&
        isAutoStartTaskInstalledXml(currentXml) &&
        !isAutoStartTaskHealthyXml(currentXml)) {
      try {
        await setAutoStart(true);
      } on Object {
        // The app may be opened without elevation. In that case the UI should
        // keep working and let the user reinstall or toggle startup later.
      }
    }

    final legacyXml = await _queryTaskXml(_legacyTaskName);
    if (legacyXml != null && isAutoStartTaskInstalledXml(legacyXml)) {
      try {
        await setAutoStart(true);
      } on Object {
        // Same best-effort behavior as the regular startup repair.
      }
    }
  }

  Future<void> setAutoStart(bool enabled) async {
    if (!Platform.isWindows) {
      return;
    }

    if (!enabled) {
      final result = await _deleteTask(_taskName);
      await _deleteTask(_legacyTaskName);
      if (result.exitCode != 0 && !await isAutoStartEnabled()) {
        return;
      }
      return;
    }

    final executable = Platform.resolvedExecutable;
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      _createStartupTaskScript(executable),
    ]);
    if (result.exitCode != 0) {
      final error = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not create startup task.' : error,
      );
    }
    await _deleteTask(_legacyTaskName);
  }

  Future<WindowsUpdateInfo> checkForUpdate(String currentVersion) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(latestReleaseApi);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'YurichConnect/$currentVersion',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.notFound) {
        return const WindowsUpdateInfo(
          message: 'GitHub releases are not published yet.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return WindowsUpdateInfo(
          message: 'GitHub returned HTTP ${response.statusCode}.',
        );
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?)?.trim();
      final htmlUrl = (json['html_url'] as String?)?.trim();
      final installerAsset = _findInstallerAsset(json['assets']);
      if (tag == null || tag.isEmpty) {
        return const WindowsUpdateInfo(message: 'Latest release has no tag.');
      }

      final available = compareReleaseVersions(tag, currentVersion) > 0;
      return WindowsUpdateInfo(
        available: available,
        latestVersion: tag,
        releaseUrl: htmlUrl == null || htmlUrl.isEmpty
            ? null
            : Uri.parse(htmlUrl),
        installerUrl: installerAsset?.downloadUrl,
        installerName: installerAsset?.name,
        installerSize: installerAsset?.size,
        message: available
            ? 'Update available: $tag'
            : 'You are up to date: $tag',
      );
    } on Object catch (e) {
      return WindowsUpdateInfo(message: 'Update check failed: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<File> downloadInstaller(WindowsUpdateInfo update) async {
    final url = update.installerUrl;
    if (url == null) {
      throw StateError('Latest release has no Windows installer asset.');
    }

    final safeVersion = (update.latestVersion ?? 'latest').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]+'),
      '_',
    );
    final fileName = update.installerName ?? 'YurichConnect_Setup.exe';
    final target = File(
      '${Directory.systemTemp.path}\\YurichConnect_Update_$safeVersion\\$fileName',
    );
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'YurichConnect updater');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('GitHub asset returned HTTP ${response.statusCode}.');
      }

      await response.pipe(target.openWrite());
      return target;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> runInstallerAsAdmin(File installer) async {
    if (!Platform.isWindows) {
      return;
    }
    if (!await installer.exists()) {
      throw StateError('Downloaded installer not found: ${installer.path}');
    }

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Start-Process -FilePath ${_quotePowerShell(installer.path)} -Verb RunAs',
    ]);
    if (result.exitCode != 0) {
      final error = '${result.stderr}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not start updater as administrator.' : error,
      );
    }
  }

  static _ReleaseAsset? _findInstallerAsset(Object? assets) {
    if (assets is! List) {
      return null;
    }

    final parsed = assets
        .whereType<Map>()
        .map((asset) => asset.cast<String, dynamic>())
        .map(_ReleaseAsset.fromJson)
        .whereType<_ReleaseAsset>()
        .toList();
    for (final asset in parsed) {
      if (asset.name.toLowerCase() == 'yurichconnect_setup.exe') {
        return asset;
      }
    }
    for (final asset in parsed) {
      if (asset.name.toLowerCase() == 'aurumvpn_setup.exe') {
        return asset;
      }
    }
    for (final asset in parsed) {
      final name = asset.name.toLowerCase();
      if (name.endsWith('.exe') && name.contains('setup')) {
        return asset;
      }
    }
    return null;
  }

  static String _quotePowerShell(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  Future<String?> _queryTaskXml(String taskName) async {
    final result = await Process.run('schtasks', [
      '/Query',
      '/TN',
      taskName,
      '/XML',
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    return '${result.stdout}${result.stderr}';
  }

  Future<ProcessResult> _deleteTask(String taskName) {
    return Process.run('schtasks', ['/Delete', '/TN', taskName, '/F']);
  }

  static String _createStartupTaskScript(String executable) {
    final taskName = _quotePowerShell(_taskName);
    final exe = _quotePowerShell(executable);
    final delay = _quotePowerShell(_startupDelayIso8601);
    return '''
\$ErrorActionPreference = 'Stop'
\$action = New-ScheduledTaskAction -Execute $exe
\$trigger = New-ScheduledTaskTrigger -AtLogOn
\$trigger.Delay = $delay
\$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
\$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action \$action -Trigger \$trigger -Principal \$principal -Settings \$settings -Force | Out-Null
''';
  }

  static bool isAutoStartTaskInstalledXml(String xml) {
    final normalized = xml.toLowerCase();
    return normalized.contains('<runlevel>highestavailable</runlevel>');
  }

  static bool isAutoStartTaskHealthyXml(String xml) {
    final normalized = xml.toLowerCase();
    return isAutoStartTaskInstalledXml(xml) &&
        normalized.contains(
          '<delay>$_startupDelayIso8601</delay>'.toLowerCase(),
        ) &&
        !normalized.contains(
          '<disallowstartifonbatteries>true</disallowstartifonbatteries>',
        ) &&
        !normalized.contains(
          '<stopifgoingonbatteries>true</stopifgoingonbatteries>',
        );
  }

  static int compareReleaseVersions(String left, String right) {
    List<int> parse(String value) {
      final clean = value
          .trim()
          .replaceFirst(RegExp(r'^[vV]'), '')
          .split(RegExp(r'[+-]'))
          .first;
      return clean
          .split(RegExp(r'[^0-9]+'))
          .where((part) => part.isNotEmpty)
          .map((part) => int.tryParse(part) ?? 0)
          .toList();
    }

    final a = parse(left);
    final b = parse(right);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) {
        return av.compareTo(bv);
      }
    }
    return 0;
  }
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final Uri downloadUrl;
  final int? size;

  static _ReleaseAsset? fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?)?.trim();
    final url = (json['browser_download_url'] as String?)?.trim();
    if (name == null || name.isEmpty || url == null || url.isEmpty) {
      return null;
    }
    return _ReleaseAsset(
      name: name,
      downloadUrl: Uri.parse(url),
      size: (json['size'] as num?)?.round(),
    );
  }
}
