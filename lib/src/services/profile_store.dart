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
  static const _windowsConnectionModeKey = 'windowsConnectionMode';
  static const defaultVpnOnlyProcesses = <String>[];
  static const defaultCodexDirect = true;
  static const defaultChatGptThroughVpn = true;
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
}
