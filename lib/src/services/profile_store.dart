import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/vpn_profile.dart';

enum WindowsConnectionMode {
  stableProxy('stableProxy'),
  advancedTun('advancedTun');

  const WindowsConnectionMode(this.code);

  final String code;

  static WindowsConnectionMode fromCode(String? code) {
    return values.firstWhere(
      (mode) => mode.code == code,
      orElse: () => WindowsConnectionMode.stableProxy,
    );
  }
}

class ProfileRuntimeStats {
  const ProfileRuntimeStats({
    this.successes = 0,
    this.failures = 0,
    this.consecutiveFailures = 0,
    this.totalStartMs = 0,
    this.lastSuccessAt,
    this.lastFailureAt,
    this.lastFailureReason,
  });

  final int successes;
  final int failures;
  final int consecutiveFailures;
  final int totalStartMs;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final String? lastFailureReason;

  int get averageStartMs => successes <= 0 ? 0 : totalStartMs ~/ successes;

  int get score {
    var value = 100 - (consecutiveFailures * 18) - (failures * 4);
    if (averageStartMs > 8000) {
      value -= 15;
    } else if (averageStartMs > 4000) {
      value -= 8;
    }
    if (successes >= 3 && consecutiveFailures == 0) {
      value += successes.clamp(0, 10).toInt();
    }
    return value.clamp(0, 100).toInt();
  }

  bool get unstable => consecutiveFailures >= 2 || score < 55;

  ProfileRuntimeStats recordSuccess(Duration startDuration) {
    return ProfileRuntimeStats(
      successes: successes + 1,
      failures: failures,
      consecutiveFailures: 0,
      totalStartMs: totalStartMs + startDuration.inMilliseconds,
      lastSuccessAt: DateTime.now(),
      lastFailureAt: lastFailureAt,
      lastFailureReason: lastFailureReason,
    );
  }

  ProfileRuntimeStats recordFailure(String reason) {
    return ProfileRuntimeStats(
      successes: successes,
      failures: failures + 1,
      consecutiveFailures: consecutiveFailures + 1,
      totalStartMs: totalStartMs,
      lastSuccessAt: lastSuccessAt,
      lastFailureAt: DateTime.now(),
      lastFailureReason: reason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'successes': successes,
      'failures': failures,
      'consecutiveFailures': consecutiveFailures,
      'totalStartMs': totalStartMs,
      'lastSuccessAt': lastSuccessAt?.toIso8601String(),
      'lastFailureAt': lastFailureAt?.toIso8601String(),
      'lastFailureReason': lastFailureReason,
    };
  }

  factory ProfileRuntimeStats.fromJson(Map<String, dynamic> json) {
    int readInt(String key) {
      final value = json[key];
      if (value is int) {
        return value < 0 ? 0 : value;
      }
      if (value is num) {
        return value < 0 ? 0 : value.toInt();
      }
      return 0;
    }

    return ProfileRuntimeStats(
      successes: readInt('successes'),
      failures: readInt('failures'),
      consecutiveFailures: readInt('consecutiveFailures'),
      totalStartMs: readInt('totalStartMs'),
      lastSuccessAt: json['lastSuccessAt'] == null
          ? null
          : DateTime.tryParse('${json['lastSuccessAt']}'),
      lastFailureAt: json['lastFailureAt'] == null
          ? null
          : DateTime.tryParse('${json['lastFailureAt']}'),
      lastFailureReason: json['lastFailureReason'] as String?,
    );
  }
}

class ProfileStore {
  static const _profilesKey = 'profiles';
  static const _selectedProfileKey = 'selectedProfileId';
  static const _languageKey = 'languageCode';
  static const _autoConnectKey = 'autoConnect';
  static const _subscriptionSourcesKey = 'subscriptionSources';
  static const _deletedProfileIdsKey = 'deletedProfileIds';
  static const _splitTunnelExcludedProcessesKey =
      'splitTunnelExcludedProcesses';
  static const _vpnOnlyProcessesKey = 'vpnOnlyProcesses';
  static const _codexDirectKey = 'codexDirect';
  static const _chatGptThroughVpnKey = 'chatGptThroughVpn';
  static const _developerModeKey = 'developerMode';
  static const _dnsOnlyThroughVpnKey = 'dnsOnlyThroughVpn';
  static const _windowsConnectionModeKey = 'windowsConnectionMode';
  static const _profileRuntimeStatsKey = 'profileRuntimeStats';
  static const defaultVpnOnlyProcesses = <String>[];
  static const defaultCodexDirect = true;
  static const defaultChatGptThroughVpn = true;
  static const defaultDeveloperMode = true;
  static const defaultDnsOnlyThroughVpn = true;
  static const defaultWindowsConnectionMode = WindowsConnectionMode.stableProxy;

