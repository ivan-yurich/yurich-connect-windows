import 'dart:convert';

import '../models/vpn_profile.dart';
import 'sing_box_config_builder.dart';
import 'vless_profile_tools.dart';

class XrayConfigBuilder {
  const XrayConfigBuilder();

  bool supportsProfile(VpnProfile profile) {
    return VlessProfileTools.isVlessProfile(profile);
  }

  String build(VpnProfile profile, {bool windowsTunMode = false}) {
    if (!supportsProfile(profile)) {
      throw StateError('Xray backend пока поддерживает только VLESS profiles.');
    }
    if (windowsTunMode) {
      throw StateError(
        'Xray backend работает только в Stable Proxy Mode. Отключи Advanced TUN Mode для этого профиля.',
      );
    }
    final outbound = profile.outbound;
    if (outbound == null) {
      throw StateError('У VLESS профиля нет outbound-конфига.');
    }

    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'inbounds': [_httpInbound(), _socksInbound()],
      'outbounds': [
        _vlessOutbound(profile, outbound),
        {'protocol': 'freedom', 'tag': 'direct'},
        {'protocol': 'blackhole', 'tag': 'block'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {'type': 'field', 'ip': _privateCidrs, 'outboundTag': 'direct'},
        ],
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  Map<String, dynamic> _httpInbound() {
    return {
      'tag': 'http-in',
      'protocol': 'http',
      'listen': '127.0.0.1',
      'port': SingBoxConfigBuilder.localMixedProxyPort,
      'settings': {'timeout': 60},
      'sniffing': _sniffing(),
    };
  }

  Map<String, dynamic> _socksInbound() {
    return {
      'tag': 'socks-in',
      'protocol': 'socks',
      'listen': '127.0.0.1',
      'port': SingBoxConfigBuilder.localSocksProxyPort,
      'settings': {'auth': 'noauth', 'udp': false},
      'sniffing': _sniffing(),
    };
  }

  Map<String, dynamic> _sniffing() {
    return {
      'enabled': true,
      'destOverride': ['http', 'tls'],
      'routeOnly': false,
    };
  }

  Map<String, dynamic> _vlessOutbound(
    VpnProfile profile,
    Map<String, dynamic> outbound,
  ) {
    final server = '${profile.server ?? outbound['server'] ?? ''}'.trim();
    final port = profile.port ?? outbound['server_port'];
    final uuid = '${outbound['uuid'] ?? ''}'.trim();
    if (server.isEmpty || port is! int || uuid.isEmpty) {
      throw StateError('VLESS профиль без server/port/uuid.');
    }

    final user = <String, dynamic>{
      'id': uuid,
      'encryption': 'none',
      if ('${outbound['flow'] ?? ''}'.trim().isNotEmpty)
        'flow': outbound['flow'],
    };

    return {
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': server,
            'port': port,
            'users': [user],
          },
        ],
      },
      'streamSettings': _streamSettings(profile, outbound),
    };
  }

  Map<String, dynamic> _streamSettings(
    VpnProfile profile,
    Map<String, dynamic> outbound,
  ) {
    final transport = (outbound['transport'] as Map?)?.cast<String, dynamic>();
    final type = VlessProfileTools.normalizeImportTransportType(
      '${transport?['type'] ?? 'tcp'}',
    );
    final settings = <String, dynamic>{'network': _xrayNetwork(type)};

    final tls = (outbound['tls'] as Map?)?.cast<String, dynamic>();
    if (tls != null && tls['enabled'] == true) {
      settings.addAll(_tlsSettings(profile, tls));
    } else {
      settings['security'] = 'none';
    }

    switch (type) {
      case 'xhttp':
        settings['xhttpSettings'] = _xhttpSettings(transport);
        break;
      case 'grpc':
        settings['grpcSettings'] = {
          if ('${transport?['service_name'] ?? ''}'.trim().isNotEmpty)
            'serviceName': transport?['service_name'],
        };
        break;
      case 'ws':
        settings['wsSettings'] = {
          if ('${transport?['path'] ?? ''}'.trim().isNotEmpty)
            'path': transport?['path'],
          if (transport?['headers'] is Map) 'headers': transport?['headers'],
        };
        break;
      case 'httpupgrade':
        settings['httpupgradeSettings'] = {
          if ('${transport?['path'] ?? ''}'.trim().isNotEmpty)
            'path': transport?['path'],
          if ('${transport?['host'] ?? ''}'.trim().isNotEmpty)
            'host': transport?['host'],
        };
        break;
    }
    return settings;
  }

  String _xrayNetwork(String type) {
    return switch (type) {
      'xhttp' => 'xhttp',
      'grpc' => 'grpc',
      'ws' => 'websocket',
      'httpupgrade' => 'httpupgrade',
      _ => 'raw',
    };
  }

  Map<String, dynamic> _tlsSettings(
    VpnProfile profile,
    Map<String, dynamic> tls,
  ) {
    final reality = (tls['reality'] as Map?)?.cast<String, dynamic>();
    final serverName = '${tls['server_name'] ?? profile.server ?? ''}'.trim();
    final fingerprint = '${(tls['utls'] as Map?)?['fingerprint'] ?? ''}'.trim();
    if (reality != null && reality['enabled'] == true) {
      return {
        'security': 'reality',
        'realitySettings': {
          if (serverName.isNotEmpty) 'serverName': serverName,
          if (fingerprint.isNotEmpty) 'fingerprint': fingerprint,
          'publicKey': reality['public_key'],
          if ('${reality['short_id'] ?? ''}'.trim().isNotEmpty)
            'shortId': reality['short_id'],
        },
      };
    }

    return {
      'security': 'tls',
      'tlsSettings': {
        if (serverName.isNotEmpty) 'serverName': serverName,
        if (fingerprint.isNotEmpty) 'fingerprint': fingerprint,
        if (tls['insecure'] == true) 'allowInsecure': true,
        if (tls['alpn'] is List) 'alpn': tls['alpn'],
      },
    };
  }

  Map<String, dynamic> _xhttpSettings(Map<String, dynamic>? transport) {
    final host = VlessProfileTools.normalizeXhttpHost(transport?['host']);
    final path = VlessProfileTools.normalizeXhttpPath(transport?['path']);
    final mode = VlessProfileTools.normalizeXhttpMode(transport?['mode']);
    final extra = VlessProfileTools.normalizeXhttpExtra(transport?['extra']);
    final settings = <String, dynamic>{'path': path, 'mode': mode};
    if (host != null) {
      settings['host'] = host;
    }
    if (extra != null) {
      settings['extra'] = extra;
    }
    return settings;
  }

  static const _privateCidrs = [
    '0.0.0.0/8',
    '10.0.0.0/8',
    '100.64.0.0/10',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '224.0.0.0/4',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
  ];
}
