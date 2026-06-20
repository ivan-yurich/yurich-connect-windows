import '../models/vpn_profile.dart';

class VlessProfileTools {
  const VlessProfileTools._();

  static const allowedFlow = 'xtls-rprx-vision';
  static const supportedTransports = {
    'tcp',
    'ws',
    'grpc',
    'http',
    'httpupgrade',
  };
  static const supportedPacketEncodings = {'packetaddr', 'xudp'};
  static const unsupportedXhttpMessage =
      'VLESS XHTTP пока не поддерживается bundled sing-box. Для XHTTP нужен отдельный Xray-core backend.';

  static bool isVlessKind(VpnProfileKind kind) =>
      kind == VpnProfileKind.vlessReality || kind == VpnProfileKind.vlessTls;

  static bool isVlessProfile(VpnProfile profile) => isVlessKind(profile.kind);

  static bool isValidUuid(String value) {
    final normalized = value.trim();
    return RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
        ).hasMatch(normalized) ||
        RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(normalized);
  }

  static String normalizeTransportType(String? value) {
    final type = (value ?? 'tcp').trim().toLowerCase();
    if (type.isEmpty || type == 'tcp') {
      return 'tcp';
    }
    if (type == 'h2') {
      return 'http';
    }
    if (type == 'splithttp' || type == 'xhttp') {
      throw StateError(unsupportedXhttpMessage);
    }
    if (!supportedTransports.contains(type)) {
      throw StateError('VLESS transport "$type" не поддерживается.');
    }
    return type;
  }

  static String transportTypeFromOutbound(Map<String, dynamic>? outbound) {
    final transport = (outbound?['transport'] as Map?)?.cast<String, dynamic>();
    if (transport != null) {
      return normalizeTransportType('${transport['type'] ?? 'tcp'}');
    }
    final network = '${outbound?['network'] ?? ''}'.trim().toLowerCase();
    if (network.isEmpty || network == 'tcp' || network == 'udp') {
      return 'tcp';
    }
    return normalizeTransportType(network);
  }

  static String transportType(VpnProfile profile) =>
      transportTypeFromOutbound(profile.outbound);

  static String safeTransportType(VpnProfile profile) {
    try {
      return transportType(profile);
    } on Object {
      return 'unsupported';
    }
  }

  static String transportLabel(VpnProfile profile) {
    final transport = safeTransportType(profile);
    return switch (transport) {
      'ws' => 'WebSocket',
      'grpc' => 'gRPC',
      'http' => 'HTTP/H2',
      'httpupgrade' => 'HTTPUpgrade',
      _ => 'TCP',
    };
  }

  static String? normalizeFlow(String? value) {
    final flow = (value ?? '').trim();
    if (flow.isEmpty) {
      return null;
    }
    if (flow != allowedFlow) {
      throw StateError(
        'VLESS flow "$flow" не поддерживается. Поддерживается только $allowedFlow.',
      );
    }
    return flow;
  }

  static String? normalizePacketEncoding(String? value) {
    final encoding = (value ?? '').trim().toLowerCase();
    if (encoding.isEmpty || encoding == 'none') {
      return null;
    }
    if (!supportedPacketEncodings.contains(encoding)) {
      throw StateError(
        'VLESS packet_encoding "$encoding" не поддерживается. Доступны packetaddr или xudp.',
      );
    }
    return encoding;
  }

  static String configSummary(VpnProfile profile) {
    if (!isVlessProfile(profile)) {
      return 'not_vless';
    }
    final outbound = profile.outbound ?? const <String, dynamic>{};
    final tls = (outbound['tls'] as Map?)?.cast<String, dynamic>();
    final reality = (tls?['reality'] as Map?)?.cast<String, dynamic>();
    final flow = '${outbound['flow'] ?? 'none'}';
    final packetEncoding = '${outbound['packet_encoding'] ?? 'none'}';
    return [
      'family=${profile.kind.label}',
      'transport=${safeTransportType(profile)}',
      'flow=$flow',
      'packet_encoding=$packetEncoding',
      'tls=${tls?['enabled'] == true}',
      'utls=${(tls?['utls'] as Map?)?['fingerprint'] ?? 'none'}',
      if (profile.kind == VpnProfileKind.vlessReality)
        'reality_public_key=${_present(reality?['public_key'])}',
      if (profile.kind == VpnProfileKind.vlessReality)
        'reality_short_id=${_present(reality?['short_id'])}',
      if (tls?['server_name'] != null) 'sni=${tls?['server_name']}',
    ].join('; ');
  }

  static String _present(Object? value) {
    final text = '$value'.trim();
    return text.isEmpty || text == 'null' ? 'missing' : 'present';
  }
}
