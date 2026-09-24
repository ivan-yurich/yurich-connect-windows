import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/vpn_profile.dart';

typedef DnsProbe = Future<void> Function(String host, Duration timeout);
typedef TcpProbe =
    Future<void> Function(String host, int port, Duration timeout);
typedef TlsProbe =
    Future<void> Function(String host, int port, Duration timeout);
typedef UdpProbe =
    Future<void> Function(String host, int port, Duration timeout);

enum NetworkCompatibilityCheckKind {
  profileDns,
  profileEndpoint,
  profileUdp,
  subscriptionEndpoint,
  publicTcp,
  publicTls,
  publicUdp,
}

enum NetworkCompatibilityCheckState { passed, failed, skipped }

enum NetworkCompatibilityIssue {
  none('none'),
  dns('dns'),
  tcp('tcp'),
  tlsInterference('tls_interference'),
  udp('udp'),
  endpoint('endpoint'),
  unavailable('unavailable');

  const NetworkCompatibilityIssue(this.code);

  final String code;
}

class NetworkCompatibilityCheck {
  const NetworkCompatibilityCheck({
    required this.kind,
    required this.state,
    required this.target,
    required this.duration,
    required this.resultCode,
  });

  final NetworkCompatibilityCheckKind kind;
  final NetworkCompatibilityCheckState state;
  final String target;
  final Duration duration;
  final String resultCode;
}

class NetworkCompatibilityReport {
  const NetworkCompatibilityReport({required this.issue, required this.checks});

  final NetworkCompatibilityIssue issue;
  final List<NetworkCompatibilityCheck> checks;

  bool get healthy => issue == NetworkCompatibilityIssue.none;
}

class NetworkCompatibilityService {
  NetworkCompatibilityService({
    DnsProbe? dnsProbe,
    TcpProbe? tcpProbe,
    TlsProbe? tlsProbe,
    UdpProbe? udpProbe,
  }) : _dnsProbe = dnsProbe ?? _defaultDnsProbe,
       _tcpProbe = tcpProbe ?? _defaultTcpProbe,
       _tlsProbe = tlsProbe ?? _defaultTlsProbe,
       _udpProbe = udpProbe ?? _defaultUdpProbe;

  static const _publicTcpTargets = <(String, int)>[
    ('cp.cloudflare.com', 443),
    ('www.msftconnecttest.com', 443),
  ];
  static const _publicTlsTargets = <(String, int)>[
    ('www.cloudflare.com', 443),
    ('www.microsoft.com', 443),
  ];
  static const _publicUdpTargets = <(String, int)>[
    ('one.one.one.one', 443),
    ('dns.google', 443),
  ];

  final DnsProbe _dnsProbe;
  final TcpProbe _tcpProbe;
  final TlsProbe _tlsProbe;
  final UdpProbe _udpProbe;