  Future<List<VpnProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_profilesKey);
    if (encoded == null || encoded.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(encoded) as List<dynamic>;
    return decoded
        .whereType<Map>()
        .map((json) => VpnProfile.fromJson(json.cast<String, dynamic>()))
        .toList();
  }

  Future<void> saveProfiles(List<VpnProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      profiles.map((profile) => profile.toJson()).toList(),
    );
    await prefs.setString(_profilesKey, encoded);
  }

  Future<String?> loadSelectedProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedProfileKey);
  }

  Future<void> saveSelectedProfileId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedProfileKey);
    } else {
      await prefs.setString(_selectedProfileKey, id);
    }
  }

  Future<String?> loadLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languageKey);
  }

  Future<void> saveLanguageCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, code);
  }

  Future<bool> loadAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoConnectKey) ?? false;
  }

  Future<void> saveAutoConnect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoConnectKey, enabled);
  }

  Future<List<String>> loadSubscriptionSources() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_subscriptionSourcesKey) ?? const [];
  }

  Future<void> saveSubscriptionSources(List<String> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized =
        sources
            .map((source) => source.trim())
            .where((source) => source.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    await prefs.setStringList(_subscriptionSourcesKey, normalized);
  }

  Future<Set<String>> loadDeletedProfileIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_deletedProfileIdsKey) ?? const [])
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<void> saveDeletedProfileIds(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized =
        ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet().toList()
          ..sort();
    await prefs.setStringList(_deletedProfileIdsKey, normalized);
  }

  Future<void> markProfileDeleted(String id) async {
    final deletedIds = await loadDeletedProfileIds();
    deletedIds.add(id);
    await saveDeletedProfileIds(deletedIds);
  }

  Future<void> restoreProfiles(Iterable<String> ids) async {
    final restoreIds = ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (restoreIds.isEmpty) {
      return;
    }
    final deletedIds = await loadDeletedProfileIds();
    deletedIds.removeAll(restoreIds);
    await saveDeletedProfileIds(deletedIds);
  }

  Future<List<String>> loadSplitTunnelExcludedProcesses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_splitTunnelExcludedProcessesKey) ?? const [];
  }

  Future<void> saveSplitTunnelExcludedProcesses(List<String> processes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_splitTunnelExcludedProcessesKey, processes);
  }

  Future<List<String>> loadVpnOnlyProcesses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_vpnOnlyProcessesKey) ?? defaultVpnOnlyProcesses;
  }

  Future<void> saveVpnOnlyProcesses(List<String> processes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_vpnOnlyProcessesKey, processes);
  }

  Future<bool> loadCodexDirect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_codexDirectKey) ?? defaultCodexDirect;
  }

  Future<void> saveCodexDirect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_codexDirectKey, enabled);
  }

  Future<bool> loadChatGptThroughVpn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_chatGptThroughVpnKey) ?? defaultChatGptThroughVpn;
  }

  Future<void> saveChatGptThroughVpn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_chatGptThroughVpnKey, enabled);
  }

  Future<bool> loadDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_developerModeKey) ?? defaultDeveloperMode;
  }

  Future<void> saveDeveloperMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_developerModeKey, enabled);
  }

  Future<bool> loadDnsOnlyThroughVpn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_dnsOnlyThroughVpnKey) ?? defaultDnsOnlyThroughVpn;
  }

  Future<void> saveDnsOnlyThroughVpn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dnsOnlyThroughVpnKey, enabled);
  }

  Future<WindowsConnectionMode> loadWindowsConnectionMode() async {
    final prefs = await SharedPreferences.getInstance();
    return WindowsConnectionMode.fromCode(
      prefs.getString(_windowsConnectionModeKey),
    );
  }

  Future<void> saveWindowsConnectionMode(WindowsConnectionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_windowsConnectionModeKey, mode.code);
  }

  Future<Map<String, ProfileRuntimeStats>> loadProfileRuntimeStats() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_profileRuntimeStatsKey);
    if (encoded == null || encoded.isEmpty) {
      return const {};
    }

    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      return const {};
    }

    final result = <String, ProfileRuntimeStats>{};
    for (final entry in decoded.entries) {
      final key = '${entry.key}'.trim();
      if (key.isEmpty) {
        continue;
      }
      final value = entry.value;
      final stats = value is Map
          ? ProfileRuntimeStats.fromJson(value.cast<String, dynamic>())
          : const ProfileRuntimeStats();
      result[key] = stats;
    }
    return result;
  }

  Future<void> saveProfileRuntimeStats(
    Map<String, ProfileRuntimeStats> stats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = <String, dynamic>{
      for (final entry in stats.entries)
        if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value.toJson(),
    };
    await prefs.setString(_profileRuntimeStatsKey, jsonEncode(normalized));
  }

  Future<ProfileRuntimeStats> recordProfileRuntimeSuccess(
    String profileId,
    Duration startDuration,
  ) async {
    final stats = Map<String, ProfileRuntimeStats>.of(
      await loadProfileRuntimeStats(),
    );
    final updated = (stats[profileId] ?? const ProfileRuntimeStats())
        .recordSuccess(startDuration);
    stats[profileId] = updated;
    await saveProfileRuntimeStats(stats);
    return updated;
  }

  Future<ProfileRuntimeStats> recordProfileRuntimeFailure(
    String profileId,
    String reason,
  ) async {
    final stats = Map<String, ProfileRuntimeStats>.of(
      await loadProfileRuntimeStats(),
    );
    final updated = (stats[profileId] ?? const ProfileRuntimeStats())
        .recordFailure(reason);
    stats[profileId] = updated;
    await saveProfileRuntimeStats(stats);
    return updated;
  }

  Future<void> removeProfileRuntimeStats(String profileId) async {
    final stats = Map<String, ProfileRuntimeStats>.of(
      await loadProfileRuntimeStats(),
    )..remove(profileId);
    await saveProfileRuntimeStats(stats);
  }
}
