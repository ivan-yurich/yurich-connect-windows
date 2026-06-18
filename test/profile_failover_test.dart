import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/models/vpn_profile.dart';
import 'package:yurich_connect_windows/src/services/profile_failover.dart';
import 'package:yurich_connect_windows/src/services/profile_store.dart';

void main() {
  group('profile failover ranking', () {
    test('auto-selects a healthier profile when preferred is unstable', () {
      final preferred = _profile('preferred', 'Slow RU');
      final best = _profile('best', 'Fast FI');
      final now = DateTime(2026, 6, 18);
      final stats = {
        preferred.id: const ProfileRuntimeStats(
          failures: 3,
          consecutiveFailures: 2,
          totalStartMs: 12000,
        ),
        best.id: const ProfileRuntimeStats(successes: 5, totalStartMs: 3500),
      };
      final latencies = {
        preferred.id: const ProfileLatencySnapshot.failed(),
        best.id: const ProfileLatencySnapshot.ok(65),
      };

      final ranked = rankProfilesForFailover(
        profiles: [preferred, best],
        preferred: preferred,
        runtimeStats: stats,
        latencies: latencies,
        now: now,
      );

      expect(ranked.first.profile.id, best.id);
      expect(
        shouldAutoSelectBestProfile(
          preferred: preferred,
          best: ranked.first,
          runtimeStats: stats,
          latencies: latencies,
          now: now,
        ),
        isTrue,
      );
    });

    test('keeps a healthy preferred profile first unless the gap is large', () {
      final preferred = _profile('preferred', 'Current');
      final alternative = _profile('alternative', 'Alternative');
      final now = DateTime(2026, 6, 18);
      final stats = {
        preferred.id: const ProfileRuntimeStats(
          successes: 3,
          totalStartMs: 900,
        ),
        alternative.id: const ProfileRuntimeStats(
          successes: 3,
          totalStartMs: 1200,
        ),
      };
      final latencies = {
        preferred.id: const ProfileLatencySnapshot.ok(80),
        alternative.id: const ProfileLatencySnapshot.ok(70),
      };

      final ranked = rankProfilesForFailover(
        profiles: [preferred, alternative],
        preferred: preferred,
        runtimeStats: stats,
        latencies: latencies,
        now: now,
      );

      expect(
        shouldAutoSelectBestProfile(
          preferred: preferred,
          best: ranked.first,
          runtimeStats: stats,
          latencies: latencies,
          now: now,
        ),
        isFalse,
      );
    });

    test('deprioritizes expired profiles', () {
      final expired = _profile(
        'expired',
        'Expired',
        expiresAt: DateTime(2026, 6, 17),
      );
      final active = _profile(
        'active',
        'Active',
        expiresAt: DateTime(2026, 6, 19),
      );
      final now = DateTime(2026, 6, 18);

      final ranked = rankProfilesForFailover(
        profiles: [expired, active],
        preferred: expired,
        runtimeStats: const {},
        latencies: const {},
        now: now,
      );

      expect(ranked.first.profile.id, active.id);
      expect(ranked.any((entry) => entry.profile.id == expired.id), isFalse);
    });
  });
}

VpnProfile _profile(String id, String name, {DateTime? expiresAt}) {
  return VpnProfile(
    id: id,
    name: name,
    kind: VpnProfileKind.vlessReality,
    originalInput: 'vless://example',
    server: '$id.example.com',
    port: 443,
    outbound: const {'type': 'vless', 'server': 'example.com', 'uuid': 'uuid'},
    subscriptionSource: 'https://example.com/sub',
    expiresAt: expiresAt,
  );
}
