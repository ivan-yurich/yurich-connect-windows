import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/windows_update_integrity.dart';

void main() {
  group('WindowsUpdateIntegrity SHA-256 metadata', () {
    const hash =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    test('normalizes GitHub asset digest', () {
      expect(
        WindowsUpdateIntegrity.normalizeSha256('SHA256:${hash.toUpperCase()}'),
        hash,
      );
      expect(WindowsUpdateIntegrity.normalizeSha256('sha256:1234'), isNull);
      expect(WindowsUpdateIntegrity.normalizeSha256('md5:$hash'), isNull);
    });

    test('extracts the exact installer from SHA256SUMS', () {
      final content =
          '''
1111111111111111111111111111111111111111111111111111111111111111  YurichConnect_Windows_Portable.zip
$hash *YurichConnect_Setup.exe
''';

      expect(
        WindowsUpdateIntegrity.checksumForFile(
          content,
          r'C:\Temp\YurichConnect_Setup.exe',
        ),
        hash,
      );
    });

    test('rejects missing or conflicting installer checksums', () {
      expect(
        WindowsUpdateIntegrity.checksumForFile(
          '$hash  another.exe',
          'YurichConnect_Setup.exe',
        ),
        isNull,
      );
      expect(
        WindowsUpdateIntegrity.checksumForFile('''
$hash  YurichConnect_Setup.exe
1111111111111111111111111111111111111111111111111111111111111111  YurichConnect_Setup.exe
''', 'YurichConnect_Setup.exe'),
        isNull,
      );
    });

    test(
      'hashes files without loading the whole installer into memory',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'yurich_update_hash_test_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File(
          '${directory.path}${Platform.pathSeparator}sample.bin',
        );
        await file.writeAsString('abc');

        expect(await WindowsUpdateIntegrity.sha256ForFile(file), hash);
        expect(
          await WindowsUpdateIntegrity.fileMatchesSha256(file, hash),
          isTrue,
        );
        expect(
          await WindowsUpdateIntegrity.fileMatchesSha256(
            file,
            '1111111111111111111111111111111111111111111111111111111111111111',
          ),
          isFalse,
        );
      },
    );
  });

  group('WindowsUpdateIntegrity Authenticode policy', () {
    const signedApp = WindowsAuthenticodeInfo(
      status: 'Valid',
      thumbprint: 'AABBCC',
      subject: 'CN=Yurich',
    );

    test('accepts the same valid signer', () {
      expect(
        WindowsUpdateIntegrity.authenticodePolicyError(
          currentApp: signedApp,
          installer: const WindowsAuthenticodeInfo(
            status: 'Valid',
            thumbprint: 'aabbcc',
          ),
        ),
        isNull,
      );
    });

    test('rejects unsigned or differently signed updates after signing', () {
      expect(
        WindowsUpdateIntegrity.authenticodePolicyError(
          currentApp: signedApp,
          installer: const WindowsAuthenticodeInfo(status: 'NotSigned'),
        ),
        isNotNull,
      );
      expect(
        WindowsUpdateIntegrity.authenticodePolicyError(
          currentApp: signedApp,
          installer: const WindowsAuthenticodeInfo(
            status: 'Valid',
            thumbprint: 'DDEEFF',
          ),
        ),
        isNotNull,
      );
    });

    test('allows the current unsigned beta to update using SHA-256', () {
      expect(
        WindowsUpdateIntegrity.authenticodePolicyError(
          currentApp: const WindowsAuthenticodeInfo(status: 'NotSigned'),
          installer: const WindowsAuthenticodeInfo(status: 'NotSigned'),
        ),
        isNull,
      );
    });

    test('rejects a broken installer signature', () {
      expect(
        WindowsUpdateIntegrity.authenticodePolicyError(
          currentApp: const WindowsAuthenticodeInfo(status: 'NotSigned'),
          installer: const WindowsAuthenticodeInfo(status: 'HashMismatch'),
        ),
        isNotNull,
      );
    });

    test('rejects updates when the current signed app is corrupted', () {
      expect(
        WindowsUpdateIntegrity.authenticodePolicyError(
          currentApp: const WindowsAuthenticodeInfo(status: 'HashMismatch'),
          installer: const WindowsAuthenticodeInfo(status: 'Valid'),
        ),
        isNotNull,
      );
    });

    test('parses PowerShell Authenticode JSON', () {
      final parsed = WindowsUpdateIntegrity.parseAuthenticodeJson(
        '{"status":"Valid","thumbprint":"aabbcc","subject":"CN=Yurich"}',
      );

      expect(parsed, isNotNull);
      expect(parsed!.isValid, isTrue);
      expect(parsed.thumbprint, 'AABBCC');
      expect(parsed.subject, 'CN=Yurich');
    });
  });
}
