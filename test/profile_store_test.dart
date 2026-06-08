import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yurich_connect_windows/src/services/profile_store.dart';

void main() {
  group('ProfileStore subscription sources', () {
    test('saves normalized unique subscription URLs', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveSubscriptionSources([
        ' https://example.com/sub ',
        'https://example.com/sub',
        '',
        'https://example.com/next',
      ]);

      expect(await store.loadSubscriptionSources(), [
        'https://example.com/next',
        'https://example.com/sub',
      ]);
    });
  });
}
