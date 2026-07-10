enum VpnProfileKind {
  vlessReality,
  vlessTls,
  naive,
  hysteria,
  hysteria2,
  singBoxConfig,
}

extension VpnProfileKindLabel on VpnProfileKind {
  String get label => switch (this) {
    VpnProfileKind.vlessReality => 'VLESS Reality',
    VpnProfileKind.vlessTls => 'VLESS TLS',
    VpnProfileKind.naive => 'NaiveProxy',
    VpnProfileKind.hysteria => 'Hysteria',
    VpnProfileKind.hysteria2 => 'Hysteria2',
    VpnProfileKind.singBoxConfig => 'Sing-box',
  };
}

enum VpnCoreBackend { auto, singBox, xray }

extension VpnCoreBackendLabel on VpnCoreBackend {
  String get label => switch (this) {
    VpnCoreBackend.auto => 'Yurich Core Auto',
    VpnCoreBackend.singBox => 'sing-box',
    VpnCoreBackend.xray => 'Xray-core',
  };
}

class VpnProfile {
  const VpnProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.originalInput,
    this.server,
    this.port,
    this.outbound,
    this.rawConfig,
    this.expiresAt,
    this.subscriptionSource,
    this.coreBackend = VpnCoreBackend.auto,
  });

  final String id;
  final String name;
  final VpnProfileKind kind;
  final String originalInput;
  final String? server;
  final int? port;
  final Map<String, dynamic>? outbound;
  final String? rawConfig;
  final DateTime? expiresAt;
  final String? subscriptionSource;
  final VpnCoreBackend coreBackend;

  String get endpoint {
    if (server == null || server!.isEmpty) {
      return kind.label;
    }
    return port == null ? server! : '$server:$port';
  }

  VpnProfile withId(String value) {
    if (value == id) {
      return this;
    }
    return VpnProfile(
      id: value,
      name: name,
      kind: kind,
      originalInput: originalInput,
      server: server,
      port: port,
      outbound: outbound,
      rawConfig: rawConfig,
      expiresAt: expiresAt,
      subscriptionSource: subscriptionSource,
      coreBackend: coreBackend,
    );
  }

  VpnProfile withExpiresAt(DateTime? value) {
    if (value == null || expiresAt != null) {
      return this;
    }
    return VpnProfile(
      id: id,
      name: name,
      kind: kind,
      originalInput: originalInput,
      server: server,
      port: port,
      outbound: outbound,
      rawConfig: rawConfig,
      expiresAt: value,
      subscriptionSource: subscriptionSource,
      coreBackend: coreBackend,
    );
  }

  VpnProfile withSubscriptionSource(String? value) {
    if (value == null || value.trim().isEmpty) {
      return this;
    }
    return VpnProfile(
      id: id,
      name: name,
      kind: kind,
      originalInput: originalInput,
      server: server,
      port: port,
      outbound: outbound,
      rawConfig: rawConfig,
      expiresAt: expiresAt,
      subscriptionSource: value.trim(),
      coreBackend: coreBackend,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'kind': kind.name,
      'originalInput': originalInput,
      'server': server,
      'port': port,
      'outbound': outbound,
      'rawConfig': rawConfig,
      'expiresAt': expiresAt?.toIso8601String(),
      'subscriptionSource': subscriptionSource,
      'coreBackend': coreBackend.name,
    };
  }

  factory VpnProfile.fromJson(Map<String, dynamic> json) {
    final kindName =
        json['kind'] as String? ?? VpnProfileKind.vlessReality.name;
    final coreBackendName =
        json['coreBackend'] as String? ?? VpnCoreBackend.auto.name;
    return VpnProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: VpnProfileKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => VpnProfileKind.vlessReality,
      ),
      originalInput: json['originalInput'] as String? ?? '',
      server: json['server'] as String?,
      port: json['port'] as int?,
      outbound: (json['outbound'] as Map?)?.cast<String, dynamic>(),
      rawConfig: json['rawConfig'] as String?,
      subscriptionSource: json['subscriptionSource'] as String?,
      expiresAt: json['expiresAt'] == null
          ? null
          : DateTime.tryParse(json['expiresAt'] as String),
      coreBackend: VpnCoreBackend.values.firstWhere(
        (value) => value.name == coreBackendName,
        orElse: () => VpnCoreBackend.auto,
      ),
    );
  }
}
