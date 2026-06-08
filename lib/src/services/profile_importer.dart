import 'dart:convert';
import 'dart:io';

import '../models/vpn_profile.dart';
import 'sing_box_config_builder.dart';

class ProfileImportException implements Exception {
  const ProfileImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _SubscriptionFetchResult {
  const _SubscriptionFetchResult({required this.body, this.expiresAt});

  final String body;
  final DateTime? expiresAt;
}

class ProfileImporter {
  static final _linkPattern = RegExp(
    "(?:vless://|naive\\+https://|naive://|hysteria2://|hy2://|hysteria://)[^\\s<>\"']+",
    caseSensitive: false,
  );

  Future<List<VpnProfile>> importFromText(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      throw const ProfileImportException('Вставь ссылку, подписку или JSON.');
    }

    final uri = Uri.tryParse(text);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final fetched = await _fetchSubscription(uri);
      return _parsePayload(
        fetched.body,
        source: text,
        defaultExpiresAt: fetched.expiresAt,
      );
    }

    return _parsePayload(text, source: text);
  }

  Future<_SubscriptionFetchResult> _fetchSubscription(Uri uri) async {
    final clients = [
      'YurichConnect-Windows/1.0.30 YurichCore/sing-box/1.13.12',
      'HiddifyNext/2.5.7',
      'NekoBoxForAndroid/1.3.8',
      'v2rayNG/1.10.5',
    ];

    Object? lastError;
    final candidates = <String>[];
    DateTime? candidateExpiresAt;
    for (final userAgent in clients) {
      for (final viaLocalProxy in const [false, true]) {
        try {
          final fetched = await _get(
            uri,
            userAgent: userAgent,
            viaLocalProxy: viaLocalProxy,
          );
          candidateExpiresAt = fetched.expiresAt;
          final normalizedBody = _decodeHtmlEntities(fetched.body);
          if (_canParsePayload(normalizedBody)) {
            return _SubscriptionFetchResult(
              body: normalizedBody,
              expiresAt: fetched.expiresAt,
            );
          }
          if (_looksLikeHtml(normalizedBody)) {
            candidates.add(normalizedBody);
            lastError = ProfileImportException(
              '${_fetchModeLabel(viaLocalProxy)}: сервер вернул HTML-страницу без поддерживаемых raw-ссылок.',
            );
            continue;
          }
          candidates.add(normalizedBody);
        } on Object catch (error) {
          lastError = ProfileImportException(
            '${_fetchModeLabel(viaLocalProxy)}: $error',
          );
        }
      }
    }

    if (candidates.isNotEmpty) {
      return _SubscriptionFetchResult(
        body: candidates.first,
        expiresAt: candidateExpiresAt,
      );
    }

    throw ProfileImportException(
      'Не смог получить Yurich ID. Проверь, что в Yurich Panel включён Base64/Xray-json/Sing-box template. Деталь: $lastError',
    );
  }

  bool _canParsePayload(String body) {
    try {
      return _parsePayload(body, source: '').isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<_SubscriptionFetchResult> _get(
    Uri uri, {
    required String userAgent,
    bool viaLocalProxy = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: viaLocalProxy ? 8 : 12);
    if (viaLocalProxy) {
      client.findProxy = (_) =>
          'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
    }
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/plain, application/json, */*',
      );
      request.followRedirects = true;

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ProfileImportException('HTTP ${response.statusCode}: $body');
      }
      final expiresAt = _extractSubscriptionExpires(response.headers);
      return _SubscriptionFetchResult(body: body, expiresAt: expiresAt);
    } finally {
      client.close(force: true);
    }
  }

  String _fetchModeLabel(bool viaLocalProxy) {
    return viaLocalProxy ? 'fallback через активный VPN' : 'прямой запрос';
  }

  List<VpnProfile> _parsePayload(
    String payload, {
    required String source,
    DateTime? defaultExpiresAt,
  }) {
    final text = payload.trim();
    if (text.isEmpty) {
      throw const ProfileImportException('Подписка пустая.');
    }

    final jsonProfile = _tryParseJsonConfig(
      text,
      source: source,
      defaultExpiresAt: defaultExpiresAt,
    );
    if (jsonProfile != null) {
      return [jsonProfile.withExpiresAt(defaultExpiresAt)];
    }

    final jsonLinks = _tryParseJsonLinks(
      text,
      defaultExpiresAt: defaultExpiresAt,
    );
    if (jsonLinks.isNotEmpty) {
      return jsonLinks;
    }

    final xrayProfiles = _tryParseXrayConfigs(
      text,
      defaultExpiresAt: defaultExpiresAt,
    );
    if (xrayProfiles.isNotEmpty) {
      return xrayProfiles;
    }

    final links = _extractLinks(text);
    if (links.isNotEmpty) {
      return _profilesFromLinks(links, defaultExpiresAt: defaultExpiresAt);
    }

    final decoded = _tryDecodeBase64(text);
    if (decoded != null) {
      final decodedJsonProfile = _tryParseJsonConfig(
        decoded,
        source: source,
        defaultExpiresAt: defaultExpiresAt,
      );
      if (decodedJsonProfile != null) {
        return [decodedJsonProfile];
      }

      final decodedJsonLinks = _tryParseJsonLinks(
        decoded,
        defaultExpiresAt: defaultExpiresAt,
      );
      if (decodedJsonLinks.isNotEmpty) {
        return decodedJsonLinks;
      }

      final decodedXrayProfiles = _tryParseXrayConfigs(
        decoded,
        defaultExpiresAt: defaultExpiresAt,
      );
      if (decodedXrayProfiles.isNotEmpty) {
        return decodedXrayProfiles;
      }

      final decodedLinks = _extractLinks(decoded);
      if (decodedLinks.isNotEmpty) {
        return _profilesFromLinks(
          decodedLinks,
          defaultExpiresAt: defaultExpiresAt,
        );
      }
    }

    if (_looksLikeHtml(text)) {
      throw const ProfileImportException(
        'Это HTML-страница Yurich ID. Нужна raw-подписка или включённые raw keys в Yurich Panel.',
      );
    }

    throw const ProfileImportException(
      'Не нашёл поддерживаемых ссылок. Поддерживаются vless://, naive+https://, hysteria://, hysteria2://, hy2:// и sing-box JSON.',
    );
  }

  VpnProfile? _tryParseJsonConfig(
    String text, {
    required String source,
    DateTime? defaultExpiresAt,
  }) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        if (decoded.containsKey('inbounds') &&
            decoded.containsKey('outbounds')) {
          return VpnProfile(
            id: _stableId(text),
            name: 'Sing-box config',
            kind: VpnProfileKind.singBoxConfig,
            originalInput: source,
            rawConfig: const JsonEncoder.withIndent('  ').convert(decoded),
            expiresAt: defaultExpiresAt,
          );
        }
      }
    } on FormatException {
      return null;
    }

    return null;
  }

  List<VpnProfile> _tryParseJsonLinks(
    String text, {
    DateTime? defaultExpiresAt,
  }) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final links = decoded['links'];
        if (links is List) {
          return _profilesFromLinks(
            links.whereType<String>().toList(),
            defaultExpiresAt:
                _extractExpiryFromJson(decoded) ?? defaultExpiresAt,
          );
        }
      }
      if (decoded is List) {
        return _profilesFromLinks(
          decoded.whereType<String>().toList(),
          defaultExpiresAt: defaultExpiresAt,
        );
      }
    } on FormatException {
      return const [];
    }
    return const [];
  }

  List<VpnProfile> _tryParseXrayConfigs(
    String text, {
    DateTime? defaultExpiresAt,
  }) {
    try {
      final decoded = jsonDecode(text);
      final configs = switch (decoded) {
        Map() => [decoded.cast<String, dynamic>()],
        List() =>
          decoded
              .whereType<Map>()
              .map((item) => item.cast<String, dynamic>())
              .toList(),
        _ => const <Map<String, dynamic>>[],
      };

      final profiles = <VpnProfile>[];
      for (final config in configs) {
        final outbounds = config['outbounds'];
        if (outbounds is! List) {
          continue;
        }

        for (final item in outbounds.whereType<Map>()) {
          final outbound = item.cast<String, dynamic>();
          if ((outbound['protocol'] as String?)?.toLowerCase() == 'vless') {
            profiles.add(
              _profileFromXrayVless(
                config,
                outbound,
                defaultExpiresAt:
                    _extractExpiryFromJson(config) ?? defaultExpiresAt,
              ),
            );
          }
        }
      }
      return profiles;
    } on FormatException {
      return const [];
    } on ProfileImportException {
      return const [];
    }
  }

  VpnProfile _profileFromXrayVless(
    Map<String, dynamic> config,
    Map<String, dynamic> outbound, {
    DateTime? defaultExpiresAt,
  }) {
    final settings = _asMap(outbound['settings']);
    if (settings == null) {
      throw const ProfileImportException('Xray VLESS outbound без settings.');
    }
    final vnext = settings['vnext'];
    final server = vnext is List && vnext.isNotEmpty
        ? _asMap(vnext.first)
        : null;
    if (server == null) {
      throw const ProfileImportException('Xray VLESS outbound без vnext.');
    }

    final users = server['users'];
    final user = users is List && users.isNotEmpty ? _asMap(users.first) : null;
    final uuid = user?['id'] as String?;
    final address = server['address'] as String?;
    final port = _asInt(server['port']) ?? 443;
    if (uuid == null || uuid.isEmpty || address == null || address.isEmpty) {
      throw const ProfileImportException('Xray VLESS outbound без UUID/host.');
    }

    final stream = _asMap(outbound['streamSettings']) ?? const {};
    final network = (stream['network'] as String?) ?? 'tcp';
    final security = (stream['security'] as String?) ?? 'none';
    final reality = _asMap(stream['realitySettings']);
    final tls = _asMap(stream['tlsSettings']);
    final name = (config['remarks'] as String?) ?? address;

    final query = <String, String>{
      'encryption': (user?['encryption'] as String?) ?? 'none',
      'type': network,
      'security': security,
      if ((user?['flow'] as String?)?.isNotEmpty ?? false)
        'flow': user!['flow'] as String,
      if (reality != null &&
          (reality['serverName'] as String?)?.isNotEmpty == true)
        'sni': reality['serverName'] as String,
      if (tls != null && (tls['serverName'] as String?)?.isNotEmpty == true)
        'sni': tls['serverName'] as String,
      if (reality != null &&
          (reality['fingerprint'] as String?)?.isNotEmpty == true)
        'fp': reality['fingerprint'] as String,
      if (reality != null &&
          (reality['publicKey'] as String?)?.isNotEmpty == true)
        'pbk': reality['publicKey'] as String,
      if (reality != null &&
          (reality['shortId'] as String?)?.isNotEmpty == true)
        'sid': reality['shortId'] as String,
    };

    final alpn = reality?['alpn'] ?? tls?['alpn'];
    final alpnValue = _listOrString(alpn);
    if (alpnValue.isNotEmpty) {
      query['alpn'] = alpnValue;
    }

    final uri = Uri(
      scheme: 'vless',
      userInfo: uuid,
      host: address,
      port: port,
      queryParameters: query,
      fragment: name,
    );
    return _parseVless(
      uri.toString(),
      expiresAt: _resolveExpiresAt(
        defaultValue: defaultExpiresAt,
        candidates: [_extractExpiryFromQuery(query)],
      ),
    );
  }

  List<String> _extractLinks(String text) {
    final normalized = _decodeHtmlEntities(text);
    return _linkPattern
        .allMatches(normalized)
        .map((match) => match.group(0)!)
        .map(_cleanLink)
        .toSet()
        .toList();
  }

  List<VpnProfile> _profilesFromLinks(
    List<String> links, {
    DateTime? defaultExpiresAt,
  }) {
    final profiles = <VpnProfile>[];
    final errors = <String>[];

    for (final link in links) {
      try {
        final lower = link.toLowerCase();
        if (lower.startsWith('vless://')) {
          profiles.add(_parseVless(link, expiresAt: defaultExpiresAt));
        } else if (lower.startsWith('naive+https://') ||
            lower.startsWith('naive://')) {
          profiles.add(_parseNaive(link, expiresAt: defaultExpiresAt));
        } else if (lower.startsWith('hysteria2://') ||
            lower.startsWith('hy2://')) {
          profiles.add(_parseHysteria2(link, expiresAt: defaultExpiresAt));
        } else if (lower.startsWith('hysteria://')) {
          profiles.add(_parseHysteria(link, expiresAt: defaultExpiresAt));
        }
      } on Object catch (error) {
        errors.add('$link: $error');
      }
    }

    if (profiles.isEmpty && errors.isNotEmpty) {
      throw ProfileImportException(errors.join('\n'));
    }
    return profiles;
  }

  VpnProfile _parseVless(String link, {DateTime? expiresAt}) {
    final uri = Uri.parse(link);
    final uuid = Uri.decodeComponent(uri.userInfo);
    if (uuid.isEmpty || uri.host.isEmpty) {
      throw const ProfileImportException('VLESS ссылка без UUID или host.');
    }

    final query = _query(uri);
    final security = (query['security'] ?? '').toLowerCase();
    final port = uri.hasPort ? uri.port : 443;
    final name = _displayName(uri.fragment, fallback: uri.host);
    final tls = <String, dynamic>{};

    if (security == 'reality' || security == 'tls') {
      tls['enabled'] = true;
      final sni = query['sni'] ?? query['peer'] ?? query['host'] ?? uri.host;
      if (sni.isNotEmpty) {
        tls['server_name'] = sni;
      }

      final alpn = _csv(query['alpn']);
      if (alpn.isNotEmpty) {
        tls['alpn'] = alpn;
      }

      if (_truthy(query['allowInsecure']) || _truthy(query['insecure'])) {
        tls['insecure'] = true;
      }

      final fingerprint = query['fp'] ?? query['fingerprint'];
      if (fingerprint != null && fingerprint.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
      }

      if (security == 'reality') {
        final publicKey = query['pbk'] ?? query['publicKey'];
        if (publicKey == null || publicKey.isEmpty) {
          throw const ProfileImportException(
            'Reality ссылка без pbk/publicKey.',
          );
        }
        tls['reality'] = {
          'enabled': true,
          'public_key': publicKey,
          if ((query['sid'] ?? '').isNotEmpty) 'short_id': query['sid'],
        };
      }
    }

    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': port,
      'uuid': uuid,
      if ((query['flow'] ?? '').isNotEmpty) 'flow': query['flow'],
      if (tls.isNotEmpty) 'tls': tls,
    };

    final transport = _v2rayTransport(query);
    if (transport != null) {
      outbound['transport'] = transport;
    }

    return VpnProfile(
      id: _stableId(link),
      name: name,
      kind: security == 'reality'
          ? VpnProfileKind.vlessReality
          : VpnProfileKind.vlessTls,
      originalInput: link,
      server: uri.host,
      port: port,
      outbound: outbound,
      expiresAt: _resolveExpiresAt(
        defaultValue: expiresAt,
        candidates: [_extractExpiryFromQuery(query)],
      ),
    );
  }

  VpnProfile _parseNaive(String link, {DateTime? expiresAt}) {
    final normalized = link.toLowerCase().startsWith('naive+')
        ? link.substring('naive+'.length)
        : link;
    final uri = Uri.parse(normalized);
    if (uri.host.isEmpty) {
      throw const ProfileImportException('Naive ссылка без host.');
    }

    final userParts = uri.userInfo.split(':');
    final username = userParts.isNotEmpty
        ? Uri.decodeComponent(userParts.first)
        : '';
    final password = userParts.length > 1
        ? Uri.decodeComponent(userParts.sublist(1).join(':'))
        : '';
    final query = _query(uri);
    final port = uri.hasPort ? uri.port : 443;
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': query['sni'] ?? uri.host,
    };

    final outbound = <String, dynamic>{
      'type': 'naive',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': port,
      if (username.isNotEmpty) 'username': username,
      if (password.isNotEmpty) 'password': password,
      'tls': tls,
      if (_truthy(query['quic'])) 'quic': true,
      if ((query['quic_congestion_control'] ?? '').isNotEmpty)
        'quic_congestion_control': query['quic_congestion_control'],
    };

    return VpnProfile(
      id: _stableId(link),
      name: _displayName(uri.fragment, fallback: uri.host),
      kind: VpnProfileKind.naive,
      originalInput: link,
      server: uri.host,
      port: port,
      outbound: outbound,
      expiresAt: _resolveExpiresAt(
        defaultValue: expiresAt,
        candidates: [_extractExpiryFromQuery(query)],
      ),
    );
  }

  VpnProfile _parseHysteria(String link, {DateTime? expiresAt}) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty || !uri.hasPort) {
      throw const ProfileImportException('Hysteria ссылка без host или port.');
    }

    final query = _query(uri);
    final upMbps = _asIntString(query['upmbps'] ?? query['up_mbps']);
    final downMbps = _asIntString(query['downmbps'] ?? query['down_mbps']);
    if (upMbps == null || downMbps == null) {
      throw const ProfileImportException(
        'Hysteria ссылка без upmbps/downmbps.',
      );
    }

    final tls = _tlsFromQuery(
      query,
      fallbackServerName: query['peer'] ?? uri.host,
    );
    final auth = query['auth_str'] ?? query['auth'];
    final obfsPassword = query['obfsParam'] ?? query['obfs-param'];
    final obfs = obfsPassword?.isNotEmpty == true
        ? obfsPassword
        : switch ((query['obfs'] ?? '').toLowerCase()) {
            '' || 'xplus' => null,
            final value => value,
          };

    final outbound = <String, dynamic>{
      'type': 'hysteria',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'up_mbps': upMbps,
      'down_mbps': downMbps,
      if (auth != null && auth.isNotEmpty) 'auth_str': auth,
      if ((query['auth_base64'] ?? '').isNotEmpty) 'auth': query['auth_base64'],
      if (obfs != null && obfs.isNotEmpty) 'obfs': obfs,
      'tls': tls,
    };

    return VpnProfile(
      id: _stableId(link),
      name: _displayName(uri.fragment, fallback: uri.host),
      kind: VpnProfileKind.hysteria,
      originalInput: link,
      server: uri.host,
      port: uri.port,
      outbound: outbound,
      expiresAt: _resolveExpiresAt(
        defaultValue: expiresAt,
        candidates: [_extractExpiryFromQuery(query)],
      ),
    );
  }

  VpnProfile _parseHysteria2(String link, {DateTime? expiresAt}) {
    final normalized = link.toLowerCase().startsWith('hy2://')
        ? 'hysteria2://${link.substring('hy2://'.length)}'
        : link;
    final uri = Uri.parse(normalized);
    if (uri.host.isEmpty) {
      throw const ProfileImportException('Hysteria2 ссылка без host.');
    }

    final query = _query(uri);
    final password = Uri.decodeComponent(uri.userInfo);
    if (password.isEmpty) {
      throw const ProfileImportException('Hysteria2 ссылка без auth/password.');
    }

    final upMbps = _asIntString(query['upmbps'] ?? query['up_mbps']);
    final downMbps = _asIntString(query['downmbps'] ?? query['down_mbps']);
    final outbound = <String, dynamic>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.hasPort ? uri.port : 443,
      'password': password,
      if ((query['obfs'] ?? '').toLowerCase() == 'salamander' &&
          (query['obfs-password'] ?? query['obfsParam'] ?? '').isNotEmpty)
        'obfs': {
          'type': 'salamander',
          'password': query['obfs-password'] ?? query['obfsParam'],
        },
      'tls': _tlsFromQuery(query, fallbackServerName: uri.host),
    };
    if (upMbps != null) {
      outbound['up_mbps'] = upMbps;
    }
    if (downMbps != null) {
      outbound['down_mbps'] = downMbps;
    }

    return VpnProfile(
      id: _stableId(link),
      name: _displayName(uri.fragment, fallback: uri.host),
      kind: VpnProfileKind.hysteria2,
      originalInput: link,
      server: uri.host,
      port: uri.hasPort ? uri.port : 443,
      outbound: outbound,
      expiresAt: _resolveExpiresAt(
        defaultValue: expiresAt,
        candidates: [_extractExpiryFromQuery(query)],
      ),
    );
  }

  DateTime? _extractSubscriptionExpires(HttpHeaders headers) {
    final candidates = <String>[];
    headers.forEach((name, values) {
      final key = name.toLowerCase();
      if (key == 'subscription-userinfo' ||
          key == 'subscription-expires' ||
          key == 'subscription_expires' ||
          key == 'subscription-expire' ||
          key == 'subscription_expire' ||
          key == 'subscription-expires-at' ||
          key == 'subscription_expires_at' ||
          key == 'subscriptionexpiration' ||
          key == 'subscription-expiration' ||
          key == 'subscriptionexpire' ||
          key == 'subscription-expire-at' ||
          key == 'subscription_expire_at' ||
          key == 'subscription-info' ||
          key == 'expire' ||
          key == 'expires') {
        candidates.addAll(values);
      }
    });

    for (final name in const [
      'subscription-userinfo',
      'subscription-expires',
    ]) {
      final value = headers[name];
      if (value != null && value.isNotEmpty) {
        candidates.addAll(value);
      }
    }

    for (final candidate in candidates) {
      final parsed = _extractExpiryFromString(candidate);
      if (parsed != null) {
        return parsed;
      }
      final parsedFromPairs = _extractExpiryFromPairString(candidate);
      if (parsedFromPairs != null) {
        return parsedFromPairs;
      }
    }
    return null;
  }

  DateTime? _extractExpiryFromJson(Map<String, dynamic> map) {
    final direct = _extractExpiryFromString(
      map['expires'] ??
          map['expiry'] ??
          map['expire'] ??
          map['subscription-expires'] ??
          map['subscription_expires'] ??
          map['subscription-expire'] ??
          map['subscription_expire'] ??
          map['subscription-expire-at'] ??
          map['subscription_expires_at'] ??
          map['expiresAt'] ??
          map['expires_at'] ??
          map['subscriptionExpire'] ??
          map['subscription_expire_at'],
    );
    if (direct != null) {
      return direct;
    }

    final subscription = _asMap(map['subscription']);
    if (subscription != null) {
      final nested = _extractExpiryFromJson(subscription);
      if (nested != null) {
        return nested;
      }
    }

    final userInfo = map['subscription-userinfo'];
    if (userInfo is String) {
      return _extractExpiryFromPairString(userInfo);
    }

    return null;
  }

  DateTime? _extractExpiryFromQuery(Map<String, String> query) {
    final candidateKeys = <String>[
      'expire',
      'expiry',
      'expires',
      'exp',
      'subscription-expire',
      'subscription_expire',
      'subscription-expires',
      'subscription_expires',
      'subscription-expire-at',
      'subscription_expire_at',
      'expires-at',
      'expires_at',
      'subscription-expire-time',
      'subscription_expire_time',
    ];
    for (final key in candidateKeys) {
      final parsed = _extractExpiryFromString(query[key]);
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  DateTime? _extractExpiryFromString(Object? value) {
    if (value == null) {
      return null;
    }
    final source = '$value'.trim();
    if (source.isEmpty) {
      return null;
    }

    final epochMatch = RegExp(r'^\d{9,16}$').firstMatch(source);
    if (epochMatch != null) {
      final parsed = int.tryParse(epochMatch.group(0)!);
      if (parsed == null) {
        return null;
      }
      return parsed > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(parsed, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(parsed * 1000, isUtc: true);
    }

    final parsedIso = DateTime.tryParse(source);
    if (parsedIso != null) {
      return parsedIso.isUtc ? parsedIso.toLocal() : parsedIso;
    }

    final dateMatch = RegExp(
      r'^(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})(?:[ T]|$)',
    ).firstMatch(source);
    if (dateMatch != null) {
      final parsedDate = DateTime.tryParse(dateMatch.group(1)!);
      if (parsedDate != null) {
        return parsedDate.isUtc ? parsedDate.toLocal() : parsedDate;
      }
    }
    return null;
  }

  DateTime? _extractExpiryFromPairString(String source) {
    final normalized = source.replaceAll(' ', '');
    final pairs = normalized.split(RegExp(r'[;&,]'));
    const keys = {'expire', 'expiry', 'expires', 'exp'};
    for (final pair in pairs) {
      final split = pair.split('=');
      if (split.length == 2) {
        final key = split.first.toLowerCase();
        if (keys.contains(key)) {
          final parsed = _extractExpiryFromString(split.last);
          if (parsed != null) {
            return parsed;
          }
        }
      }
    }
    return null;
  }

  DateTime? _resolveExpiresAt({
    required DateTime? defaultValue,
    required List<DateTime?> candidates,
  }) {
    for (final candidate in candidates) {
      if (candidate != null) {
        return candidate;
      }
    }
    return defaultValue;
  }

  Map<String, dynamic> _tlsFromQuery(
    Map<String, String> query, {
    required String fallbackServerName,
  }) {
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': query['sni'] ?? query['peer'] ?? fallbackServerName,
    };
    final alpn = _csv(query['alpn']);
    if (alpn.isNotEmpty) {
      tls['alpn'] = alpn;
    }
    if (_truthy(query['allowInsecure']) ||
        _truthy(query['insecure']) ||
        _truthy(query['skip-cert-verify'])) {
      tls['insecure'] = true;
    }
    return tls;
  }

  Map<String, String> _query(Uri uri) {
    return uri.queryParameters.map(
      (key, value) => MapEntry(key, Uri.decodeComponent(value)),
    );
  }

  int? _asIntString(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return int.tryParse(value.trim());
  }

  Map<String, dynamic>? _v2rayTransport(Map<String, String> query) {
    final type = (query['type'] ?? query['transport'] ?? 'tcp').toLowerCase();
    if (type == 'tcp' || type.isEmpty) {
      return null;
    }

    if (type == 'ws') {
      final headers = <String, String>{};
      final host = query['host'];
      if (host != null && host.isNotEmpty) {
        headers['Host'] = host;
      }
      return {
        'type': 'ws',
        if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
        if (headers.isNotEmpty) 'headers': headers,
      };
    }

    if (type == 'grpc') {
      return {
        'type': 'grpc',
        if ((query['serviceName'] ?? query['service_name'] ?? '').isNotEmpty)
          'service_name': query['serviceName'] ?? query['service_name'],
      };
    }

    if (type == 'http' || type == 'h2') {
      return {
        'type': 'http',
        if ((query['host'] ?? '').isNotEmpty) 'host': _csv(query['host']),
        if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
      };
    }

    throw ProfileImportException('Transport "$type" пока не поддержан.');
  }

  String? _tryDecodeBase64(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 8 ||
        !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
      return null;
    }

    var normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }

    try {
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  bool _looksLikeHtml(String text) {
    final lower = text.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.contains('<body') ||
        lower.contains('<script');
  }

  String _cleanLink(String link) {
    return link.replaceAll(RegExp(r'[)\],;]+$'), '');
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }

  String _displayName(String fragment, {required String fallback}) {
    if (fragment.isEmpty) {
      return fallback;
    }
    return Uri.decodeComponent(fragment).trim().isEmpty
        ? fallback
        : Uri.decodeComponent(fragment).trim();
  }

  List<String> _csv(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const [];
    }
    return value
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  bool _truthy(String? value) {
    if (value == null) {
      return false;
    }
    return const {'1', 'true', 'yes', 'on'}.contains(value.toLowerCase());
  }

  Map<String, dynamic>? _asMap(Object? value) {
    return value is Map ? value.cast<String, dynamic>() : null;
  }

  int? _asInt(Object? value) {
    return switch (value) {
      int() => value,
      String() => int.tryParse(value),
      _ => null,
    };
  }

  String _listOrString(Object? value) {
    return switch (value) {
      String() => value,
      List() => value.whereType<String>().join(','),
      _ => '',
    };
  }

  String _stableId(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
