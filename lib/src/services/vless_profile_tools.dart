import 'dart:convert';

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
    'xhttp',
  };
  static const supportedXhttpModes = {
    'auto',
    'packet-up',
    'stream-up',
    'stream-one',
  };
  static const supportedPacketEncodings = {'packetaddr', 'xudp'};
  static const xhttpStableProxyOnlyMessage =
      'VLESS XHTTP работает через Xray-core только в Stable Proxy Mode. Отключи Advanced TUN Mode и повтори подключение.';

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
    final type = normalizeImportTransportType(value);
    if (!supportedTransports.contains(type)) {
      throw StateError('VLESS transport "$type" не поддерживается.');
    }
    return type;
  }

  static String normalizeImportTransportType(String? value) {
    final type = (value ?? 'tcp').trim().toLowerCase();
    if (type.isEmpty || type == 'tcp') {
      return 'tcp';
    }
    if (type == 'h2') {
      return 'http';
    }
    if (type == 'websocket') {
      return 'ws';
    }
    if (type == 'splithttp') {
      return 'xhttp';
    }
    if (!supportedTransports.contains(type)) {
      throw StateError('VLESS transport "$type" не поддерживается.');
    }
    return type;
  }

  static String transportTypeFromOutbound(Map<String, dynamic>? outbound) {
    final transport = (outbound?['transport'] as Map?)?.cast<String, dynamic>();
    if (transport != null) {
      return normalizeImportTransportType('${transport['type'] ?? 'tcp'}');
    }
    final network = '${outbound?['network'] ?? ''}'.trim().toLowerCase();
    if (network.isEmpty || network == 'tcp' || network == 'udp') {
      return 'tcp';
    }
    return normalizeImportTransportType(network);
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
      'xhttp' => 'XHTTP',
      _ => 'TCP',
    };
  }

  static bool requiresXrayBackend(VpnProfile profile) {
    if (!isVlessProfile(profile)) {
      return false;
    }
    return safeTransportType(profile) == 'xhttp';
  }

  static bool supportsSingBoxBackend(VpnProfile profile) {
    if (!isVlessProfile(profile)) {
      return true;
    }
    return !requiresXrayBackend(profile);
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

  static String normalizeXhttpMode(Object? value) {
    final mode = '${value ?? ''}'.trim().toLowerCase();
    final normalized = mode.isEmpty ? 'auto' : mode;
    if (!supportedXhttpModes.contains(normalized)) {
      throw StateError(
        'XHTTP mode "$normalized" не поддерживается. Доступны auto, packet-up, stream-up и stream-one.',
      );
    }
    return normalized;
  }

  static String normalizeXhttpPath(Object? value) {
    var path = '${value ?? ''}'.trim();
    if (path.isEmpty) {
      return '/';
    }
    if (path.length > 2048 || path.contains(RegExp(r'[\x00\r\n]'))) {
      throw StateError('XHTTP path содержит недопустимые символы.');
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    return path;
  }

  static String? normalizeXhttpHost(Object? value) {
    final host = '${value ?? ''}'.trim();
    if (host.isEmpty) {
      return null;
    }
    if (host.length > 253 || host.contains(RegExp(r'[\x00\r\n\s/]'))) {
      throw StateError('XHTTP host содержит недопустимые символы.');
    }
    return host;
  }

  static Map<String, dynamic>? normalizeXhttpExtra(Object? value) {
    if (value == null || (value is String && value.trim().isEmpty)) {
      return null;
    }
    Object? decoded = value;
    if (value is String) {
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        throw StateError('XHTTP extra должен быть корректным JSON-объектом.');
      }
    }
    if (decoded is! Map) {
      throw StateError('XHTTP extra должен быть JSON-объектом.');
    }
    try {
      final encoded = jsonEncode(decoded);
      if (utf8.encode(encoded).length > 64 * 1024) {
        throw StateError('XHTTP extra превышает безопасный лимит 64 КБ.');
      }
      return (jsonDecode(encoded) as Map).cast<String, dynamic>();
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('XHTTP extra содержит неподдерживаемые значения.');
    }
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
      'core=${profile.coreBackend.label}',
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
