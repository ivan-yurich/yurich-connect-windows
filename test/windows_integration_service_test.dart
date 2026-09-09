import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/windows_integration_service.dart';

void main() {
  group('WindowsIntegrationService legacy auto-start task XML', () {
    test('accepts immediate elevated interactive tray startup task', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Delay>PT0S</Delay>
    </LogonTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>C:\Program Files\Yurich Connect\YurichConnect.exe</Command>
      <Arguments>--autostart</Arguments>
      <WorkingDirectory>C:\Program Files\Yurich Connect</WorkingDirectory>
    </Exec>
  </Actions>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
</Task>
''';

      expect(
        WindowsIntegrationService.isAutoStartTaskInstalledXml(xml),
        isTrue,
      );
      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isTrue);
    });

    test('detects elevated immediate task as installed legacy startup', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Delay>PT0S</Delay>
    </LogonTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>C:\Program Files\Yurich Connect\YurichConnect.exe</Command>
      <WorkingDirectory>C:\Program Files\Yurich Connect</WorkingDirectory>
    </Exec>
  </Actions>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
</Task>
''';

      expect(
        WindowsIntegrationService.isAutoStartTaskInstalledXml(xml),
        isTrue,
      );
      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isFalse);
    });

    test('detects elevated immediate task without startup delay field', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Actions>
    <Exec>
      <Command>C:\Program Files\Yurich Connect\YurichConnect.exe</Command>
      <WorkingDirectory>C:\Program Files\Yurich Connect</WorkingDirectory>
    </Exec>
  </Actions>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
</Task>
''';

      expect(
        WindowsIntegrationService.isAutoStartTaskInstalledXml(xml),
        isTrue,
      );
      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isFalse);
    });

    test('detects old task with non-zero startup delay', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Delay>PT30S</Delay>
    </LogonTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>C:\Program Files\Yurich Connect\YurichConnect.exe</Command>
      <WorkingDirectory>C:\Program Files\Yurich Connect</WorkingDirectory>
    </Exec>
  </Actions>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
</Task>
''';

      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isFalse);
      expect(
        WindowsIntegrationService.isAutoStartTaskInstalledXml(xml),
        isTrue,
      );
    });

    test('rejects elevated task without working directory', () {
      const xml = '''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Delay>PT0S</Delay>
    </LogonTrigger>
  </Triggers>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
</Task>
''';

      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isFalse);
      expect(
        WindowsIntegrationService.isAutoStartTaskInstalledXml(xml),
        isTrue,
      );
    });

    test('rejects tasks that stop on battery power', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Delay>PT0S</Delay>
    </LogonTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>C:\Program Files\Yurich Connect\YurichConnect.exe</Command>
      <WorkingDirectory>C:\Program Files\Yurich Connect</WorkingDirectory>
    </Exec>
  </Actions>
  <Settings>
    <DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
  </Settings>
</Task>
''';

      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isFalse);
    });
  });

  group('WindowsIntegrationService.compareReleaseVersions', () {
    test('handles GitHub release tags with v prefix', () {
      expect(
        WindowsIntegrationService.compareReleaseVersions('v1.0.1', '1.0.0'),
        isPositive,
      );
      expect(
        WindowsIntegrationService.compareReleaseVersions('v1.0.0', '1.0.0'),
        isZero,
      );
    });

    test('ignores Flutter build suffix when versions are otherwise equal', () {
      expect(
        WindowsIntegrationService.compareReleaseVersions('1.0.0', '1.0.0+1'),
        isZero,
      );
      expect(
        WindowsIntegrationService.compareReleaseVersions('1.0.1', '1.0.0+9'),
        isPositive,
      );
    });

    test('ignores prerelease suffix for base version comparison', () {
      expect(
        WindowsIntegrationService.compareReleaseVersions(
          'v1.0.0-beta.1',
          '1.0.0',
        ),
        isZero,
      );
    });

    test('compares missing patch parts as zero', () {
      expect(
        WindowsIntegrationService.compareReleaseVersions('1.0', '1.0.0'),
        isZero,
      );
      expect(
        WindowsIntegrationService.compareReleaseVersions('1.1', '1.0.9'),
        isPositive,
      );
    });

    test('treats older Windows release tags as not updateable', () {
      expect(
        WindowsIntegrationService.compareReleaseVersions(
          'v1.0.19-windows',
          '1.0.22',
        ),
        isNegative,
      );
    });
  });

  group('WindowsIntegrationService release web fallback', () {
    test('extracts latest release tag from redirect location', () {
      expect(
        WindowsIntegrationService.releaseTagFromLocation(
          'https://github.com/ivan-yurich/yurich-connect-windows/releases/tag/v1.0.38-windows',
        ),
        'v1.0.38-windows',
      );
      expect(
        WindowsIntegrationService.releaseTagFromLocation(
          '/ivan-yurich/yurich-connect-windows/releases/tag/v1.0.39-windows',
        ),
        'v1.0.39-windows',
      );
    });

    test('extracts latest release tag from GitHub html', () {
      expect(
        WindowsIntegrationService.releaseTagFromHtml(
          '<a href="/ivan-yurich/yurich-connect-windows/releases/tag/v1.0.40-windows">latest</a>',
        ),
        'v1.0.40-windows',
      );
    });

    test('extracts latest release tag from GitHub atom feed', () {
      const atom = '''
<feed>
  <entry>
    <id>tag:github.com,2008:Repository/1246885860/v1.0.41-windows</id>
    <link rel="alternate" type="text/html" href="https://github.com/ivan-yurich/yurich-connect-windows/releases/tag/v1.0.41-windows"/>
    <title>Yurich Connect for Windows v1.0.41</title>
  </entry>
</feed>
''';

      expect(
        WindowsIntegrationService.releaseTagFromAtom(atom),
        'v1.0.41-windows',
      );
    });
  });

  group('WindowsIntegrationService update trust boundary', () {
    test('accepts only this repository release downloads over HTTPS', () {
      expect(
        WindowsIntegrationService.isTrustedReleaseDownloadUrl(
          Uri.parse(
            'https://github.com/ivan-yurich/yurich-connect-windows/releases/download/v1.0.105/YurichConnect_Setup.exe',
          ),
          expectedTag: 'v1.0.105',
        ),
        isTrue,
      );
      expect(
        WindowsIntegrationService.isTrustedReleaseDownloadUrl(
          Uri.parse(
            'http://github.com/ivan-yurich/yurich-connect-windows/releases/download/v1.0.105/YurichConnect_Setup.exe',
          ),
        ),
        isFalse,
      );
      expect(
        WindowsIntegrationService.isTrustedReleaseDownloadUrl(
          Uri.parse(
            'https://github.com/ivan-yurich/yurich-connect-windows/releases/download/v1.0.104/YurichConnect_Setup.exe',
          ),
          expectedTag: 'v1.0.105',
        ),
        isFalse,
      );
      expect(
        WindowsIntegrationService.isTrustedReleaseDownloadUrl(
          Uri.parse(
            'https://github.com/ivan-yurich/yurich-connect-windows/releases/download/v1.0.105/YurichConnect_Setup.exe?source=other',
          ),
        ),
        isFalse,
      );
      expect(
        WindowsIntegrationService.isTrustedReleaseDownloadUrl(
          Uri.parse(
            'https://github.com/ivan-yurich/yurich-connect-windows/releases/download/v1.0.105/other.exe',
          ),
        ),
        isFalse,
      );
      expect(
        WindowsIntegrationService.isTrustedReleaseDownloadUrl(
          Uri.parse(
            'https://github.com/attacker/yurich-connect-windows/releases/download/v1.0.105/YurichConnect_Setup.exe',
          ),
        ),
        isFalse,
      );
    });

    test('requires integrity metadata before enabling installation', () {
      final installer = Uri.parse(
        'https://github.com/ivan-yurich/yurich-connect-windows/releases/download/v1.0.105/YurichConnect_Setup.exe',
      );
      expect(
        WindowsUpdateInfo(
          message: 'update',
          available: true,
          installerUrl: installer,
        ).canInstall,
        isFalse,
      );
      expect(
        WindowsUpdateInfo(
          message: 'update',
          available: true,
          installerUrl: installer,
          installerSha256:
              '1111111111111111111111111111111111111111111111111111111111111111',
        ).canInstall,
        isTrue,
      );
      expect(
        WindowsUpdateInfo(
          message: 'update',
          available: true,
          installerUrl: installer,
          installerChecksumUrl: Uri.parse('$installer.sha256'),
        ).canInstall,
        isTrue,
      );
    });
  });
}
