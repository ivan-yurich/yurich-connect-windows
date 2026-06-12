import 'dart:convert';
import 'dart:io';

import '../branding.dart';

class WindowsUpdateInfo {
  const WindowsUpdateInfo({
    required this.message,
    this.currentVersion,
    this.latestVersion,
    this.releaseUrl,
    this.installerUrl,
    this.installerName,
    this.installerSize,
    this.available = false,
    this.latestIsOlder = false,
  });

  final String message;
  final String? currentVersion;
  final String? latestVersion;
  final Uri? releaseUrl;
  final Uri? installerUrl;
  final String? installerName;
  final int? installerSize;
  final bool available;
  final bool latestIsOlder;

  bool get canInstall => available && installerUrl != null;
}

class WindowsIntegrationService {
  static const githubOwner = 'ivan-yurich';
  static const githubRepo = 'yurich-connect-windows';
  static const releasesUrl =
      'https://github.com/$githubOwner/$githubRepo/releases';
  static final latestReleaseApi = Uri.https(
    'api.github.com',
    '/repos/$githubOwner/$githubRepo/releases/latest',
  );

  static const _taskName = YurichBranding.appName;
  static const _legacyTaskName = 'Aurum VPN';
  static const _startupDelayIso8601 = 'PT0S';

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
        await setAutoStart(true, requestElevation: false);
      } on Object {
        // The app may be opened without elevation. In that case the UI should
        // keep working and let the user reinstall or toggle startup later.
      }
    }

    final legacyXml = await _queryTaskXml(_legacyTaskName);
    if (legacyXml != null && isAutoStartTaskInstalledXml(legacyXml)) {
      try {
        await setAutoStart(true, requestElevation: false);
      } on Object {
        // Same best-effort behavior as the regular startup repair.
      }
    }
  }

  Future<bool> isCurrentProcessElevated() async {
    if (!Platform.isWindows) {
      return true;
    }
    return _isCurrentProcessElevated();
  }

  Future<bool> restartCurrentProcessAsAdministrator() async {
    if (!Platform.isWindows) {
      return false;
    }

    final executable = Platform.resolvedExecutable;
    final workingDirectory = File(executable).parent.path;
    final exe = _quotePowerShell(executable);
    final directory = _quotePowerShell(workingDirectory);
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '''
\$ErrorActionPreference = 'Stop'
try {
  Start-Process -FilePath $exe -WorkingDirectory $directory -Verb RunAs | Out-Null
  exit 0
} catch {
  Write-Error \$_.Exception.Message
  exit 1
}
''',
    ]).timeout(const Duration(seconds: 20));

    return result.exitCode == 0;
  }

  Future<void> setAutoStart(
    bool enabled, {
    bool requestElevation = true,
  }) async {
    if (!Platform.isWindows) {
      return;
    }

    if (!enabled) {
      await _runStartupTaskScript(
        _deleteStartupTaskScript(),
        requestElevation: requestElevation,
      );
      return;
    }

    final executable = Platform.resolvedExecutable;
    await _runStartupTaskScript(
      _createStartupTaskScript(executable),
      requestElevation: requestElevation,
    );
  }

  Future<void> _runStartupTaskScript(
    String script, {
    required bool requestElevation,
  }) async {
    final elevated = await _isCurrentProcessElevated();
    final wrappedScript = _wrapPowerShellScript(script);
    if (elevated) {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        wrappedScript,
      ]).timeout(const Duration(seconds: 45));
      if (result.exitCode != 0) {
        final error = '${result.stderr}${result.stdout}'.trim();
        throw StateError(
          error.isEmpty ? 'Could not update startup task.' : error,
        );
      }
      return;
    }

    if (!requestElevation) {
      throw StateError('Administrator rights are required.');
    }

    await _runPowerShellScriptAsAdmin(script);
  }

  Future<void> _runPowerShellScriptAsAdmin(String script) async {
    final dir = Directory('${Directory.systemTemp.path}\\YurichConnect');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(
      '${dir.path}\\startup_${DateTime.now().millisecondsSinceEpoch}.ps1',
    );
    await file.writeAsString(_wrapPowerShellScript(script), flush: true);
    try {
      final filePath = _quotePowerShell(file.path);
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '''
\$ErrorActionPreference = 'Stop'
\$process = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$filePath) -Verb RunAs -Wait -PassThru
if (\$null -eq \$process) { exit 1 }
exit \$process.ExitCode
''',
      ]);
      if (result.exitCode != 0) {
        final error = '${result.stderr}${result.stdout}'.trim();
        throw StateError(
          error.isEmpty
              ? 'Windows UAC did not allow startup task update.'
              : error,
        );
      }
    } finally {
      try {
        await file.delete();
      } on Object {
        // Best effort cleanup.
      }
    }
  }

  Future<bool> _isCurrentProcessElevated() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '''
\$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
\$principal = [Security.Principal.WindowsPrincipal]::new(\$identity)
\$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
''',
    ]);
    if (result.exitCode != 0) {
      return false;
    }
    return '${result.stdout}'.trim().toLowerCase() == 'true';
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

      final versionComparison = compareReleaseVersions(tag, currentVersion);
      final available = versionComparison > 0;
      final latestIsOlder = versionComparison < 0;
      return WindowsUpdateInfo(
        available: available,
        latestIsOlder: latestIsOlder,
        currentVersion: currentVersion,
        latestVersion: tag,
        releaseUrl: htmlUrl == null || htmlUrl.isEmpty
            ? null
            : Uri.parse(htmlUrl),
        installerUrl: installerAsset?.downloadUrl,
        installerName: installerAsset?.name,
        installerSize: installerAsset?.size,
        message: available
            ? 'Update available: $tag'
            : latestIsOlder
            ? 'Installed build $currentVersion is newer than GitHub latest $tag.'
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

    final helper = File(
      '${installer.parent.path}\\run_yurich_connect_update_${DateTime.now().millisecondsSinceEpoch}.ps1',
    );
    await helper.writeAsString('''
param(
  [Parameter(Mandatory = \$true)]
  [string]\$Installer,
  [Parameter(Mandatory = \$true)]
  [int]\$AppPid
)

\$ErrorActionPreference = 'Stop'
try {
  \$app = Get-Process -Id \$AppPid -ErrorAction SilentlyContinue
  if (\$null -ne \$app) {
    Wait-Process -Id \$AppPid -Timeout 30 -ErrorAction SilentlyContinue
  }
} catch {
  # If the old app already exited, continue with the installer.
}
Start-Sleep -Milliseconds 700
\$workingDirectory = Split-Path -Parent \$Installer
\$setup = Start-Process -FilePath \$Installer -WorkingDirectory \$workingDirectory -Verb RunAs -Wait -PassThru
try {
  Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
} catch {
  # Cleanup is best-effort.
}
if (\$null -eq \$setup) { exit 1 }
exit \$setup.ExitCode
''', flush: true);

    final helperPath = _quotePowerShell(helper.path);
    final installerPath = _quotePowerShell(installer.path);
    final workingDirectory = _quotePowerShell(installer.parent.path);
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '''
\$ErrorActionPreference = 'Stop'
Start-Process -FilePath powershell.exe -WorkingDirectory $workingDirectory -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helperPath,'-Installer',$installerPath,'-AppPid','$pid') | Out-Null
''',
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

  static String _wrapPowerShellScript(String script) {
    return '''
\$ErrorActionPreference = 'Stop'
try {
$script
  exit 0
} catch {
  \$message = \$_.Exception.Message
  if ([string]::IsNullOrWhiteSpace(\$message)) {
    \$message = \$_.Exception.ToString()
  }
  Write-Output \$message
  exit 1
}
''';
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

  static String _deleteStartupTaskScript() {
    final taskName = _quotePowerShell(_taskName);
    final legacyTaskName = _quotePowerShell(_legacyTaskName);
    return '''
\$taskName = $taskName
\$legacyTaskName = $legacyTaskName
& schtasks.exe /Delete /TN \$taskName /F 2>\$null | Out-Null
& schtasks.exe /Delete /TN \$legacyTaskName /F 2>\$null | Out-Null
''';
  }

  static String _createStartupTaskScript(String executable) {
    final taskName = _quotePowerShell(_taskName);
    final legacyTaskName = _quotePowerShell(_legacyTaskName);
    final exe = _quotePowerShell(executable);
    final workingDirectory = _quotePowerShell(File(executable).parent.path);
    return '''
\$taskName = $taskName
\$legacyTaskName = $legacyTaskName
\$exePath = $exe
\$workingDirectory = $workingDirectory
function Escape-Xml([string]\$Value) {
  return [System.Security.SecurityElement]::Escape(\$Value)
}
\$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
\$exeXml = Escape-Xml \$exePath
\$workingDirectoryXml = Escape-Xml \$workingDirectory
\$xmlPath = Join-Path \$env:TEMP ("YurichConnectStartup_" + [guid]::NewGuid().ToString("N") + ".xml")
\$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Yurich Connect</Author>
    <Description>Starts Yurich Connect with highest available privileges at Windows logon.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>\$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>\$exeXml</Command>
      <WorkingDirectory>\$workingDirectoryXml</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
try {
  Set-Content -LiteralPath \$xmlPath -Value \$xml -Encoding Unicode
  \$createOutput = & schtasks.exe /Create /TN \$taskName /XML \$xmlPath /F 2>&1
  if (\$LASTEXITCODE -ne 0) {
    throw "schtasks /Create failed (\$LASTEXITCODE): \$(\$createOutput -join [Environment]::NewLine)"
  }
  \$queryOutput = & schtasks.exe /Query /TN \$taskName /XML 2>&1
  if (\$LASTEXITCODE -ne 0) {
    throw "schtasks /Query failed (\$LASTEXITCODE): \$(\$queryOutput -join [Environment]::NewLine)"
  }
  \$queryText = \$queryOutput -join [Environment]::NewLine
  if (\$queryText -notmatch '<RunLevel>HighestAvailable</RunLevel>') {
    throw 'Startup task was created without HighestAvailable run level.'
  }
  if (\$queryText -notmatch '<WorkingDirectory>') {
    throw 'Startup task was created without working directory.'
  }
  & schtasks.exe /Delete /TN \$legacyTaskName /F 2>\$null | Out-Null
} finally {
  Remove-Item -LiteralPath \$xmlPath -Force -ErrorAction SilentlyContinue
}
''';
  }

  static bool isAutoStartTaskInstalledXml(String xml) {
    final normalized = xml.toLowerCase();
    return normalized.contains('<runlevel>highestavailable</runlevel>');
  }

  static bool isAutoStartTaskHealthyXml(String xml) {
    final normalized = xml.toLowerCase();
    final delays =
        RegExp(r'<delay>\s*([^<]+?)\s*</delay>', caseSensitive: false)
            .allMatches(normalized)
            .map((match) => (match[1] ?? '').trim())
            .where((delay) => delay.isNotEmpty);
    final hasUnsupportedDelay = delays.any(
      (delay) => delay != _startupDelayIso8601.toLowerCase(),
    );
    return isAutoStartTaskInstalledXml(xml) &&
        !hasUnsupportedDelay &&
        normalized.contains('<workingdirectory>') &&
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
