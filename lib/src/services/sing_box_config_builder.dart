import 'dart:convert';

import '../models/vpn_profile.dart';

enum SingBoxConfigTarget { android, windows }

class SingBoxConfigBuilder {
  static const windowsClashApiPort = 19090;
  static const localMixedProxyPort = 20808;
  static const russianGeoIpRuleSet = 'geoip-ru';
  static const russianGeoIpRuleSetUrl =
      'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs';

  String build(
    VpnProfile profile, {
    SingBoxConfigTarget target = SingBoxConfigTarget.android,
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
    _normalizeOutbound(profile, proxyOutbound);
    _applyDialStability(proxyOutbound, target);
    final rejectUnsupportedUdp = profile.kind == VpnProfileKind.naive;
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
          if (target == SingBoxConfigTarget.windows) ...[
            {
              'domain_suffix': ['.ru', '.рф', '.su'],
              'outbound': 'direct',
            },
            {'rule_set': russianGeoIpRuleSet, 'outbound': 'direct'},
          ],
          _unsupportedUdpRule(rejectUnsupportedUdp),
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
        'default_domain_resolver': 'local-dns',
        'auto_detect_interface': true,
        'find_process':
            target == SingBoxConfigTarget.windows &&
            excludedProcesses.isNotEmpty,
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
      'mtu': 1380,
      'auto_route': true,
      'strict_route': true,
      'stack': target == SingBoxConfigTarget.android ? 'gvisor' : 'mixed',
      if (target == SingBoxConfigTarget.android)
        'endpoint_independent_nat': false,
    };
    if (target == SingBoxConfigTarget.windows) {
      inbound['interface_name'] = 'AurumVPN';
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
      if (target == SingBoxConfigTarget.windows)
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
      'strategy': target == SingBoxConfigTarget.android
          ? 'ipv4_only'
          : 'prefer_ipv4',
      'cache_capacity': 8192,
      'reverse_mapping': true,
      'final': 'global-dns',
    };
  }

  Map<String, dynamic> _unsupportedUdpRule(bool rejectAllUdp) {
    return {
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {'port': 853},
        {'protocol': 'stun'},
        {'protocol': 'icmp'},
        if (rejectAllUdp) {'network': 'udp', 'port': 443},
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
    proxyOutbound.putIfAbsent('domain_resolver', () => 'local-dns');
    if (target == SingBoxConfigTarget.android) {
      proxyOutbound.putIfAbsent('network_strategy', () => 'fallback');
      proxyOutbound.putIfAbsent('fallback_delay', () => '300ms');
    }
  }

  void _normalizeOutbound(
    VpnProfile profile,
    Map<String, dynamic> proxyOutbound,
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
}
