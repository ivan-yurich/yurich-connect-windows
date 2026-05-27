import 'dart:async';
import 'dart:io';

import 'android_vpn_engine.dart';
import 'sing_box_config_builder.dart';
import 'windows_sing_box_engine.dart';

class AurumVpnStatus {
  static const stopped = 'Stopped';
  static const starting = 'Starting';
  static const started = 'Started';
  static const stopping = 'Stopping';
}

abstract class VpnEngine {
  Stream<Map<String, dynamic>> get onStatusChanged;
  Stream<Map<String, dynamic>> get onTrafficUpdate;
  Stream<Map<String, dynamic>> get onLogMessage;

  SingBoxConfigTarget get configTarget;

  Future<bool> setNotificationTitle(String title);
  Future<String> getNotificationTitle();
  Future<bool> setNotificationDescription(String description);
  Future<String> getNotificationDescription();
  Future<bool> requestNotificationPermission();
  Future<String> getVPNStatus();
  Future<bool> saveConfig(String config, {String? naiveProxyConfig});
  Future<String> getConfig();
  Future<bool> startVPN();
  Future<bool> stopVPN();
  Future<List<String>> getLogs();
  Future<bool> clearLogs();
  Future<void> dispose();
}

VpnEngine createVpnEngine() {
  if (Platform.isWindows) {
    return WindowsSingBoxEngine();
  }
  return AndroidVpnEngine();
}
