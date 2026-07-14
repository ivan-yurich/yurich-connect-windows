import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/connection_health_presentation.dart';
import 'package:yurich_connect_windows/src/services/vpn_engine.dart';

void main() {
  group('ConnectionHealthPresentation', () {
    test('does not show a failure panel for a transient connected warning', () {
      expect(
        ConnectionHealthPresentation.shouldShowIssuePanel(
          status: YurichConnectStatus.started,
          error: 'Network health is temporarily degraded',
          transientWarning: true,
        ),
        isFalse,
      );
    });

    test('keeps real connected errors visible', () {
      expect(
        ConnectionHealthPresentation.shouldShowIssuePanel(
          status: YurichConnectStatus.started,
          error: 'Core process exited',
          transientWarning: false,
        ),
        isTrue,
      );
    });

    test('always shows the administrator action panel', () {
      expect(
        ConnectionHealthPresentation.shouldShowIssuePanel(
          status: YurichConnectStatus.adminRequired,
          error: null,
          transientWarning: false,
        ),
        isTrue,
      );
    });
  });
}
