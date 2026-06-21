import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/runtime_log_classifier.dart';

void main() {
  group('RuntimeLogClassifier', () {
    test('hides benign TUN connection close noise from user-facing logs', () {
      const log =
          'ERROR [3871220134 341ms] connection: connection upload closed: '
          'raw-read tcp4 172.19.0.1:54682->172.19.0.2:10040: '
          'An existing connection was forcibly closed by the remote host.';

      expect(RuntimeLogClassifier.isUserFacingNoise(log), isTrue);
      expect(RuntimeLogClassifier.isDiagnosticNoise(log), isTrue);
    });

    test('hides direct route timeout noise from user-facing logs', () {
      const log =
          'ERROR [1901787533 5.0s] connection: open connection to '
          '195.209.219.65:42999 using outbound/direct[direct]: '
          'dial tcp 195.209.219.65:42999: i/o timeout';

      expect(RuntimeLogClassifier.isUserFacingNoise(log), isTrue);
      expect(RuntimeLogClassifier.isDiagnosticNoise(log), isTrue);
    });

    test('keeps real VLESS proxy failures visible for failover', () {
      const log =
          'ERROR outbound/vless[proxy]: open connection to example.com:443: '
          'i/o timeout';

      expect(RuntimeLogClassifier.isUserFacingNoise(log), isFalse);
      expect(RuntimeLogClassifier.isDiagnosticNoise(log), isFalse);
    });
  });
}