  static Future<String> currentNetworkKey() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback: false,
      );
      final material =
          interfaces
              .expand(
                (interface) => interface.addresses.map(
                  (address) => '${interface.name}:${address.address}',
                ),
              )
              .toList()
            ..sort();
      if (material.isEmpty) {
        return 'net_unknown';
      }
      final digest = sha256.convert(utf8.encode(material.join('|')));
      return 'net_${digest.toString().substring(0, 16)}';
    } on Object {
      return 'net_unknown';
    }
  }

  Future<NetworkCompatibilityReport> run({
    VpnProfile? profile,
    Uri? subscriptionUri,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final pending = <Future<NetworkCompatibilityCheck>>[];
    final profileHost = profile?.server?.trim() ?? '';
    final profilePort = profile?.port;

    if (profileHost.isNotEmpty) {
      if (InternetAddress.tryParse(profileHost) == null) {
        pending.add(
          _runCheck(
            kind: NetworkCompatibilityCheckKind.profileDns,
            target: profileHost,
            action: () => _dnsProbe(profileHost, timeout),
          ),
        );
      } else {
        pending.add(
          _skipped(
            NetworkCompatibilityCheckKind.profileDns,
            profileHost,
            'ip_literal',
          ),
        );
      }

      if (profilePort != null && !_usesUdpEndpoint(profile!)) {
        pending.add(
          _runCheck(
            kind: NetworkCompatibilityCheckKind.profileEndpoint,
            target: '$profileHost:$profilePort',
            action: () => _tcpProbe(profileHost, profilePort, timeout),
          ),
        );
      } else {
        pending.add(
          _skipped(
            NetworkCompatibilityCheckKind.profileEndpoint,
            profilePort == null ? profileHost : '$profileHost:$profilePort',
            profilePort == null
                ? 'missing_port'
                : 'udp_protocol_probe_required',
          ),
        );
        if (profilePort != null) {
          pending.add(
            _runCheck(
              kind: NetworkCompatibilityCheckKind.profileUdp,
              target: '$profileHost:$profilePort',
              action: () => _udpProbe(profileHost, profilePort, timeout),
            ),
          );
        }
      }
    }

    final subscriptionHost = subscriptionUri?.host.trim() ?? '';
    if (subscriptionHost.isNotEmpty && subscriptionHost != profileHost) {
      final port = subscriptionUri!.hasPort
          ? subscriptionUri.port
          : subscriptionUri.scheme.toLowerCase() == 'http'
          ? 80
          : 443;
      pending.add(
        _runCheck(
          kind: NetworkCompatibilityCheckKind.subscriptionEndpoint,
          target: '$subscriptionHost:$port',
          action: () => _tcpProbe(subscriptionHost, port, timeout),
        ),
      );
    }

    pending.addAll([
      _runCheck(
        kind: NetworkCompatibilityCheckKind.publicTcp,
        target: 'public_https_multi_endpoint',
        action: () => _probeAnyTcp(_publicTcpTargets, timeout),
      ),
      _runCheck(
        kind: NetworkCompatibilityCheckKind.publicTls,
        target: 'public_tls_multi_endpoint',
        action: () => _probeAnyTls(_publicTlsTargets, timeout),
      ),
      _runCheck(
        kind: NetworkCompatibilityCheckKind.publicUdp,
        target: 'public_udp_multi_endpoint',
        action: () => _probeAnyUdp(_publicUdpTargets, timeout),
      ),
    ]);

    final checks = await Future.wait(pending);
    return NetworkCompatibilityReport(
      issue: classify(checks),
      checks: List.unmodifiable(checks),
    );
  }

  static NetworkCompatibilityIssue classify(
    Iterable<NetworkCompatibilityCheck> checks,
  ) {
    final values = checks.toList(growable: false);
    if (values.isEmpty ||
        values.every(
          (check) => check.state == NetworkCompatibilityCheckState.skipped,
        )) {
      return NetworkCompatibilityIssue.unavailable;
    }

    bool failed(NetworkCompatibilityCheckKind kind) => values.any(
      (check) =>
          check.kind == kind &&
          check.state == NetworkCompatibilityCheckState.failed,
    );
    bool passed(NetworkCompatibilityCheckKind kind) => values.any(
      (check) =>
          check.kind == kind &&
          check.state == NetworkCompatibilityCheckState.passed,
    );

    if (failed(NetworkCompatibilityCheckKind.profileDns) &&
        !passed(NetworkCompatibilityCheckKind.profileEndpoint)) {
      return NetworkCompatibilityIssue.dns;
    }
    if (failed(NetworkCompatibilityCheckKind.publicTcp)) {
      return NetworkCompatibilityIssue.tcp;
    }
    if (failed(NetworkCompatibilityCheckKind.publicTls)) {
      return NetworkCompatibilityIssue.tlsInterference;
    }
    if (failed(NetworkCompatibilityCheckKind.profileUdp) ||
        failed(NetworkCompatibilityCheckKind.publicUdp)) {
      return NetworkCompatibilityIssue.udp;
    }
    if (failed(NetworkCompatibilityCheckKind.profileEndpoint) ||
        failed(NetworkCompatibilityCheckKind.subscriptionEndpoint)) {
      return NetworkCompatibilityIssue.endpoint;
    }
    return NetworkCompatibilityIssue.none;
  }

  Future<void> _probeAnyTcp(
    List<(String, int)> targets,
    Duration timeout,
  ) async {
    Object? lastError;
    for (final target in targets) {
      try {
        await _tcpProbe(target.$1, target.$2, timeout);
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const SocketException('No TCP targets');
  }

  Future<void> _probeAnyTls(
    List<(String, int)> targets,
    Duration timeout,
  ) async {
    Object? lastError;
    for (final target in targets) {
      try {
        await _tlsProbe(target.$1, target.$2, timeout);
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const SocketException('No TLS targets');
  }

  Future<void> _probeAnyUdp(
    List<(String, int)> targets,
    Duration timeout,
  ) async {
    Object? lastError;
    for (final target in targets) {
      try {
        await _udpProbe(target.$1, target.$2, timeout);
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const SocketException('No UDP targets');
  }

  Future<NetworkCompatibilityCheck> _runCheck({
    required NetworkCompatibilityCheckKind kind,
    required String target,
    required Future<void> Function() action,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      await action();
      return NetworkCompatibilityCheck(
        kind: kind,
        state: NetworkCompatibilityCheckState.passed,
        target: target,
        duration: stopwatch.elapsed,
        resultCode: 'ok',
      );
    } on TimeoutException {
      return NetworkCompatibilityCheck(
        kind: kind,
        state: NetworkCompatibilityCheckState.failed,
        target: target,
        duration: stopwatch.elapsed,
        resultCode: 'timeout',
      );
    } on HandshakeException {
      return NetworkCompatibilityCheck(
        kind: kind,
        state: NetworkCompatibilityCheckState.failed,
        target: target,
        duration: stopwatch.elapsed,
        resultCode: 'tls_handshake_error',
      );
    } on SocketException {
      return NetworkCompatibilityCheck(
        kind: kind,
        state: NetworkCompatibilityCheckState.failed,
        target: target,
        duration: stopwatch.elapsed,
        resultCode: 'socket_error',
      );
    } on Object {
      return NetworkCompatibilityCheck(
        kind: kind,
        state: NetworkCompatibilityCheckState.failed,
        target: target,
        duration: stopwatch.elapsed,
        resultCode: 'probe_error',
      );
    }
  }

  Future<NetworkCompatibilityCheck> _skipped(
    NetworkCompatibilityCheckKind kind,
    String target,
    String resultCode,
  ) async {
    return NetworkCompatibilityCheck(
      kind: kind,
      state: NetworkCompatibilityCheckState.skipped,
      target: target,
      duration: Duration.zero,
      resultCode: resultCode,
    );
  }

  static bool _usesUdpEndpoint(VpnProfile profile) {
    if (profile.kind == VpnProfileKind.hysteria ||
        profile.kind == VpnProfileKind.hysteria2) {
      return true;
    }
    return profile.kind == VpnProfileKind.naive &&
        profile.outbound?['quic'] == true;
  }

  static Future<void> _defaultDnsProbe(String host, Duration timeout) async {
    final addresses = await InternetAddress.lookup(host).timeout(timeout);
    if (addresses.isEmpty) {
      throw const SocketException('Host resolved without addresses');
    }
  }

  static Future<void> _defaultTcpProbe(
    String host,
    int port,
    Duration timeout,
  ) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
  }

  static Future<void> _defaultTlsProbe(
    String host,
    int port,
    Duration timeout,
  ) async {
    final socket = await SecureSocket.connect(host, port, timeout: timeout);
    await socket.close();
  }

  static Future<void> _defaultUdpProbe(
    String host,
    int port,
    Duration timeout,
  ) async {
    final addresses = await InternetAddress.lookup(host).timeout(timeout);
    if (addresses.isEmpty) {
      throw const SocketException('UDP host resolved without addresses');
    }
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      ).timeout(timeout);
      socket.send(<int>[0], addresses.first, port);
    } finally {
      socket?.close();
    }
  }
}
