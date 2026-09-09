import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../branding.dart';
import 'sing_box_config_builder.dart';
import 'windows_update_integrity.dart';

class WindowsUpdateInfo {
  const WindowsUpdateInfo({
    required this.message,
    this.currentVersion,
    this.latestVersion,
    this.releaseUrl,
    this.installerUrl,
    this.installerName,
    this.installerSize,
    this.installerSha256,
    this.installerChecksumUrl,
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
  final String? installerSha256;
  final Uri? installerChecksumUrl;
  final bool available;
  final bool latestIsOlder;

  bool get canInstall =>
      available &&
      installerUrl != null &&
      (WindowsUpdateIntegrity.normalizeSha256(installerSha256) != null ||
          installerChecksumUrl != null);
}

class VerifiedWindowsInstaller {
  const VerifiedWindowsInstaller({
    required this.file,
    required this.sha256,
    this.signerThumbprint,
  });

  final File file;
  final String sha256;
  final String? signerThumbprint;
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
  static final latestReleaseWeb = Uri.https(
    'github.com',
    '/$githubOwner/$githubRepo/releases/latest',
  );
  static final latestReleaseAtom = Uri.https(
    'github.com',
    '/$githubOwner/$githubRepo/releases.atom',
  );

  static const _taskName = YurichBranding.appName;
  static const _legacyTaskName = 'Aurum VPN';
  static const _runKeyPath =
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _internetSettingsKey =
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _proxyBackupEnableName = 'YurichConnectProxyBackupEnable';
  static const _proxyBackupServerName = 'YurichConnectProxyBackupServer';
  static const _systemProxyServer =
      'http=127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort};'
      'https=127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort};'
      'socks=127.0.0.1:${SingBoxConfigBuilder.localSocksProxyPort}';

  Future<bool> isAutoStartEnabled() async {
    if (!Platform.isWindows) {
      return false;
    }
    if (await isEarlyAutoStartEnabled()) {
      return true;
    }
    final command = await _readAutoStartRunValue();
    if (command == null || command.isEmpty) {
      return false;
    }
    return _normalizedAutoStartCommand(
      command,
    ).contains(_normalizedAutoStartCommand(Platform.resolvedExecutable));
  }

  Future<bool> isEarlyAutoStartEnabled() async {
    if (!Platform.isWindows) {
      return false;
    }
    final taskXml = await _queryTaskXml(_taskName);
    return taskXml != null && isAutoStartTaskHealthyXml(taskXml);
  }

  Future<void> repairAutoStartIfNeeded() async {
    if (!Platform.isWindows) {
      return;
    }

    final currentXml = await _queryTaskXml(_taskName);
    if (currentXml != null && isAutoStartTaskHealthyXml(currentXml)) {
      return;
    }
    final legacyXml = await _queryTaskXml(_legacyTaskName);
    final hasLegacyTask =
        (currentXml != null && isAutoStartTaskInstalledXml(currentXml)) ||
        (legacyXml != null && isAutoStartTaskInstalledXml(legacyXml));
    if (hasLegacyTask) {
      try {
        await setAutoStart(true, requestElevation: false);
      } on Object {
        // Best-effort migration: the app should keep working even if Windows
        // denies removal of an old elevated scheduled task.
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

  Future<bool> setAutoStart(
    bool enabled, {
    bool requestElevation = true,
  }) async {
    if (!Platform.isWindows) {
      return false;
    }

    if (!enabled) {
      await _deleteAutoStartRunValue();
      await _deleteStartupTasks(requestElevation: requestElevation);
      return false;
    }

    final executable = Platform.resolvedExecutable;
    await _writeAutoStartRunValue(executable);
    final taskInstalled = await _registerEarlyAutoStartTask(
      executable,
      requestElevation: requestElevation,
    );
    if (taskInstalled) {
      await _deleteAutoStartRunValue();
      await _deleteLegacyStartupTaskOnly();
    }
    return taskInstalled;
  }

  Future<bool> isSystemProxyEnabled() async {
    if (!Platform.isWindows) {
      return false;
    }
    final script =
        '''
\$enable = Get-ItemPropertyValue -Path ${_quotePowerShell(_internetSettingsKey)} -Name ProxyEnable -ErrorAction SilentlyContinue
\$server = Get-ItemPropertyValue -Path ${_quotePowerShell(_internetSettingsKey)} -Name ProxyServer -ErrorAction SilentlyContinue
Write-Output "\$enable|\$server"
''';
    final ProcessResult result;
    try {
      result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 8),
      );
    } on Object {
      return false;
    }
    if (result.exitCode != 0) {
      return false;
    }
    final text = '${result.stdout}'.trim();
    final separator = text.indexOf('|');
    if (separator < 0) {
      return false;
    }
    final enabled = text.substring(0, separator).trim() == '1';
    final server = text.substring(separator + 1).trim();
    return enabled && server == _systemProxyServer;
  }

  Future<void> setSystemProxyEnabled(bool enabled) async {
    if (!Platform.isWindows) {
      return;
    }
    final key = _quotePowerShell(_internetSettingsKey);
    final server = _quotePowerShell(_systemProxyServer);
    final backupEnable = _quotePowerShell(_proxyBackupEnableName);
    final backupServer = _quotePowerShell(_proxyBackupServerName);
    final script = enabled
        ? '''
New-Item -Path $key -Force | Out-Null
\$currentEnable = Get-ItemPropertyValue -Path $key -Name ProxyEnable -ErrorAction SilentlyContinue
\$currentServer = Get-ItemPropertyValue -Path $key -Name ProxyServer -ErrorAction SilentlyContinue
if (\$currentServer -ne $server) {
  \$currentEnableValue = 0
  if (\$null -ne \$currentEnable) { \$currentEnableValue = [int]\$currentEnable }
  New-ItemProperty -Path $key -Name $backupEnable -PropertyType DWord -Value \$currentEnableValue -Force | Out-Null
  if (\$null -ne \$currentServer) {
    New-ItemProperty -Path $key -Name $backupServer -PropertyType String -Value \$currentServer -Force | Out-Null
  } else {
    Remove-ItemProperty -Path $key -Name $backupServer -Force -ErrorAction SilentlyContinue
  }
}
New-ItemProperty -Path $key -Name ProxyEnable -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $key -Name ProxyServer -PropertyType String -Value $server -Force | Out-Null
'''
        : '''
New-Item -Path $key -Force | Out-Null
\$backupEnableValue = Get-ItemPropertyValue -Path $key -Name $backupEnable -ErrorAction SilentlyContinue
\$backupServerValue = Get-ItemPropertyValue -Path $key -Name $backupServer -ErrorAction SilentlyContinue
if (\$null -ne \$backupEnableValue) {
  New-ItemProperty -Path $key -Name ProxyEnable -PropertyType DWord -Value ([int]\$backupEnableValue) -Force | Out-Null
} else {
  New-ItemProperty -Path $key -Name ProxyEnable -PropertyType DWord -Value 0 -Force | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace([string]\$backupServerValue)) {
  New-ItemProperty -Path $key -Name ProxyServer -PropertyType String -Value \$backupServerValue -Force | Out-Null
} else {
  Remove-ItemProperty -Path $key -Name ProxyServer -Force -ErrorAction SilentlyContinue
}
Remove-ItemProperty -Path $key -Name $backupEnable -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $key -Name $backupServer -Force -ErrorAction SilentlyContinue
''';
    final result = await _runPowerShell(
      '${_proxyChangeType()}\n$script\n${_notifyProxyChangedScript()}',
      timeout: const Duration(seconds: 12),
    );
    if (result.exitCode != 0) {
      final error = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not update Windows system proxy.' : error,
      );
    }
  }

  Future<bool> _isCurrentProcessElevated() async {
    try {
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
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) {
        return false;
      }
      return '${result.stdout}'.trim().toLowerCase() == 'true';
    } on Object {
      return false;
    }
  }

  Future<WindowsUpdateInfo> checkForUpdate(String currentVersion) async {
    final errors = <String>[];
    for (final viaLocalProxy in const [false, true]) {
      try {
        return await _checkForUpdateViaApi(
          currentVersion,
          viaLocalProxy: viaLocalProxy,
        );
      } on _TransientUpdateException catch (error) {
        errors.add('${_updateRouteLabel(viaLocalProxy)}: ${error.message}');
      } on Object catch (error) {
        errors.add('${_updateRouteLabel(viaLocalProxy)}: $error');
      }
    }

    for (final viaLocalProxy in const [false, true]) {
      try {
        return await _checkForUpdateViaAtom(
          currentVersion,
          viaLocalProxy: viaLocalProxy,
        );
      } on Object catch (error) {
        errors.add('${_updateRouteLabel(viaLocalProxy)} atom: $error');
      }
    }

    for (final viaLocalProxy in const [false, true]) {
      try {
        return await _checkForUpdateViaWeb(
          currentVersion,
          viaLocalProxy: viaLocalProxy,
        );
      } on Object catch (error) {
        errors.add('${_updateRouteLabel(viaLocalProxy)} web: $error');
      }
    }

    final details = errors.take(3).join('; ');
    return WindowsUpdateInfo(
      message: details.isEmpty
          ? 'GitHub is temporarily unavailable. Try again later.'
          : 'GitHub is temporarily unavailable. Try again later. Details: $details',
    );
  }

  Future<WindowsUpdateInfo> _checkForUpdateViaApi(
    String currentVersion, {
    required bool viaLocalProxy,
  }) async {
    final client = _githubHttpClient(viaLocalProxy: viaLocalProxy);
    try {
      final request = await client.getUrl(latestReleaseApi);
      _setGitHubHeaders(request, currentVersion);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.notFound) {
        return const WindowsUpdateInfo(
          message: 'GitHub releases are not published yet.',
        );
      }
      if (response.statusCode >= 500 && response.statusCode < 600) {
        throw _TransientUpdateException(
          'GitHub API HTTP ${response.statusCode}',
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
      final assets = json['assets'];
      final installerAsset = _findInstallerAsset(assets);
      final checksumAsset = _findInstallerChecksumAsset(
        assets,
        installerAsset?.name,
      );
      if (tag == null || tag.isEmpty) {
        return const WindowsUpdateInfo(message: 'Latest release has no tag.');
      }

      return _buildUpdateInfo(
        currentVersion: currentVersion,
        tag: tag,
        releaseUrl: htmlUrl == null || htmlUrl.isEmpty
            ? null
            : Uri.parse(htmlUrl),
        installerAsset: installerAsset,
        checksumAsset: checksumAsset,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<WindowsUpdateInfo> _checkForUpdateViaWeb(
    String currentVersion, {
    required bool viaLocalProxy,
  }) async {
    final client = _githubHttpClient(viaLocalProxy: viaLocalProxy);
    try {
      final request = await client.getUrl(latestReleaseWeb);
      request.followRedirects = false;
      _setGitHubHeaders(request, currentVersion);
      request.headers.set(HttpHeaders.acceptHeader, 'text/html, */*');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 500 && response.statusCode < 600) {
        throw _TransientUpdateException(
          'GitHub web HTTP ${response.statusCode}',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw StateError('GitHub web returned HTTP ${response.statusCode}.');
      }

      final location = response.headers.value(HttpHeaders.locationHeader);
      final tag = releaseTagFromLocation(location) ?? releaseTagFromHtml(body);
      if (tag == null || tag.isEmpty) {
        throw StateError('GitHub web latest page has no release tag.');
      }

      final releaseUrl = Uri.https(
        'github.com',
        '/$githubOwner/$githubRepo/releases/tag/$tag',
      );
      final installerUrl = Uri.https(
        'github.com',
        '/$githubOwner/$githubRepo/releases/download/$tag/YurichConnect_Setup.exe',
      );
      final checksumUrl = Uri.https(
        'github.com',
        '/$githubOwner/$githubRepo/releases/download/$tag/YurichConnect_Setup.exe.sha256',
      );
      return _buildUpdateInfo(
        currentVersion: currentVersion,
        tag: tag,
        releaseUrl: releaseUrl,
        installerAsset: _ReleaseAsset(
          name: 'YurichConnect_Setup.exe',
          downloadUrl: installerUrl,
          size: null,
        ),
        checksumAsset: _ReleaseAsset(
          name: 'YurichConnect_Setup.exe.sha256',
          downloadUrl: checksumUrl,
          size: null,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<WindowsUpdateInfo> _checkForUpdateViaAtom(
    String currentVersion, {
    required bool viaLocalProxy,
  }) async {
    final client = _githubHttpClient(viaLocalProxy: viaLocalProxy);
    try {
      final request = await client.getUrl(latestReleaseAtom);
      _setGitHubHeaders(request, currentVersion);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/atom+xml, application/xml, text/xml, */*',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 500 && response.statusCode < 600) {
        throw _TransientUpdateException(
          'GitHub atom HTTP ${response.statusCode}',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('GitHub atom returned HTTP ${response.statusCode}.');
      }

      final tag = releaseTagFromAtom(body);
      if (tag == null || tag.isEmpty) {
        throw StateError('GitHub atom feed has no release tag.');
      }

      final releaseUrl = Uri.https(
        'github.com',
        '/$githubOwner/$githubRepo/releases/tag/$tag',
      );
      final installerUrl = Uri.https(
        'github.com',
        '/$githubOwner/$githubRepo/releases/download/$tag/YurichConnect_Setup.exe',
      );
      final checksumUrl = Uri.https(
        'github.com',
        '/$githubOwner/$githubRepo/releases/download/$tag/YurichConnect_Setup.exe.sha256',
      );
      return _buildUpdateInfo(
        currentVersion: currentVersion,
        tag: tag,
        releaseUrl: releaseUrl,
        installerAsset: _ReleaseAsset(
          name: 'YurichConnect_Setup.exe',
          downloadUrl: installerUrl,
          size: null,
        ),
        checksumAsset: _ReleaseAsset(
          name: 'YurichConnect_Setup.exe.sha256',
          downloadUrl: checksumUrl,
          size: null,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  WindowsUpdateInfo _buildUpdateInfo({
    required String currentVersion,
    required String tag,
    required Uri? releaseUrl,
    required _ReleaseAsset? installerAsset,
    _ReleaseAsset? checksumAsset,
  }) {
    final versionComparison = compareReleaseVersions(tag, currentVersion);
    final available = versionComparison > 0;
    final latestIsOlder = versionComparison < 0;
    return WindowsUpdateInfo(
      available: available,
      latestIsOlder: latestIsOlder,
      currentVersion: currentVersion,
      latestVersion: tag,
      releaseUrl: releaseUrl,
      installerUrl: installerAsset?.downloadUrl,
      installerName: installerAsset?.name,
      installerSize: installerAsset?.size,
      installerSha256: WindowsUpdateIntegrity.normalizeSha256(
        installerAsset?.digest,
      ),
      installerChecksumUrl: checksumAsset?.downloadUrl,
      message: available
          ? 'Update available: $tag'
          : latestIsOlder
          ? 'Installed build $currentVersion is newer than GitHub latest $tag.'
          : 'You are up to date: $tag',
    );
  }

  Future<VerifiedWindowsInstaller> downloadInstaller(
    WindowsUpdateInfo update,
  ) async {
    if (update.installerUrl == null) {
      throw StateError('Latest release has no Windows installer asset.');
    }
    if (!isTrustedReleaseDownloadUrl(
      update.installerUrl!,
      expectedTag: update.latestVersion,
    )) {
      throw StateError('The update installer URL is not trusted.');
    }
    final expectedSha256 = await _resolveInstallerSha256(update);

    final safeVersion = (update.latestVersion ?? 'latest').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]+'),
      '_',
    );
    final fileName = update.installerName ?? 'YurichConnect_Setup.exe';
    final target = File(
      '${Directory.systemTemp.path}\\YurichConnect_Update_$safeVersion\\$fileName',
    );
    final partial = File('${target.path}.download');
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }

    if (await _isValidDownloadedInstaller(
      target,
      update.installerSize,
      expectedSha256,
    )) {
      return _verifyInstallerForLaunch(target, expectedSha256);
    }
    if (await target.exists()) {
      await target.delete();
    }

    final errors = <String>[];
    Future<File?> tryDownload(
      String label,
      Future<File> Function() action,
    ) async {
      try {
        if (await partial.exists()) {
          await partial.delete();
        }
        return await action();
      } on Object catch (error) {
        errors.add('$label: ${_shortUpdateError(error)}');
        try {
          if (await partial.exists()) {
            await partial.delete();
          }
        } on Object {
          // Best-effort cleanup of an incomplete update payload.
        }
        return null;
      }
    }

    for (final viaLocalProxy in const [false, true]) {
      final result = await tryDownload(
        'Dart ${_updateRouteLabel(viaLocalProxy)}',
        () => _downloadInstaller(
          update,
          target: target,
          partial: partial,
          viaLocalProxy: viaLocalProxy,
          expectedSha256: expectedSha256,
        ),
      );
      if (result != null) {
        return _verifyInstallerForLaunch(result, expectedSha256);
      }
    }

    if (Platform.isWindows) {
      for (final viaLocalProxy in const [false, true]) {
        final result = await tryDownload(
          'curl.exe ${_updateRouteLabel(viaLocalProxy)}',
          () => _downloadInstallerWithCurl(
            update,
            target: target,
            partial: partial,
            viaLocalProxy: viaLocalProxy,
            expectedSha256: expectedSha256,
          ),
        );
        if (result != null) {
          return _verifyInstallerForLaunch(result, expectedSha256);
        }
      }

      for (final viaLocalProxy in const [false, true]) {
        final result = await tryDownload(
          'PowerShell ${_updateRouteLabel(viaLocalProxy)}',
          () => _downloadInstallerWithPowerShell(
            update,
            target: target,
            partial: partial,
            viaLocalProxy: viaLocalProxy,
            expectedSha256: expectedSha256,
          ),
        );
        if (result != null) {
          return _verifyInstallerForLaunch(result, expectedSha256);
        }
      }
    }

    final details = errors.take(6).join('; ');
    throw StateError(
      details.isEmpty
          ? 'Could not download update installer.'
          : 'Could not download update installer. Tried ${errors.length} methods. $details',
    );
  }

  Future<String> _resolveInstallerSha256(WindowsUpdateInfo update) async {
    final fromApi = WindowsUpdateIntegrity.normalizeSha256(
      update.installerSha256,
    );
    if (fromApi != null) {
      return fromApi;
    }

    final checksumUrl = update.installerChecksumUrl;
    if (checksumUrl == null ||
        !isTrustedReleaseDownloadUrl(
          checksumUrl,
          expectedTag: update.latestVersion,
        )) {
      throw StateError(
        'The release has no trusted SHA-256 metadata. Open GitHub Releases and update manually.',
      );
    }
    final fileName = update.installerName ?? 'YurichConnect_Setup.exe';
    final errors = <String>[];
    for (final viaLocalProxy in const [false, true]) {
      try {
        final checksum = await _downloadChecksum(
          checksumUrl,
          fileName: fileName,
          viaLocalProxy: viaLocalProxy,
        );
        if (checksum != null) {
          return checksum;
        }
        errors.add(
          '${_updateRouteLabel(viaLocalProxy)}: invalid checksum file',
        );
      } on Object catch (error) {
        errors.add(
          '${_updateRouteLabel(viaLocalProxy)}: ${_shortUpdateError(error)}',
        );
      }
    }
    throw StateError(
      'Could not verify the release checksum. ${errors.take(2).join('; ')}',
    );
  }

  Future<String?> _downloadChecksum(
    Uri url, {
    required String fileName,
    required bool viaLocalProxy,
  }) async {
    final client = _githubHttpClient(viaLocalProxy: viaLocalProxy)
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'YurichConnect updater');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'GitHub checksum returned HTTP ${response.statusCode}.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.add(chunk);
        if (bytes.length > 64 * 1024) {
          throw StateError('GitHub checksum file is unexpectedly large.');
        }
      }
      final content = utf8.decode(bytes.takeBytes(), allowMalformed: false);
      return WindowsUpdateIntegrity.checksumForFile(content, fileName);
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _downloadInstaller(
    WindowsUpdateInfo update, {
    required File target,
    required File partial,
    required bool viaLocalProxy,
    required String expectedSha256,
  }) async {
    final url = update.installerUrl!;
    final client = _githubHttpClient(viaLocalProxy: viaLocalProxy)
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

      await response
          .pipe(partial.openWrite())
          .timeout(const Duration(minutes: 15));
      return await _finalizeDownloadedInstaller(
        target,
        partial,
        update.installerSize,
        expectedSha256,
      );
    } on Object {
      try {
        if (await partial.exists()) {
          await partial.delete();
        }
      } on Object {
        // Best-effort cleanup of an incomplete update payload.
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _downloadInstallerWithCurl(
    WindowsUpdateInfo update, {
    required File target,
    required File partial,
    required bool viaLocalProxy,
    required String expectedSha256,
  }) async {
    final args = <String>[
      '--fail',
      '--location',
      '--show-error',
      '--silent',
      '--connect-timeout',
      '30',
      '--max-time',
      '900',
      '--retry',
      '3',
      '--retry-delay',
      '2',
      '--retry-all-errors',
      '--tlsv1.2',
      '--proto',
      '=https',
      '--proto-redir',
      '=https',
      '--user-agent',
      'YurichConnect updater',
      '--output',
      partial.path,
    ];
    if (viaLocalProxy) {
      args.addAll([
        '--proxy',
        'http://127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
      ]);
    } else {
      args.addAll(['--noproxy', '*']);
    }
    args.add(update.installerUrl!.toString());

    final result = await Process.run(
      'curl.exe',
      args,
    ).timeout(const Duration(minutes: 16));
    if (result.exitCode != 0) {
      final output = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        output.isEmpty
            ? 'curl.exe exited with code ${result.exitCode}.'
            : 'curl.exe exited with code ${result.exitCode}: $output',
      );
    }
    return _finalizeDownloadedInstaller(
      target,
      partial,
      update.installerSize,
      expectedSha256,
    );
  }

  Future<File> _downloadInstallerWithPowerShell(
    WindowsUpdateInfo update, {
    required File target,
    required File partial,
    required bool viaLocalProxy,
    required String expectedSha256,
  }) async {
    final url = _quotePowerShell(update.installerUrl!.toString());
    final outFile = _quotePowerShell(partial.path);
    final proxy = viaLocalProxy
        ? "-Proxy ${_quotePowerShell('http://127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}')}"
        : '';
    final script =
        '''
\$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 900 -Headers @{ 'User-Agent' = 'YurichConnect updater' } $proxy
''';
    final result = await _runPowerShell(
      script,
      timeout: const Duration(minutes: 16),
    );
    if (result.exitCode != 0) {
      final output = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        output.isEmpty
            ? 'PowerShell downloader exited with code ${result.exitCode}.'
            : output,
      );
    }
    return _finalizeDownloadedInstaller(
      target,
      partial,
      update.installerSize,
      expectedSha256,
    );
  }

  Future<File> _finalizeDownloadedInstaller(
    File target,
    File partial,
    int? expectedSize,
    String expectedSha256,
  ) async {
    final actualSize = await partial.length();
    if (expectedSize != null && actualSize != expectedSize) {
      throw StateError(
        'Downloaded installer size mismatch: $actualSize of $expectedSize bytes.',
      );
    }
    if (actualSize < 1024 * 1024) {
      throw StateError('Downloaded installer is too small: $actualSize bytes.');
    }
    if (!await WindowsUpdateIntegrity.fileMatchesSha256(
      partial,
      expectedSha256,
    )) {
      throw StateError('Downloaded installer SHA-256 mismatch.');
    }
    if (await target.exists()) {
      await target.delete();
    }
    await partial.rename(target.path);
    return target;
  }

  Future<bool> _isValidDownloadedInstaller(
    File file,
    int? expectedSize,
    String expectedSha256,
  ) async {
    if (!await file.exists()) {
      return false;
    }
    final size = await file.length();
    if (size < 1024 * 1024) {
      return false;
    }
    if (expectedSize != null && size != expectedSize) {
      return false;
    }
    return WindowsUpdateIntegrity.fileMatchesSha256(file, expectedSha256);
  }

  Future<VerifiedWindowsInstaller> _verifyInstallerForLaunch(
    File installer,
    String expectedSha256,
  ) async {
    if (!await WindowsUpdateIntegrity.fileMatchesSha256(
      installer,
      expectedSha256,
    )) {
      throw StateError('The update installer failed SHA-256 verification.');
    }
    final currentSignature = await _readAuthenticode(
      File(Platform.resolvedExecutable),
    );
    final installerSignature = await _readAuthenticode(installer);
    final policyError = WindowsUpdateIntegrity.authenticodePolicyError(
      currentApp: currentSignature,
      installer: installerSignature,
    );
    if (policyError != null) {
      throw StateError(policyError);
    }
    return VerifiedWindowsInstaller(
      file: installer,
      sha256: expectedSha256,
      signerThumbprint: currentSignature.isValid
          ? currentSignature.thumbprint
          : null,
    );
  }

  Future<WindowsAuthenticodeInfo> _readAuthenticode(File file) async {
    final path = _quotePowerShell(file.path);
    final result = await _runPowerShell('''
\$signature = Get-AuthenticodeSignature -LiteralPath $path
\$thumbprint = ''
\$subject = ''
if (\$null -ne \$signature.SignerCertificate) {
  \$thumbprint = [string]\$signature.SignerCertificate.Thumbprint
  \$subject = [string]\$signature.SignerCertificate.Subject
}
[pscustomobject]@{
  status = [string]\$signature.Status
  thumbprint = \$thumbprint
  subject = \$subject
} | ConvertTo-Json -Compress
''', timeout: const Duration(seconds: 20));
    if (result.exitCode != 0) {
      final error = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        error.isEmpty
            ? 'Could not inspect the installer signature.'
            : 'Could not inspect the installer signature: $error',
      );
    }
    final parsed = WindowsUpdateIntegrity.parseAuthenticodeJson(
      '${result.stdout}',
    );
    if (parsed == null) {
      throw StateError('Windows returned invalid Authenticode information.');
    }
    return parsed;
  }

  HttpClient _githubHttpClient({required bool viaLocalProxy}) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (viaLocalProxy) {
      client.findProxy = (_) =>
          'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
    }
    return client;
  }

  void _setGitHubHeaders(HttpClientRequest request, String currentVersion) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'YurichConnect/$currentVersion',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
  }

  String _updateRouteLabel(bool viaLocalProxy) {
    return viaLocalProxy ? 'local VPN proxy' : 'direct';
  }

  String _shortUpdateError(Object error) {
    final text = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 260) {
      return text;
    }
    return '${text.substring(0, 260)}...';
  }

  Future<void> runInstallerAsAdmin(
    VerifiedWindowsInstaller verifiedInstaller,
  ) async {
    if (!Platform.isWindows) {
      return;
    }
    final installer = verifiedInstaller.file;
    if (!await installer.exists()) {
      throw StateError('Downloaded installer not found: ${installer.path}');
    }
    final reverified = await _verifyInstallerForLaunch(
      installer,
      verifiedInstaller.sha256,
    );
    if (verifiedInstaller.signerThumbprint != null &&
        reverified.signerThumbprint != verifiedInstaller.signerThumbprint) {
      throw StateError('The update signer changed before installation.');
    }
    final installerPath = _quotePowerShell(installer.path);
    final workingDirectory = _quotePowerShell(installer.parent.path);
    final expectedSha256 = _quotePowerShell(verifiedInstaller.sha256);
    final expectedSigner = _quotePowerShell(
      verifiedInstaller.signerThumbprint ?? '',
    );
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '''
\$ErrorActionPreference = 'Stop'
\$stream = [IO.File]::Open($installerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
  \$actualHash = (Get-FileHash -InputStream \$stream -Algorithm SHA256).Hash.ToLowerInvariant()
  if (\$actualHash -ne $expectedSha256) {
    throw 'Installer SHA-256 changed before launch.'
  }
  if (-not [string]::IsNullOrWhiteSpace($expectedSigner)) {
    \$signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    \$actualSigner = ''
    if (\$null -ne \$signature.SignerCertificate) {
      \$actualSigner = [string]\$signature.SignerCertificate.Thumbprint
    }
    if ([string]\$signature.Status -ne 'Valid' -or \$actualSigner -ine $expectedSigner) {
      throw 'Installer Authenticode signature changed before launch.'
    }
  }
  Start-Process -FilePath $installerPath -WorkingDirectory $workingDirectory -Verb RunAs | Out-Null
} finally {
  \$stream.Dispose()
}
''',
    ]).timeout(const Duration(seconds: 45));
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
    return null;
  }

  static _ReleaseAsset? _findInstallerChecksumAsset(
    Object? assets,
    String? installerName,
  ) {
    if (assets is! List || installerName == null || installerName.isEmpty) {
      return null;
    }
    final parsed = assets
        .whereType<Map>()
        .map((asset) => asset.cast<String, dynamic>())
        .map(_ReleaseAsset.fromJson)
        .whereType<_ReleaseAsset>()
        .toList();
    final sidecarName = '$installerName.sha256'.toLowerCase();
    for (final asset in parsed) {
      if (asset.name.toLowerCase() == sidecarName) {
        return asset;
      }
    }
    for (final asset in parsed) {
      if (asset.name.toLowerCase() == 'sha256sums.txt') {
        return asset;
      }
    }
    return null;
  }

  static String _quotePowerShell(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    return Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '''
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
''',
    ]).timeout(timeout);
  }

  Future<String?> _readAutoStartRunValue() async {
    final script =
        '''
\$value = Get-ItemPropertyValue -Path ${_quotePowerShell(_runKeyPath)} -Name ${_quotePowerShell(_taskName)} -ErrorAction SilentlyContinue
if (\$null -ne \$value) { Write-Output \$value }
''';
    final ProcessResult result;
    try {
      result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 8),
      );
    } on Object {
      return null;
    }
    if (result.exitCode != 0) {
      return null;
    }
    return '${result.stdout}'.trim();
  }

  Future<void> _writeAutoStartRunValue(String executable) async {
    final key = _quotePowerShell(_runKeyPath);
    final name = _quotePowerShell(_taskName);
    final value = _quotePowerShell('"$executable" --autostart');
    final script =
        '''
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name $name -PropertyType String -Value $value -Force | Out-Null
''';
    final result = await _runPowerShell(
      script,
      timeout: const Duration(seconds: 12),
    );
    if (result.exitCode != 0) {
      final error = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not update Windows startup.' : error,
      );
    }
  }

  Future<void> _deleteAutoStartRunValue() async {
    final script =
        '''
Remove-ItemProperty -Path ${_quotePowerShell(_runKeyPath)} -Name ${_quotePowerShell(_taskName)} -Force -ErrorAction SilentlyContinue
''';
    final result = await _runPowerShell(
      script,
      timeout: const Duration(seconds: 8),
    );
    if (result.exitCode != 0) {
      final error = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not remove Windows startup.' : error,
      );
    }
  }

  Future<bool> _registerEarlyAutoStartTask(
    String executable, {
    required bool requestElevation,
  }) async {
    final taskName = _quotePowerShell(_taskName);
    final command = _quotePowerShell(executable);
    final workingDirectory = _quotePowerShell(File(executable).parent.path);
    final script =
        '''
\$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
\$action = New-ScheduledTaskAction -Execute $command -Argument '--autostart' -WorkingDirectory $workingDirectory
\$trigger = New-ScheduledTaskTrigger -AtLogOn -User \$currentUser
\$principal = New-ScheduledTaskPrincipal -UserId \$currentUser -LogonType Interactive -RunLevel Highest
\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action \$action -Trigger \$trigger -Principal \$principal -Settings \$settings -Description 'Early startup for Yurich Connect' -Force | Out-Null
''';
    final elevated = await _isCurrentProcessElevated();
    final result = requestElevation && !elevated
        ? await _runPowerShellElevated(
            script,
            timeout: const Duration(seconds: 35),
          )
        : await _runPowerShell(script, timeout: const Duration(seconds: 20));
    if (result.exitCode != 0) {
      return false;
    }
    final xml = await _queryTaskXml(_taskName);
    return xml != null &&
        isAutoStartTaskHealthyXml(xml) &&
        _normalizedAutoStartCommand(
          xml,
        ).contains(_normalizedAutoStartCommand(executable));
  }

  Future<void> _deleteStartupTasks({required bool requestElevation}) async {
    final names = const [
      _taskName,
      _legacyTaskName,
    ].map(_quotePowerShell).join(', ');
    final script =
        '''
foreach (\$taskName in @($names)) {
  Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue
}
''';
    final elevated = await _isCurrentProcessElevated();
    final result = requestElevation && !elevated
        ? await _runPowerShellElevated(
            script,
            timeout: const Duration(seconds: 30),
          )
        : await _runPowerShell(script, timeout: const Duration(seconds: 15));
    if (result.exitCode != 0) {
      final error = '${result.stderr}${result.stdout}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not remove Windows startup task.' : error,
      );
    }
  }

  Future<void> _deleteLegacyStartupTaskOnly() async {
    try {
      await Process.run('schtasks', [
        '/Delete',
        '/TN',
        _legacyTaskName,
        '/F',
      ]).timeout(const Duration(seconds: 8));
    } on Object {
      // An obsolete elevated task can be removed on the next elevated change.
    }
  }

  Future<ProcessResult> _runPowerShellElevated(
    String script, {
    Duration timeout = const Duration(seconds: 35),
  }) {
    final wrapped =
        '''
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
    final utf16Le = <int>[];
    for (final codeUnit in wrapped.codeUnits) {
      utf16Le
        ..add(codeUnit & 0xff)
        ..add((codeUnit >> 8) & 0xff);
    }
    final encoded = base64Encode(utf16Le);
    final encodedLiteral = _quotePowerShell(encoded);
    return Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '''
\$process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedLiteral) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
exit \$process.ExitCode
''',
    ]).timeout(timeout);
  }

  static String _normalizedAutoStartCommand(String value) {
    return value.replaceAll('"', '').trim().replaceAll('/', '\\').toLowerCase();
  }

  static String _proxyChangeType() {
    return '''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class YurichWinInet {
  [DllImport("wininet.dll", SetLastError = true)]
  public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@
''';
  }

  static String _notifyProxyChangedScript() {
    return '''
[YurichWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[YurichWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''';
  }

  Future<String?> _queryTaskXml(String taskName) async {
    try {
      final result = await Process.run('schtasks', [
        '/Query',
        '/TN',
        taskName,
        '/XML',
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) {
        return null;
      }
      return '${result.stdout}${result.stderr}';
    } on Object {
      return null;
    }
  }

  static bool isAutoStartTaskInstalledXml(String xml) {
    final normalized = xml.toLowerCase();
    return normalized.contains('<runlevel>highestavailable</runlevel>');
  }

  static bool isAutoStartTaskHealthyXml(String xml) {
    final normalized = xml.toLowerCase();
    final delayMatch = RegExp(
      r'<delay>\s*([^<]+)\s*</delay>',
    ).firstMatch(normalized);
    final hasImmediateTrigger =
        normalized.contains('<logontrigger>') &&
        (delayMatch == null || delayMatch.group(1)?.trim() == 'pt0s');
    return hasImmediateTrigger &&
        normalized.contains('<logontype>interactivetoken</logontype>') &&
        normalized.contains('<runlevel>highestavailable</runlevel>') &&
        normalized.contains('<command>') &&
        normalized.contains('<workingdirectory>') &&
        normalized.contains('<arguments>--autostart</arguments>') &&
        normalized.contains(
          '<disallowstartifonbatteries>false</disallowstartifonbatteries>',
        ) &&
        normalized.contains(
          '<stopifgoingonbatteries>false</stopifgoingonbatteries>',
        ) &&
        normalized.contains('<startwhenavailable>true</startwhenavailable>') &&
        normalized.contains(
          '<multipleinstancespolicy>ignorenew</multipleinstancespolicy>',
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

  static String? releaseTagFromLocation(String? location) {
    if (location == null || location.trim().isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(location.trim());
    if (uri == null) {
      return null;
    }
    return _releaseTagFromPathSegments(uri.pathSegments);
  }

  static String? releaseTagFromHtml(String html) {
    final match = RegExp(
      "/ivan-yurich/yurich-connect-windows/releases/tag/([^\"'<>\\s?#]+)",
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) {
      return null;
    }
    return Uri.decodeComponent(match.group(1)!);
  }

  static String? releaseTagFromAtom(String atom) {
    final linkTag = releaseTagFromHtml(atom);
    if (linkTag != null) {
      return linkTag;
    }
    final idMatch = RegExp(
      r'<id>[^<]*/([^/<]+-windows)</id>',
      caseSensitive: false,
    ).firstMatch(atom);
    if (idMatch != null) {
      return Uri.decodeComponent(idMatch.group(1)!);
    }
    return null;
  }

  static bool isTrustedReleaseDownloadUrl(Uri uri, {String? expectedTag}) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final segments = uri.pathSegments;
    if (segments.length != 6) {
      return false;
    }
    if (segments[0].toLowerCase() != githubOwner ||
        segments[1].toLowerCase() != githubRepo ||
        segments[2].toLowerCase() != 'releases' ||
        segments[3].toLowerCase() != 'download' ||
        segments[4].trim().isEmpty ||
        (expectedTag != null && segments[4] != expectedTag)) {
      return false;
    }
    final assetName = segments[5].toLowerCase();
    return assetName == 'yurichconnect_setup.exe' ||
        assetName == 'yurichconnect_setup.exe.sha256' ||
        assetName == 'sha256sums.txt';
  }

  static String? _releaseTagFromPathSegments(List<String> segments) {
    for (var i = 0; i < segments.length - 2; i++) {
      if (segments[i] == 'releases' && segments[i + 1] == 'tag') {
        final tag = segments[i + 2].trim();
        return tag.isEmpty ? null : Uri.decodeComponent(tag);
      }
    }
    return null;
  }
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.digest,
  });

  final String name;
  final Uri downloadUrl;
  final int? size;
  final String? digest;

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
      digest: (json['digest'] as String?)?.trim(),
    );
  }
}

class _TransientUpdateException implements Exception {
  const _TransientUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
