import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/windows_integration_service.dart';

void main() {
  group('WindowsIntegrationService auto-start task XML', () {
    test('accepts elevated delayed task that can run on battery', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Delay>PT1S</Delay>
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

      expect(WindowsIntegrationService.isAutoStartTaskHealthyXml(xml), isTrue);
    });

    test('rejects old elevated task without startup delay', () {
      const xml = r'''
<Task>
  <Principals>
    <Principal>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
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
      <Delay>PT1S</Delay>
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
      <Delay>PT1S</Delay>
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
}
