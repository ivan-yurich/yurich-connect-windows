class WindowsRoutingResolution {
  const WindowsRoutingResolution({
    required this.systemProxyEnabled,
    required this.directProcesses,
    required this.vpnOnlyProcesses,
    required this.removedDirectConflicts,
  });

  final bool systemProxyEnabled;
  final List<String> directProcesses;
  final List<String> vpnOnlyProcesses;
  final List<String> removedDirectConflicts;
}

class WindowsRoutingPolicy {
  const WindowsRoutingPolicy._();

  static WindowsRoutingResolution resolve({
    required bool advancedTunMode,
    required bool systemProxyEnabled,
    required Iterable<String> directProcesses,
    required Iterable<String> vpnOnlyProcesses,
  }) {
    final normalizedVpnOnly = _normalize(vpnOnlyProcesses);
    final forcedLookup = {
      for (final process in normalizedVpnOnly) process.toLowerCase(),
    };
    final normalizedDirect = _normalize(directProcesses);
    final conflicts = normalizedDirect
        .where((process) => forcedLookup.contains(process.toLowerCase()))
        .toList(growable: false);
    final resolvedDirect = normalizedDirect
        .where((process) => !forcedLookup.contains(process.toLowerCase()))
        .toList(growable: false);

    return WindowsRoutingResolution(
      systemProxyEnabled: advancedTunMode ? false : systemProxyEnabled,
      directProcesses: resolvedDirect,
      vpnOnlyProcesses: normalizedVpnOnly,
      removedDirectConflicts: conflicts,
    );
  }

  static List<String> _normalize(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final process = value.trim();
      if (process.isEmpty) {
        continue;
      }
      final key = process.toLowerCase();
      if (seen.add(key)) {
        result.add(process);
      }
    }
    return List.unmodifiable(result);
  }
}
