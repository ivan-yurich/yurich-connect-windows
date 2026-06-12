import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yurich_connect_windows/src/services/profile_store.dart';

void main() {
  group('ProfileStore Codex settings', () {
    test('keeps Codex direct enabled by default', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      expect(await store.loadCodexDirect(), isTrue);
      expect(await store.loadVpnOnlyProcesses(), isEmpty);
    });

    test('saves Codex direct preference', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveCodexDirect(false);

      expect(await store.loadCodexDirect(), isFalse);
    });
  });

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
