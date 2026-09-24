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
    this.variantGroup,
    this.variantRole,
    this.variantStrategy,
    this.variantPriority,
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
  final String? variantGroup;
  final String? variantRole;
  final String? variantStrategy;
  final int? variantPriority;

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
      variantGroup: variantGroup,
      variantRole: variantRole,
      variantStrategy: variantStrategy,
      variantPriority: variantPriority,
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
      variantGroup: variantGroup,
      variantRole: variantRole,
      variantStrategy: variantStrategy,
      variantPriority: variantPriority,
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
      variantGroup: variantGroup,
      variantRole: variantRole,
      variantStrategy: variantStrategy,
      variantPriority: variantPriority,
    );
  }

  VpnProfile copyWith({
    String? id,
    String? name,
    VpnProfileKind? kind,
    String? originalInput,
    String? server,
    int? port,
    Map<String, dynamic>? outbound,
    String? rawConfig,
    DateTime? expiresAt,
    String? subscriptionSource,
    VpnCoreBackend? coreBackend,
    String? variantGroup,
    String? variantRole,
    String? variantStrategy,
    int? variantPriority,
  }) {
    return VpnProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      originalInput: originalInput ?? this.originalInput,
      server: server ?? this.server,
      port: port ?? this.port,
      outbound: outbound ?? this.outbound,
      rawConfig: rawConfig ?? this.rawConfig,
      expiresAt: expiresAt ?? this.expiresAt,
      subscriptionSource: subscriptionSource ?? this.subscriptionSource,
      coreBackend: coreBackend ?? this.coreBackend,
      variantGroup: variantGroup ?? this.variantGroup,
      variantRole: variantRole ?? this.variantRole,
      variantStrategy: variantStrategy ?? this.variantStrategy,
      variantPriority: variantPriority ?? this.variantPriority,
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
      'variantGroup': variantGroup,
      'variantRole': variantRole,
      'variantStrategy': variantStrategy,
      'variantPriority': variantPriority,
    };
  }

  factory VpnProfile.fromJson(Map<String, dynamic> json) {
    final kindName =
        json['kind'] as String? ?? VpnProfileKind.vlessReality.name;
    final coreBackendName =
        json['coreBackend'] as String? ?? VpnCoreBackend.auto.name;
    int? readInt(String key) {
      final value = json[key];
      return switch (value) {
        int() => value,
        num() => value.toInt(),
        String() => int.tryParse(value),
        _ => null,
      };
    }

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
      variantGroup: json['variantGroup'] as String?,
      variantRole: json['variantRole'] as String?,
      variantStrategy: json['variantStrategy'] as String?,
      variantPriority: readInt('variantPriority'),
    );
  }
}
