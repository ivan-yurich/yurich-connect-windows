import 'dart:convert';

import '../models/vpn_profile.dart';

class ProfileIdentity {
  const ProfileIdentity._();

  static bool isUnsupportedXhttp(VpnProfile profile) {
    if (profile.coreBackend == VpnCoreBackend.xray) {
      return true;
    }
    final transport = profile.outbound?['transport'];
    if (transport is Map) {
      final type = '${transport['type'] ?? ''}'.trim().toLowerCase();
      if (type == 'xhttp' || type == 'splithttp') {
        return true;
      }
    }
    final uri = Uri.tryParse(profile.originalInput.trim());
    final type = uri?.queryParameters['type']?.trim().toLowerCase();
    if (type == 'xhttp' || type == 'splithttp') {
      return true;
    }
    final rawConfig = profile.rawConfig?.trim();
    if (rawConfig == null || rawConfig.isEmpty) {
      return false;
    }
    try {
      return _containsUnsupportedXhttp(jsonDecode(rawConfig));
    } on FormatException {
      return false;
    }
  }

  static String connectionKey(VpnProfile profile) {
    final payload = profile.kind == VpnProfileKind.singBoxConfig
        ? <String, dynamic>{
            'kind': profile.kind.name,
            'config': _canonicalRawConfig(profile.rawConfig),
          }
        : <String, dynamic>{
            'kind': profile.kind.name,
            'server': profile.server?.trim().toLowerCase(),
            'port': profile.port,
            'outbound': _canonicalOutbound(profile.outbound),
          };
    return _fnv1a64(jsonEncode(_canonicalize(payload)));
  }

  static Set<String> deletionKeys(VpnProfile profile) {
    final keys = <String>{connectionKey(profile)};
    final source = profile.subscriptionSource?.trim();
    if (source == null || source.isEmpty) {
      return keys;
    }
    final transport = profile.outbound?['transport'];
    final transportType = transport is Map
        ? '${transport['type'] ?? 'tcp'}'.trim().toLowerCase()
        : 'tcp';
    final slot = <String, dynamic>{
      'source': source,
      'kind': profile.kind.name,
      'server': profile.server?.trim().toLowerCase(),
      'port': profile.port,
      'transport': transportType,
    };
    keys.add('slot:${_fnv1a64(jsonEncode(_canonicalize(slot)))}');
    return keys;
  }

  static List<VpnProfile> merge({
    required Iterable<VpnProfile> current,
    required Iterable<VpnProfile> incoming,
    Iterable<VpnProfile>? identitySource,
  }) {
    final knownByKey = <String, VpnProfile>{};
    for (final profile in identitySource ?? current) {
      if (!isUnsupportedXhttp(profile)) {
        knownByKey.putIfAbsent(connectionKey(profile), () => profile);
      }
    }

    final result = <VpnProfile>[];
    final indexByKey = <String, int>{};

    void add(VpnProfile profile) {
      if (isUnsupportedXhttp(profile)) {
        return;
      }
      final key = connectionKey(profile);
      final stableId = knownByKey[key]?.id;
      final normalized = stableId == null || stableId == profile.id
          ? profile
          : profile.withId(stableId);
      final existingIndex = indexByKey[key];
      if (existingIndex == null) {
        indexByKey[key] = result.length;
        result.add(normalized);
      } else {
        result[existingIndex] = normalized;
      }
    }

    for (final profile in current) {
      add(profile);
    }
    for (final profile in incoming) {
      add(profile);
    }
    return result;
  }

  static Object? _canonicalRawConfig(String? rawConfig) {
    final source = rawConfig?.trim() ?? '';
    if (source.isEmpty) {
      return '';
    }
    try {
      return _canonicalize(jsonDecode(source));
    } on FormatException {
      return source;
    }
  }

  static Object? _canonicalOutbound(Map<String, dynamic>? outbound) {
    if (outbound == null) {
      return null;
    }
    final copy = Map<String, dynamic>.of(outbound)..remove('tag');
    return _canonicalize(copy);
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final entries =
          value.entries
              .map((entry) => MapEntry('${entry.key}', entry.value))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      return <String, dynamic>{
        for (final entry in entries) entry.key: _canonicalize(entry.value),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  static bool _containsUnsupportedXhttp(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = '${entry.key}'.toLowerCase();
        final text = '${entry.value}'.trim().toLowerCase();
        if ((key == 'type' || key == 'network') &&
            (text == 'xhttp' || text == 'splithttp')) {
          return true;
        }
        if (_containsUnsupportedXhttp(entry.value)) {
          return true;
        }
      }
    } else if (value is List) {
      return value.any(_containsUnsupportedXhttp);
    }
    return false;
  }

  static String _fnv1a64(String value) {
    var hash = 0xcbf29ce484222325;
    const mask = 0xffffffffffffffff;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
