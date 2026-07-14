import 'vpn_engine.dart';

class ConnectionHealthPresentation {
  const ConnectionHealthPresentation._();

  static bool shouldShowIssuePanel({
    required String status,
    required String? error,
    required bool transientWarning,
  }) {
    if (status == YurichConnectStatus.adminRequired) {
      return true;
    }
    if (error == null || error.trim().isEmpty) {
      return false;
    }
    return !(status == YurichConnectStatus.started && transientWarning);
  }
}
