import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/profile_importer.dart';
import 'package:yurich_connect_windows/src/services/xray_config_builder.dart';

void main() {
  Future<String> buildXhttpConfig() async {
    final link = Uri(
      scheme: 'vless',
      userInfo: '11111111-1111-4111-8111-111111111111',
      host: '203.0.113.10',
      port: 443,
      queryParameters: {
        'security': 'tls',
        'type': 'xhttp',
        'sni': 'sni.example.com',
        'host': 'host.example.com',
        'path': '/connect',
        'mode': 'packet-up',
        'extra': jsonEncode({
          'headers': {'X-Client': 'Yurich'},
          'xmux': {'maxConcurrency': '4-8'},
        }),
      },
      fragment: 'XHTTP test',
    ).toString();
    final profile = (await ProfileImporter().importFromText(link)).single;
    return const XrayConfigBuilder().build(profile);
  }

  test('builds XHTTP settings without changing SNI or JSON extra', () async {
    final config = jsonDecode(await buildXhttpConfig()) as Map<String, dynamic>;
    final outbounds = (config['outbounds'] as List).cast<Map>();
    final proxy = outbounds.first.cast<String, dynamic>();
    final stream = (proxy['streamSettings'] as Map).cast<String, dynamic>();
    final xhttp = (stream['xhttpSettings'] as Map).cast<String, dynamic>();

    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'tls');
    expect(stream['tlsSettings']['serverName'], 'sni.example.com');
    expect(xhttp['host'], 'host.example.com');
    expect(xhttp['path'], '/connect');
    expect(xhttp['mode'], 'packet-up');
    expect(xhttp['extra'], {
      'headers': {'X-Client': 'Yurich'},
      'xmux': {'maxConcurrency': '4-8'},
    });
  });

  test('bundled Xray accepts generated XHTTP config', () async {
    if (!Platform.isWindows) {
      return;
    }
    final executable = File('assets/windows/sing-box/xray.exe');
    expect(executable.existsSync(), isTrue);

    final tempDirectory = await Directory.systemTemp.createTemp(
      'yurich-xhttp-test-',
    );
    try {
      final configFile = File('${tempDirectory.path}\\xray.json');
      await configFile.writeAsString(await buildXhttpConfig(), flush: true);
      final result = await Process.run(
        executable.absolute.path,
        ['-test', '-c', configFile.path],
        workingDirectory: executable.parent.absolute.path,
        runInShell: false,
      ).timeout(const Duration(seconds: 15));

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });
}
