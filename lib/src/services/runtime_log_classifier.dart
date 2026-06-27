class RuntimeLogClassifier {
  RuntimeLogClassifier._();

  static final RegExp _ansiEscape = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

  static bool isUserFacingNoise(String message) {
    final log = _normalize(message);
    return _isTunConnectionCloseNoise(log) || _isDirectRouteTimeoutNoise(log);
  }

  static bool isDiagnosticNoise(String message) {
    final log = _normalize(message);
    return isUserFacingNoise(message) || _isHealthProbeDnsNoise(log);
  }

  static String _normalize(String message) {
    return message.replaceAll(_ansiEscape, '').toLowerCase().trim();
  }

  static bool _isTunConnectionCloseNoise(String log) {
    return log.contains('connection upload closed') &&
        log.contains('raw-read tcp4 172.19.0.1') &&
        log.contains('->172.19.0.2:') &&
        log.contains('forcibly closed by the remote host');
  }

  static bool _isDirectRouteTimeoutNoise(String log) {
    return log.contains('using outbound/direct[direct]') &&
        log.contains('i/o timeout');
  }

  static bool _isHealthProbeDnsNoise(String log) {
    if (!log.contains('dns:')) {
      return false;
    }
    final isHealthProbeHost =
        log.contains('cp.cloudflare.com') ||
        log.contains('connectivitycheck.gstatic.com') ||
        log.contains('www.msftconnecttest.com');
    if (!isHealthProbeHost) {
      return false;
    }
    return log.contains('exchange failed') ||
        log.contains('i/o timeout') ||
        log.contains('context deadline exceeded') ||
        log.contains('no such host') ||
        log.contains('failed host lookup');
  }
}
