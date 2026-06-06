import 'dart:convert';

import '../models/vpn_profile.dart';

enum SingBoxConfigTarget { android, windows }

enum NaiveOutboundMode { auto, externalCore, native, httpConnect }

class SingBoxConfigBuilder {
  static const windowsClashApiPort = 19090;
  static const localMixedProxyPort = 20808;
  static const naiveProxySocksPort = 20809;
  static const russianGeoIpRuleSet = 'geoip-ru';
  static const russianGeoIpRuleSetUrl =
      'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs';
  static const russianDirectDomains = [
    '.ru',
    '.рф',
    '.su',
    'timeweb.cloud',
    'timeweb.com',
    'yandex.net',
    'yandex.com',
    'vk.com',
    'vk.ru',
    'ok.ru',
    'mail.ru',
    'mycdn.me',
    'gosuslugi.ru',
    'sberbank.ru',
    'tbank.ru',
    'alfabank.ru',
    'avito.ru',
    'ozon.ru',
    'wildberries.ru',
  ];
  static const windowsLocalDnsQueryTypes = ['PTR', 'SRV', 'HTTPS', 'SVCB'];

  String build(
    VpnProfile profile, {
    SingBoxConfigTarget target = SingBoxConfigTarget.android,
    NaiveOutboundMode naiveMode = NaiveOutboundMode.auto,
    List<String> splitTunnelExcludedProcesses = const [],
  }) {
    if (profile.kind == VpnProfileKind.singBoxConfig) {
      final raw = profile.rawConfig;
      if (raw == null || raw.trim().isEmpty) {
        throw StateError('Пустой sing-box config.');
      }
      return raw;
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      throw StateError('У профиля нет outbound-конфига.');
    }

    final proxyOutbound =
        jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    proxyOutbound['tag'] = 'proxy';
    _normalizeOutbound(profile, proxyOutbound, naiveMode);
    _applyDialStability(proxyOutbound, target);
    final usesNaiveProxyCore =
        target == SingBoxConfigTarget.windows &&
        proxyOutbound['type'] == 'socks';
    final rejectQuicUdp =
        profile.kind == VpnProfileKind.naive ||
        (target == SingBoxConfigTarget.windows &&
            (profile.kind == VpnProfileKind.vlessReality ||
                profile.kind == VpnProfileKind.vlessTls));
    final rejectAllUdp =
        profile.kind == VpnProfileKind.naive && proxyOutbound['type'] == 'http';
    final excludedProcesses = _normalizeProcessNames(
      splitTunnelExcludedProcesses,
    );

    final config = <String, dynamic>{
      'log': {'level': 'warn', 'timestamp': true},
      'dns': _dnsConfig(target),
      'inbounds': [_tunInbound(target), _mixedInbound()],
      'outbounds': [
        proxyOutbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'action': 'sniff'},
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'protocol': 'dns'},
              {'port': 53},
            ],
            'action': 'hijack-dns',
          },
          if (target == SingBoxConfigTarget.windows &&
              excludedProcesses.isNotEmpty)
            {'process_name': excludedProcesses, 'outbound': 'direct'},
          if (usesNaiveProxyCore)
            {
              'process_name': ['naive.exe'],
              'outbound': 'direct',
            },
          if (target == SingBoxConfigTarget.windows) ...[
            {'ip_version': 6, 'action': 'reject'},
            {'domain_suffix': russianDirectDomains, 'outbound': 'direct'},
            {'rule_set': russianGeoIpRuleSet, 'outbound': 'direct'},
          ],
          _unsupportedUdpRule(
            rejectQuicUdp: rejectQuicUdp,
            rejectAllUdp: rejectAllUdp,
          ),
          {'ip_is_private': true, 'outbound': 'direct'},
        ],
        if (target == SingBoxConfigTarget.windows)
          'rule_set': [
            {
              'type': 'remote',
              'tag': russianGeoIpRuleSet,
              'format': 'binary',
              'url': russianGeoIpRuleSetUrl,
            },
          ],
        'default_domain_resolver': _domainResolver(target),
        'auto_detect_interface': true,
        'find_process':
            target == SingBoxConfigTarget.windows &&
            (excludedProcesses.isNotEmpty || usesNaiveProxyCore),
        'final': 'proxy',
      },
    };

    if (target == SingBoxConfigTarget.windows) {
      config['experimental'] = {
        'cache_file': {'enabled': true},
        'clash_api': {
          'external_controller': '127.0.0.1:$windowsClashApiPort',
          'secret': '',
        },
      };
    }

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  Map<String, dynamic> _tunInbound(SingBoxConfigTarget target) {
    final inbound = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'address': target == SingBoxConfigTarget.android
          ? ['172.19.0.1/30']
          : ['172.19.0.1/30'],
      'mtu': target == SingBoxConfigTarget.android ? 1380 : 1500,
      'auto_route': true,
      'strict_route': true,
      'stack': target == SingBoxConfigTarget.android ? 'gvisor' : 'system',
      if (target == SingBoxConfigTarget.android)
        'endpoint_independent_nat': false,
    };
    if (target == SingBoxConfigTarget.windows) {
      inbound['interface_name'] = 'YurichConnect';
    }
    if (target == SingBoxConfigTarget.android) {
      inbound['interface_name'] = 'tun0';
    }
    if (target == SingBoxConfigTarget.android) {
      inbound['exclude_package'] = ['online.dnsai.ivanvpn'];
    }
    return inbound;
  }

  Map<String, dynamic> _mixedInbound() {
    return {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': localMixedProxyPort,
    };
  }

  Map<String, dynamic> _dnsConfig(SingBoxConfigTarget target) {
    final servers = <Map<String, dynamic>>[
      {'type': 'local', 'tag': 'local-dns'},
      if (target == SingBoxConfigTarget.android)
        {
          'type': 'fakeip',
          'tag': 'fakeip',
          'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18',
        },
      if (target == SingBoxConfigTarget.android)
        {
          'type': 'https',
          'tag': 'global-dns',
          'server': '1.1.1.1',
          'server_port': 443,
          'path': '/dns-query',
          'tls': {'enabled': true, 'server_name': 'cloudflare-dns.com'},
          'detour': 'proxy',
        },
    ];

    return {
      'servers': servers,
      if (target == SingBoxConfigTarget.android)
        'rules': [
          {
            'query_type': ['A', 'AAAA'],
            'action': 'route',
            'server': 'fakeip',
          },
        ],
      if (target == SingBoxConfigTarget.windows)
        'rules': [
          {
            'query_type': windowsLocalDnsQueryTypes,
            'action': 'route',
            'server': 'local-dns',
          },
          {
            'domain_suffix': russianDirectDomains,
            'action': 'route',
            'server': 'local-dns',
          },
        ],
      'strategy': 'ipv4_only',
      'cache_capacity': target == SingBoxConfigTarget.windows ? 32768 : 8192,
      'reverse_mapping': true,
      'final': target == SingBoxConfigTarget.windows
          ? 'local-dns'
          : 'global-dns',
    };
  }

  Map<String, dynamic> _unsupportedUdpRule({
    required bool rejectQuicUdp,
    required bool rejectAllUdp,
  }) {
    return {
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {'port': 853},
        {'protocol': 'stun'},
        {'protocol': 'icmp'},
        if (rejectQuicUdp) {'network': 'udp', 'port': 443},
        if (rejectAllUdp) {'network': 'udp'},
      ],
      'action': 'reject',
    };
  }

  List<String> _normalizeProcessNames(List<String> values) {
    final result = <String>{};
    for (final value in values) {
      final cleaned = value.trim();
      if (cleaned.isEmpty || cleaned.contains('\\') || cleaned.contains('/')) {
        continue;
      }
      result.add(cleaned);
    }
    return result.toList(growable: false);
  }

  void _applyDialStability(
    Map<String, dynamic> proxyOutbound,
    SingBoxConfigTarget target,
  ) {
    proxyOutbound.putIfAbsent('connect_timeout', () => '8s');
    proxyOutbound.putIfAbsent('tcp_keep_alive', () => '3m');
    proxyOutbound.putIfAbsent('tcp_keep_alive_interval', () => '30s');
    if (target == SingBoxConfigTarget.windows) {
      proxyOutbound['domain_resolver'] = _normalizeDomainResolver(
        proxyOutbound['domain_resolver'],
      );
    } else {
      proxyOutbound.putIfAbsent('domain_resolver', () => 'local-dns');
    }
    if (target == SingBoxConfigTarget.android) {
      proxyOutbound.putIfAbsent('network_strategy', () => 'fallback');
      proxyOutbound.putIfAbsent('fallback_delay', () => '300ms');
    }
  }

  Object _domainResolver(SingBoxConfigTarget target) {
    if (target == SingBoxConfigTarget.windows) {
      return {'server': 'local-dns', 'strategy': 'ipv4_only'};
    }
    return 'local-dns';
  }

  Map<String, dynamic> _normalizeDomainResolver(Object? resolver) {
    if (resolver is Map) {
      final normalized = resolver.cast<String, dynamic>();
      normalized['strategy'] = 'ipv4_only';
      return normalized;
    }
    final server = resolver is String && resolver.isNotEmpty
        ? resolver
        : 'local-dns';
    return {'server': server, 'strategy': 'ipv4_only'};
  }

  void _normalizeOutbound(
    VpnProfile profile,
    Map<String, dynamic> proxyOutbound,
    NaiveOutboundMode naiveMode,
  ) {
    if (profile.kind == VpnProfileKind.vlessReality ||
        profile.kind == VpnProfileKind.vlessTls) {
      if (proxyOutbound['network'] == 'tcp') {
        proxyOutbound.remove('network');
      }
      return;
    }

    if (profile.kind != VpnProfileKind.naive) {
      return;
    }

    final originalTls = (proxyOutbound['tls'] as Map?)?.cast<String, dynamic>();
    final outboundType = (proxyOutbound['type'] as String?)?.toLowerCase();
    if (naiveMode == NaiveOutboundMode.externalCore) {
      proxyOutbound
        ..clear()
        ..addAll({
          'type': 'socks',
          'tag': 'proxy',
          'server': '127.0.0.1',
          'server_port': naiveProxySocksPort,
          'version': '5',
          'network': 'tcp',
        });
      return;
    }

    final useHttpConnect =
        naiveMode == NaiveOutboundMode.httpConnect ||
        (naiveMode == NaiveOutboundMode.auto && outboundType == 'http');
    if (!useHttpConnect) {
      proxyOutbound['type'] = 'naive';
      return;
    }

    proxyOutbound['type'] = 'http';
    proxyOutbound.remove('extra_headers');
    proxyOutbound.remove('insecure_concurrency');
    proxyOutbound.remove('quic');
    proxyOutbound.remove('quic_congestion_control');
    proxyOutbound.remove('udp_over_tcp');

    final normalizedTls = <String, dynamic>{};
    for (final key in const [
      'server_name',
      'certificate',
      'certificate_path',
      'ech',
    ]) {
      final value = originalTls?[key];
      if (value != null) {
        normalizedTls[key] = value;
      }
    }

    normalizedTls['enabled'] = true;
    normalizedTls.putIfAbsent(
      'server_name',
      () => profile.server ?? proxyOutbound['server'],
    );
    proxyOutbound['tls'] = normalizedTls;
  }

  String buildNaiveProxyConfig(VpnProfile profile) {
    if (profile.kind != VpnProfileKind.naive || profile.outbound == null) {
      throw StateError('NaiveProxy config requires a Naive profile.');
    }

    final outbound = profile.outbound!;
    final server = profile.server ?? outbound['server'];
    final port = profile.port ?? outbound['server_port'] ?? 443;
    if (server == null || '$server'.isEmpty) {
      throw StateError('Naive profile has no server.');
    }

    final username = Uri.encodeComponent('${outbound['username'] ?? ''}');
    final password = Uri.encodeComponent('${outbound['password'] ?? ''}');
    final userInfo = username.isEmpty
        ? ''
        : password.isEmpty
        ? '$username@'
        : '$username:$password@';
    final scheme = outbound['quic'] == true ? 'quic' : 'https';

    return const JsonEncoder.withIndent('  ').convert({
      'listen': 'socks://127.0.0.1:$naiveProxySocksPort',
      'proxy': '$scheme://$userInfo$server:$port',
      'log': '',
    });
  }
}
