import 'dart:convert';
import 'dart:io';

class WindowsUpdateInfo {
  const WindowsUpdateInfo({
    required this.message,
    this.latestVersion,
    this.releaseUrl,
    this.available = false,
  });

  final String message;
  final String? latestVersion;
  final Uri? releaseUrl;
  final bool available;
}

class WindowsIntegrationService {
  static const githubOwner = 'ivan-yurich';
  static const githubRepo = 'aurum-vpn';
  static const releasesUrl =
      'https://github.com/$githubOwner/$githubRepo/releases';
  static final latestReleaseApi = Uri.https(
    'api.github.com',
    '/repos/$githubOwner/$githubRepo/releases/latest',
  );

  static const _taskName = 'Aurum VPN';

  Future<bool> isAutoStartEnabled() async {
    if (!Platform.isWindows) {
      return false;
    }
    final result = await Process.run('schtasks', ['/Query', '/TN', _taskName]);
    return result.exitCode == 0;
  }

  Future<void> setAutoStart(bool enabled) async {
    if (!Platform.isWindows) {
      return;
    }

    if (!enabled) {
      final result = await Process.run('schtasks', [
        '/Delete',
        '/TN',
        _taskName,
        '/F',
      ]);
      if (result.exitCode != 0 && !await isAutoStartEnabled()) {
        return;
      }
      return;
    }

    final executable = Platform.resolvedExecutable;
    final command = '"$executable"';
    final result = await Process.run('schtasks', [
      '/Create',
      '/TN',
      _taskName,
      '/TR',
      command,
      '/SC',
      'ONLOGON',
      '/RL',
      'HIGHEST',
      '/F',
    ]);
    if (result.exitCode != 0) {
      final error = '${result.stderr}'.trim();
      throw StateError(
        error.isEmpty ? 'Could not create startup task.' : error,
      );
    }
  }

  Future<WindowsUpdateInfo> checkForUpdate(String currentVersion) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(latestReleaseApi);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'AurumVPN/$currentVersion',
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
