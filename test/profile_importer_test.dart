import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn_windows/src/models/vpn_profile.dart';
import 'package:aurum_vpn_windows/src/services/profile_importer.dart';
import 'package:aurum_vpn_windows/src/services/sing_box_config_builder.dart';

void main() {
  test('imports VLESS Reality link', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=abc123&sid=01#Reality';

    final profiles = await ProfileImporter().importFromText(link);

    expect(profiles, hasLength(1));
    expect(profiles.first.kind, VpnProfileKind.vlessReality);
    expect(profiles.first.outbound?['type'], 'vless');
    expect(profiles.first.outbound?['network'], isNull);
    expect(profiles.first.outbound?['tls']['reality']['public_key'], 'abc123');
  });

  test('imports NaiveProxy link', () async {
    const link = 'naive+https://example.com:pass@example.com:443#Naive';

    final profiles = await ProfileImporter().importFromText(link);
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profiles.first))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profiles, hasLength(1));
    expect(profiles.first.kind, VpnProfileKind.naive);
    expect(profiles.first.outbound?['username'], 'example.com');
    expect(profiles.first.outbound?['password'], 'pass');
    expect(proxy['type'], 'naive');
    expect(proxy['tls'], {'enabled': true, 'server_name': 'example.com'});
    final dnsServers =
        (config['dns'] as Map<String, dynamic>)['servers'] as List;
    expect(dnsServers.first, {'type': 'local', 'tag': 'local-dns'});
    expect(dnsServers[1], {
      'type': 'fakeip',
      'tag': 'fakeip',
      'inet4_range': '198.18.0.0/15',
      'inet6_range': 'fc00::/18',
    });
    expect(dnsServers[2], {
      'type': 'https',
      'tag': 'global-dns',
      'server': '1.1.1.1',
      'server_port': 443,
      'path': '/dns-query',
      'tls': {'enabled': true, 'server_name': 'cloudflare-dns.com'},
      'detour': 'proxy',
    });
    expect((config['dns'] as Map<String, dynamic>)['rules'], [
      {
        'query_type': ['A', 'AAAA'],
        'action': 'route',
        'server': 'fakeip',
      },
    ]);
    expect((config['dns'] as Map<String, dynamic>)['final'], 'global-dns');

    final inbounds = (config['inbounds'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final tunInbound = inbounds.firstWhere(
      (inbound) => inbound['type'] == 'tun',
    );
    expect(tunInbound['address'], ['172.19.0.1/30']);
    expect(tunInbound['mtu'], 1380);
    expect(tunInbound['interface_name'], 'tun0');
    expect(tunInbound['strict_route'], isTrue);
    expect(tunInbound['stack'], 'gvisor');
    expect(tunInbound['endpoint_independent_nat'], isFalse);
    expect(tunInbound['exclude_package'], ['online.dnsai.ivanvpn']);
    expect(
      inbounds.any(
        (inbound) =>
            inbound['type'] == 'mixed' &&
            inbound['listen'] == '127.0.0.1' &&
            inbound['listen_port'] == SingBoxConfigBuilder.localMixedProxyPort,
      ),
      isTrue,
    );
    expect(
      (config['outbounds'] as List).whereType<Map<String, dynamic>>().map(
        (outbound) => outbound['type'],
      ),
      isNot(contains('dns')),
    );
    expect(
      ((config['route'] as Map<String, dynamic>)['rules'] as List)
          .whereType<Map<String, dynamic>>()
          .first,
      {'action': 'sniff'},
    );
    final routeRules =
        ((config['route'] as Map<String, dynamic>)['rules'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
    expect(
      routeRules.any(
        (rule) =>
            rule['action'] == 'hijack-dns' &&
            (rule['rules'] as List).whereType<Map>().any(
              (nested) => nested['protocol'] == 'dns',
            ),
      ),
      isTrue,
    );
    expect(
      routeRules.any(
        (rule) =>
            rule['action'] == 'reject' &&
            (rule['rules'] as List).whereType<Map>().any(
              (nested) => nested['port'] == 853,
            ) &&
            (rule['rules'] as List).whereType<Map>().any(
              (nested) => nested['protocol'] == 'icmp',
            ),
      ),
      isTrue,
    );
    final rejectRule = routeRules.firstWhere(
      (rule) => rule['action'] == 'reject',
    );
    expect(
      (rejectRule['rules'] as List).whereType<Map>().any(
        (nested) => nested['network'] == 'udp' && nested.length == 1,
      ),
      isTrue,
    );
    expect(
      (rejectRule['rules'] as List).whereType<Map>().any(
        (nested) => nested['network'] == 'udp' && nested['port'] == 443,
      ),
      isTrue,
    );
    expect(routeRules.any((rule) => rule['ip_is_private'] == true), isTrue);
    expect(
      (config['route'] as Map<String, dynamic>)['default_domain_resolver'],
      'local-dns',
    );
    expect(
      (config['route'] as Map<String, dynamic>)['auto_detect_interface'],
      isTrue,
    );
    expect((config['route'] as Map<String, dynamic>)['find_process'], isFalse);
    expect((config['dns'] as Map<String, dynamic>)['cache_capacity'], 8192);
    expect((config['dns'] as Map<String, dynamic>)['reverse_mapping'], isTrue);
    expect((config['dns'] as Map<String, dynamic>)['strategy'], 'ipv4_only');
    expect(proxy['connect_timeout'], '8s');
    expect(proxy['tcp_keep_alive'], '3m');
    expect(proxy['tcp_keep_alive_interval'], '30s');
    expect(proxy['domain_resolver'], 'local-dns');
    expect(proxy['network_strategy'], 'fallback');
    expect(proxy['fallback_delay'], '300ms');
    expect(proxy['quic'], isNull);
    expect(proxy['quic_congestion_control'], isNull);
    expect(proxy['udp_over_tcp'], isNull);
  });

  test('can use HTTPS CONNECT fallback for Naive profiles', () async {
    const link = 'naive+https://example.com:pass@example.com:443#Naive';

    final profiles = await ProfileImporter().importFromText(link);
    final config =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profiles.first,
                naiveMode: NaiveOutboundMode.httpConnect,
              ),
            )
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(proxy['type'], 'http');
    expect(proxy['tls'], {'enabled': true, 'server_name': 'example.com'});
    expect(proxy['quic'], isNull);
    expect(proxy['quic_congestion_control'], isNull);
    expect(proxy['udp_over_tcp'], isNull);
  });

  test('normalizes legacy Naive TLS fields from saved profiles', () {
    const profile = VpnProfile(
      id: 'legacy-naive',
      name: 'Legacy Naive',
      kind: VpnProfileKind.naive,
      originalInput: 'naive+https://user:pass@example.com:443',
      server: 'example.com',
      port: 443,
      outbound: {
        'type': 'naive',
        'server': 'example.com',
        'server_port': 443,
        'username': 'user',
        'password': 'pass',
        'tls': {
          'enabled': true,
          'server_name': 'example.com',
          'insecure': true,
        },
      },
    );

    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(proxy['type'], 'naive');
    expect(proxy['tls'], {
      'enabled': true,
      'server_name': 'example.com',
      'insecure': true,
    });
  });

  test('normalizes legacy VLESS tcp-only outbounds from saved profiles', () {
    const profile = VpnProfile(
      id: 'legacy-vless',
      name: 'Legacy VLESS',
      kind: VpnProfileKind.vlessReality,
      originalInput: 'vless://legacy',
      server: 'example.com',
      port: 443,
      outbound: {
        'type': 'vless',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'network': 'tcp',
      },
    );

    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(proxy['network'], isNull);
    final routeRules =
        ((config['route'] as Map<String, dynamic>)['rules'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
    final rejectRule = routeRules.firstWhere(
      (rule) => rule['action'] == 'reject',
    );

    expect(
      (rejectRule['rules'] as List).whereType<Map>().any(
        (nested) => nested['network'] == 'udp' && nested.length == 1,
      ),
      isFalse,
    );
  });

  test('builds Windows TUN config without Android package exclusions', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=abc123&sid=01#Reality';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profile,
                target: SingBoxConfigTarget.windows,
                splitTunnelExcludedProcesses: const [
                  'chrome.exe',
                  'bad/path.exe',
                ],
              ),
            )
            as Map<String, dynamic>;
    final tunInbound =
        (config['inbounds'] as List).first as Map<String, dynamic>;
    final route = config['route'] as Map<String, dynamic>;
    final routeRules = (route['rules'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();

    expect(tunInbound['interface_name'], 'AurumVPN');
    expect(tunInbound['exclude_package'], isNull);
    expect(tunInbound['mtu'], 1380);
    expect(route['find_process'], isTrue);
    expect(
      routeRules.any((rule) {
        final processName = rule['process_name'];
        return rule['outbound'] == 'direct' &&
            processName is List &&
            processName.contains('chrome.exe');
      }),
      isTrue,
    );
    expect((config['experimental'] as Map<String, dynamic>)['clash_api'], {
      'external_controller':
          '127.0.0.1:${SingBoxConfigBuilder.windowsClashApiPort}',
      'secret': '',
    });
    expect((config['experimental'] as Map<String, dynamic>)['cache_file'], {
      'enabled': true,
    });
    expect((config['dns'] as Map<String, dynamic>)['servers'].first, {
      'type': 'local',
      'tag': 'local-dns',
    });
    expect((config['dns'] as Map<String, dynamic>)['servers'][1], {
      'type': 'https',
      'tag': 'global-dns',
      'server': '1.1.1.1',
      'server_port': 443,
      'path': '/dns-query',
      'tls': {'enabled': true, 'server_name': 'cloudflare-dns.com'},
      'detour': 'proxy',
    });
    expect((config['dns'] as Map<String, dynamic>)['final'], 'global-dns');
    expect(route['rule_set'], [
      {
        'type': 'remote',
        'tag': SingBoxConfigBuilder.russianGeoIpRuleSet,
        'format': 'binary',
        'url': SingBoxConfigBuilder.russianGeoIpRuleSetUrl,
      },
    ]);
    expect(
      routeRules.any(
        (rule) =>
            rule['outbound'] == 'direct' &&
            rule['domain_suffix'] is List &&
            (rule['domain_suffix'] as List).contains('.ru') &&
            (rule['domain_suffix'] as List).contains('.рф'),
      ),
      isTrue,
    );
    expect(
      routeRules.any(
        (rule) =>
            rule['outbound'] == 'direct' &&
            rule['rule_set'] == SingBoxConfigBuilder.russianGeoIpRuleSet,
      ),
      isTrue,
    );
  });

  test('imports base64 subscription list', () async {
    const raw =
        'naive+https://user:pass@example.com:443#Naive\nvless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&pbk=abc123#Reality';
    final encoded = base64.encode(utf8.encode(raw));

    final profiles = await ProfileImporter().importFromText(encoded);

    expect(profiles, hasLength(2));
  });

  test('imports Remnawave Xray JSON subscription', () async {
    final payload = jsonEncode([
      {
        'remarks': 'Russia',
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'dns-ai.online',
                  'port': 443,
                  'users': [
                    {
                      'id': '11111111-1111-4111-8111-111111111111',
                      'encryption': 'none',
                      'flow': 'xtls-rprx-vision',
                    },
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'serverName': 'dns-ai.online',
                'publicKey': 'abc123',
                'shortId': '01',
                'fingerprint': 'chrome',
              },
            },
          },
        ],
      },
    ]);

    final profiles = await ProfileImporter().importFromText(payload);

    expect(profiles, hasLength(1));
    expect(profiles.first.kind, VpnProfileKind.vlessReality);
    expect(profiles.first.originalInput, startsWith('vless://'));
    expect(profiles.first.outbound?['tls']['reality']['public_key'], 'abc123');
  });
}
