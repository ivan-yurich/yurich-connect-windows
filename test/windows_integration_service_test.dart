import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn_windows/src/services/windows_integration_service.dart';

void main() {
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
  });
}
