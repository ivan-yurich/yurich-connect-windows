import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/windows_sing_box_config_preparer.dart';

void main() {
  test('moves enabled sing-box cache to writable app data', () {
    const source = '''
{
  "experimental": {
    "cache_file": {"enabled": true},
    "clash_api": {"external_controller": "127.0.0.1:19090"}
  }
}
''';

    final prepared = WindowsSingBoxConfigPreparer.withWritableCachePath(
      source,
      cacheFilePath:
          r'C:\Users\test\AppData\Roaming\Yurich Connect\cache\sing-box.db',
    );
    final decoded = jsonDecode(prepared) as Map<String, dynamic>;
    final experimental = decoded['experimental'] as Map<String, dynamic>;
    final cacheFile = experimental['cache_file'] as Map<String, dynamic>;

    expect(cacheFile['enabled'], isTrue);
    expect(
      cacheFile['path'],
      r'C:\Users\test\AppData\Roaming\Yurich Connect\cache\sing-box.db',
    );
    expect(experimental['clash_api'], isNotNull);
  });

  test('does not enable cache when profile disabled it', () {
    const source = '{"experimental":{"cache_file":{"enabled":false}}}';

    final prepared = WindowsSingBoxConfigPreparer.withWritableCachePath(
      source,
      cacheFilePath: r'C:\temp\sing-box.db',
    );

    expect(prepared, source);
  });

  test('bundled sing-box creates cache at prepared writable path', () async {
    if (!Platform.isWindows) {
      return;
    }
    final executable = File('assets/windows/sing-box/sing-box.exe');
    expect(executable.existsSync(), isTrue);
    final tempDirectory = await Directory.systemTemp.createTemp(
      'yurich-sing-box-cache-test-',
    );
    Process? process;
    try {
      final cacheFile = File('${tempDirectory.path}\\cache\\sing-box.db');
      await cacheFile.parent.create(recursive: true);
      final source = jsonEncode({
        'log': {'level': 'error'},
        'inbounds': <Object>[],
        'outbounds': <Object>[],
        'experimental': {
          'cache_file': {'enabled': true},
        },
      });
      final config = WindowsSingBoxConfigPreparer.withWritableCachePath(
        source,
        cacheFilePath: cacheFile.path,
      );
      final configFile = File('${tempDirectory.path}\\config.json');
      await configFile.writeAsString(config, flush: true);

      process = await Process.start(
        executable.absolute.path,
        ['run', '-c', configFile.path],
        workingDirectory: executable.parent.absolute.path,
        runInShell: false,
      );
      final earlyExit = await process.exitCode.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () => -999,
      );
      expect(earlyExit, -999, reason: 'sing-box exited before startup canary');
      expect(cacheFile.existsSync(), isTrue);
    } finally {
      process?.kill(ProcessSignal.sigkill);
      try {
        await process?.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        // Best-effort test cleanup.
      }
      await tempDirectory.delete(recursive: true);
    }
  });
}
