import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/models/vpn_profile.dart';
import 'package:yurich_connect_windows/src/services/profile_failover.dart';
import 'package:yurich_connect_windows/src/services/profile_store.dart';

void main() {
  group('profile failover ranking', () {
    test('adaptive access allows a cross-protocol startup fallback', () {
      final preferred = _profile('preferred', 'Reality');
      final naive = _profile(
        'naive',
        'Naive HTTPS',
        kind: VpnProfileKind.naive,
      );

      expect(
        profileFailoverPool(
          profiles: [preferred, naive],
          preferred: preferred,
          adaptiveAccess: false,
        ).map((profile) => profile.id),
        ['preferred'],
      );
      expect(
        profileFailoverPool(
          profiles: [preferred, naive],
          preferred: preferred,
          adaptiveAccess: true,
        ).map((profile) => profile.id),
        ['preferred', 'naive'],
      );
    });

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

    test('skips quarantined profiles when healthy candidates exist', () {
      final preferred = _profile('preferred', 'Germany Primary');
      final quarantined = _profile('quarantined', 'Germany Broken');
      final healthy = _profile('healthy', 'Germany Backup');
      final now = DateTime(2026, 6, 18);
      final stats = {
        quarantined.id: ProfileRuntimeStats(
          failures: 4,
          consecutiveFailures: 3,
          quarantinedUntil: now.add(const Duration(minutes: 20)),
        ),
        healthy.id: const ProfileRuntimeStats(successes: 4, totalStartMs: 2000),
      };

      final ranked = rankProfilesForFailover(
        profiles: [preferred, quarantined, healthy],
        preferred: preferred,
        runtimeStats: stats,
        latencies: {
          quarantined.id: const ProfileLatencySnapshot.ok(40),
          healthy.id: const ProfileLatencySnapshot.ok(90),
        },
        now: now,
      );

      expect(
        ranked.map((entry) => entry.profile.id),
        isNot(contains(quarantined.id)),
      );
      expect(ranked.first.profile.id, healthy.id);
    });

    test('keeps VLESS failover inside the same transport group first', () {
      final preferred = _profile(
        'preferred',
        'Germany Reality TCP',
        transport: 'tcp',
      );
      final sameTransport = _profile(
        'same-transport',
        'Germany Reality Backup',
        transport: 'tcp',
      );
      final grpc = _profile('grpc', 'Germany gRPC Backup', transport: 'grpc');
      final now = DateTime(2026, 6, 18);
      final stats = {
        sameTransport.id: const ProfileRuntimeStats(
          successes: 2,
          totalStartMs: 1400,
        ),
        grpc.id: const ProfileRuntimeStats(successes: 6, totalStartMs: 900),
      };
      final latencies = {
        sameTransport.id: const ProfileLatencySnapshot.ok(120),
        grpc.id: const ProfileLatencySnapshot.ok(40),
      };

      final ranked = rankProfilesForFailover(
        profiles: [preferred, grpc, sameTransport],
        preferred: preferred,
        runtimeStats: stats,
        latencies: latencies,
        now: now,
      );

      expect(ranked.first.profile.id, sameTransport.id);
      expect(ranked.map((entry) => entry.profile.id), contains(grpc.id));
    });

    test('compatibility strategy prefers TCP friendly transports', () {
      final preferred = _profile('preferred', 'Current Reality');
      final hysteria = _profile(
        'hysteria',
        'Hysteria Turbo',
        kind: VpnProfileKind.hysteria2,
      );
      final naiveHttps = _profile(
        'naive-https',
        'Naive HTTPS',
        kind: VpnProfileKind.naive,
      );
      final now = DateTime(2026, 6, 18);

      final ranked = rankProfilesForFailover(
        profiles: [hysteria, naiveHttps, preferred],
        preferred: preferred,
        runtimeStats: const {},
        latencies: {
          hysteria.id: const ProfileLatencySnapshot.ok(20),
          naiveHttps.id: const ProfileLatencySnapshot.ok(70),
          preferred.id: const ProfileLatencySnapshot.ok(90),
        },
        adaptiveStrategy: AdaptiveAccessStrategy.compatibility,
        now: now,
      );

      expect(ranked.map((entry) => entry.profile.id).take(2), [
        'preferred',
        'naive-https',
      ]);
    });

    test('speed strategy prefers UDP capable transports', () {
      final preferred = _profile('preferred', 'Current Reality');
      final hysteria = _profile(
        'hysteria',
        'Hysteria Turbo',
        kind: VpnProfileKind.hysteria2,
      );
      final naiveQuic = _profile(
        'naive-quic',
        'Naive QUIC',
        kind: VpnProfileKind.naive,
        quic: true,
      );
      final now = DateTime(2026, 6, 18);

      final ranked = rankProfilesForFailover(
        profiles: [preferred, naiveQuic, hysteria],
        preferred: preferred,
        runtimeStats: const {},
        latencies: {
          preferred.id: const ProfileLatencySnapshot.ok(40),
          naiveQuic.id: const ProfileLatencySnapshot.ok(60),
          hysteria.id: const ProfileLatencySnapshot.ok(80),
        },
        adaptiveStrategy: AdaptiveAccessStrategy.speed,
        now: now,
      );

      expect(ranked.map((entry) => entry.profile.id).take(2), [
        'hysteria',
        'naive-quic',
      ]);
    });

    test('server variant metadata keeps failover inside the same location', () {
      final preferred = _profile(
        'preferred',
        'DE Frankfurt • VLESS TCP',
        variantGroup: 'de-frankfurt-1',
        variantRole: 'vless-reality-tcp',
        variantStrategy: 'compatibility',
        variantPriority: 10,
      );
      final sameGroupNaive = _profile(
        'same-naive',
        'DE Frankfurt • Naive HTTPS',
        kind: VpnProfileKind.naive,
        variantGroup: 'de-frankfurt-1',
        variantRole: 'naive-https',
        variantStrategy: 'compatibility',
        variantPriority: 20,
      );
      final otherVless = _profile(
        'other-vless',
        'NL Amsterdam • VLESS TCP',
        variantGroup: 'nl-amsterdam-1',
        variantRole: 'vless-reality-tcp',
        variantStrategy: 'compatibility',
        variantPriority: 10,
      );
      final now = DateTime(2026, 6, 18);

      final ranked = rankProfilesForFailover(
        profiles: [otherVless, sameGroupNaive, preferred],
        preferred: preferred,
        runtimeStats: const {},
        latencies: {
          preferred.id: const ProfileLatencySnapshot.ok(90),
          sameGroupNaive.id: const ProfileLatencySnapshot.ok(120),
          otherVless.id: const ProfileLatencySnapshot.ok(30),
        },
        adaptiveStrategy: AdaptiveAccessStrategy.compatibility,
        now: now,
      );

      expect(ranked.map((entry) => entry.profile.id).take(2), [
        'preferred',
        'same-naive',
      ]);
    });

    test('does not retry a quarantined preferred profile after failover', () {
      final preferred = _profile('preferred', 'Estonia Broken');
      final healthy = _profile('healthy', 'France Healthy');
      final now = DateTime(2026, 9, 4);
      final selection = selectProfileFailoverCandidates(
        profiles: [preferred, healthy],
        preferred: preferred,
        runtimeStats: {
          preferred.id: ProfileRuntimeStats(
            failures: 2,
            consecutiveFailures: 2,
            quarantinedUntil: now.add(const Duration(minutes: 15)),
          ),
          healthy.id: const ProfileRuntimeStats(
            successes: 3,
            totalStartMs: 1800,
          ),
        },
        latencies: {
          preferred.id: const ProfileLatencySnapshot.ok(35),
          healthy.id: const ProfileLatencySnapshot.ok(90),
        },
        maxAttempts: 5,
        now: now,
      );

      expect(selection.candidates.map((profile) => profile.id), ['healthy']);
      expect(selection.autoSelectedProfile?.id, 'healthy');
    });

    test(
      'tries only the requested profile when every profile is quarantined',
      () {
        final preferred = _profile('preferred', 'Requested');
        final alternative = _profile('alternative', 'Alternative');
        final now = DateTime(2026, 9, 4);
        final quarantinedUntil = now.add(const Duration(minutes: 15));
        final selection = selectProfileFailoverCandidates(
          profiles: [preferred, alternative],
          preferred: preferred,
          runtimeStats: {
            preferred.id: ProfileRuntimeStats(
              consecutiveFailures: 2,
              quarantinedUntil: quarantinedUntil,
            ),
            alternative.id: ProfileRuntimeStats(
              consecutiveFailures: 2,
              quarantinedUntil: quarantinedUntil,
            ),
          },
          latencies: const {},
          maxAttempts: 5,
          now: now,
        );

        expect(selection.candidates.map((profile) => profile.id), [
          'preferred',
        ]);
        expect(selection.autoSelectedProfile, isNull);
      },
    );
  });

  group('startup probe quarantine policy', () {
    test('classifies repeated upstream failures for every protocol', () {
      const failures = ['proxy_probe_timeout', 'tcp', 'socket'];

      expect(
        startupProbeQuarantineReason(
          profileKind: VpnProfileKind.vlessReality,
          failureClasses: failures,
        ),
        'vless_upstream_unreachable',
      );
      expect(
        startupProbeQuarantineReason(
          profileKind: VpnProfileKind.naive,
          failureClasses: failures,
        ),
        'naive_upstream_unreachable',
      );
      expect(
        startupProbeQuarantineReason(
          profileKind: VpnProfileKind.hysteria2,
          failureClasses: failures,
        ),
        'hysteria_upstream_unreachable',
      );
    });

    test('does not quarantine after one or mixed endpoint failure', () {
      expect(
        startupProbeQuarantineReason(
          profileKind: VpnProfileKind.vlessReality,
          failureClasses: const ['proxy_probe_timeout'],
        ),
        isNull,
      );
      expect(
        startupProbeQuarantineReason(
          profileKind: VpnProfileKind.vlessReality,
          failureClasses: const ['proxy_probe_timeout', 'http_status', 'http'],
        ),
        isNull,
      );
    });
  });
}

VpnProfile _profile(
  String id,
  String name, {
  DateTime? expiresAt,
  String transport = 'tcp',
  VpnProfileKind kind = VpnProfileKind.vlessReality,
  bool quic = false,
  String? variantGroup,
  String? variantRole,
  String? variantStrategy,
  int? variantPriority,
}) {
  final outboundType = switch (kind) {
    VpnProfileKind.naive => 'naive',
    VpnProfileKind.hysteria || VpnProfileKind.hysteria2 => 'hysteria2',
    _ => 'vless',
  };
  final outbound = <String, dynamic>{
    'type': outboundType,
    'server': 'example.com',
    'uuid': '11111111-1111-4111-8111-111111111111',
    if (quic) 'quic': true,
    if (transport != 'tcp') 'transport': {'type': transport},
  };
  return VpnProfile(
    id: id,
    name: name,
    kind: kind,
    originalInput: 'vless://example',
    server: '$id.example.com',
    port: 443,
    outbound: outbound,
    subscriptionSource: 'https://example.com/sub',
    expiresAt: expiresAt,
    variantGroup: variantGroup,
    variantRole: variantRole,
    variantStrategy: variantStrategy,
    variantPriority: variantPriority,
  );
}
