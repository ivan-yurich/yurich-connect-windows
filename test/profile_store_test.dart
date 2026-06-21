import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yurich_connect_windows/src/services/profile_store.dart';

void main() {
  group('ProfileStore Codex settings', () {
    test('keeps Codex direct enabled by default', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      expect(await store.loadCodexDirect(), isTrue);
      expect(await store.loadChatGptThroughVpn(), isTrue);
      expect(await store.loadDeveloperMode(), isTrue);
      expect(await store.loadDnsOnlyThroughVpn(), isTrue);
      expect(await store.loadVpnOnlyProcesses(), isEmpty);
    });

    test('saves Codex direct preference', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveCodexDirect(false);

      expect(await store.loadCodexDirect(), isFalse);
    });

    test('saves ChatGPT website routing preference', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveChatGptThroughVpn(false);

      expect(await store.loadChatGptThroughVpn(), isFalse);
    });

    test('saves developer mode preference', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveDeveloperMode(false);

      expect(await store.loadDeveloperMode(), isFalse);
    });

    test('saves DNS leak protection preference', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveDnsOnlyThroughVpn(false);

      expect(await store.loadDnsOnlyThroughVpn(), isFalse);
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

    test('saves normalized deleted profile denylist', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveDeletedProfileIds([' profile-b ', '', 'profile-a']);
      await store.markProfileDeleted('profile-b');

      expect(await store.loadDeletedProfileIds(), {'profile-a', 'profile-b'});
    });

    test('restores manually imported profiles from denylist', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.saveDeletedProfileIds(['profile-a', 'profile-b']);
      await store.restoreProfiles(['profile-a']);

      expect(await store.loadDeletedProfileIds(), {'profile-b'});
    });
  });

  group('ProfileStore runtime stats', () {
    test('records profile success and failure score', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      final success = await store.recordProfileRuntimeSuccess(
        'profile-a',
        const Duration(milliseconds: 1200),
      );
      final failure = await store.recordProfileRuntimeFailure(
        'profile-a',
        'proxy_probe_timeout',
      );

      expect(success.successes, 1);
      expect(failure.successes, 1);
      expect(failure.failures, 1);
      expect(failure.consecutiveFailures, 1);
      expect(failure.score, lessThan(100));
      expect(failure.unstable, isFalse);

      final loaded = await store.loadProfileRuntimeStats();
      expect(loaded['profile-a']?.lastFailureReason, 'proxy_probe_timeout');
    });

    test('marks repeated failures as unstable and clears stats', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      await store.recordProfileRuntimeFailure('profile-a', 'dns');
      final second = await store.recordProfileRuntimeFailure(
        'profile-a',
        'tcp',
      );

      expect(second.consecutiveFailures, 2);
      expect(second.unstable, isTrue);
      expect(second.isQuarantined(), isTrue);

      final recovered = await store.recordProfileRuntimeSuccess(
        'profile-a',
        const Duration(milliseconds: 600),
      );
      expect(recovered.consecutiveFailures, 0);
      expect(recovered.isQuarantined(), isFalse);

      await store.removeProfileRuntimeStats('profile-a');
      expect(await store.loadProfileRuntimeStats(), isEmpty);
    });

    test('quarantines profile immediately for fail-fast failures', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      final failed = await store.recordProfileRuntimeFailure(
        'profile-a',
        'vless_upstream_timeout',
        quarantineFor: const Duration(minutes: 12),
      );

      expect(failed.consecutiveFailures, 1);
      expect(failed.lastFailureReason, 'vless_upstream_timeout');
      expect(failed.isQuarantined(), isTrue);
    });
  });

  group('ProfileStore connection history', () {
    test('keeps only the latest 20 session records', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore();

      for (var i = 0; i < 25; i += 1) {
        await store.appendConnectionSession(
          ConnectionSessionRecord(
            timestamp: DateTime(2026, 6, 18, 12, i),
            profileId: 'profile-$i',
            profileName: 'Profile $i',
            protocol: 'VLESS Reality',
            lifecycle: 'stable',
            success: true,
            startMs: 500 + i,
          ),
        );
      }

      final history = await store.loadConnectionSessionHistory();
      expect(history, hasLength(20));
      expect(history.first.profileId, 'profile-5');
      expect(history.last.profileId, 'profile-24');
    });
  });
}
