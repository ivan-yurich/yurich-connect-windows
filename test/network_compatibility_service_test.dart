import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/models/vpn_profile.dart';
import 'package:yurich_connect_windows/src/services/network_compatibility_service.dart';

void main() {
  VpnProfile profile({VpnProfileKind kind = VpnProfileKind.vlessReality}) {
    return VpnProfile(
      id: 'profile',
      name: 'Profile',
      kind: kind,
      originalInput: 'redacted',
      server: 'vpn.example.com',
      port: 443,
      outbound: const {'type': 'vless'},
    );
  }

  test(
    'reports a healthy path without exposing subscription URL data',
    () async {
      final service = NetworkCompatibilityService(
        dnsProbe: (_, _) async {},
        tcpProbe: (_, _, _) async {},
        tlsProbe: (_, _, _) async {},
      );

      final report = await service.run(
        profile: profile(),
        subscriptionUri: Uri.parse(
          'https://connect.example.com/s/private-token?device=secret',
        ),
      );

      expect(report.issue, NetworkCompatibilityIssue.none);
      expect(report.checks, isNotEmpty);
      expect(
        report.checks.map((check) => check.target).join(' '),
        isNot(contains('private-token')),
      );
      expect(
        report.checks.map((check) => check.target).join(' '),
        isNot(contains('device=secret')),
      );
    },
  );

  test('classifies DNS failure before endpoint failures', () async {
    final service = NetworkCompatibilityService(
      dnsProbe: (_, _) async => throw const SocketException('blocked'),
      tcpProbe: (host, _, _) async {
        if (host == 'vpn.example.com') {
          throw TimeoutException('blocked');
        }
      },
      tlsProbe: (_, _, _) async {},
    );

    final report = await service.run(profile: profile());

    expect(report.issue, NetworkCompatibilityIssue.dns);
  });

  test('classifies public TLS interception separately', () async {
    final service = NetworkCompatibilityService(
      dnsProbe: (_, _) async {},
      tcpProbe: (_, _, _) async {},
      tlsProbe: (_, _, _) async => throw const HandshakeException('blocked'),
    );

    final report = await service.run(profile: profile());

    expect(report.issue, NetworkCompatibilityIssue.tlsInterference);
  });

  test(
    'ignores a transient DNS miss when the profile endpoint connects',
    () async {
      final service = NetworkCompatibilityService(
        dnsProbe: (_, _) async => throw const SocketException('transient'),
        tcpProbe: (_, _, _) async {},
        tlsProbe: (_, _, _) async {},
      );

      final report = await service.run(profile: profile());

      expect(report.issue, NetworkCompatibilityIssue.none);
    },
  );

  test('does not pretend a Hysteria TCP probe validates UDP', () async {
    final service = NetworkCompatibilityService(
      dnsProbe: (_, _) async {},
      tcpProbe: (_, _, _) async {},
      tlsProbe: (_, _, _) async {},
    );

    final report = await service.run(
      profile: profile(kind: VpnProfileKind.hysteria2),
    );
    final endpoint = report.checks.singleWhere(
      (check) => check.kind == NetworkCompatibilityCheckKind.profileEndpoint,
    );

    expect(endpoint.state, NetworkCompatibilityCheckState.skipped);
    expect(endpoint.resultCode, 'udp_protocol_probe_required');
    expect(report.issue, NetworkCompatibilityIssue.none);
  });
}
