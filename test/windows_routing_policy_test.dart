import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/windows_routing_policy.dart';

void main() {
  group('WindowsRoutingPolicy', () {
    test('disables Windows system proxy in Advanced TUN mode', () {
      final resolution = WindowsRoutingPolicy.resolve(
        advancedTunMode: true,
        systemProxyEnabled: true,
        directProcesses: const [],
        vpnOnlyProcesses: const [],
      );

      expect(resolution.systemProxyEnabled, isFalse);
    });

    test('always-through-VPN process wins over direct exclusion', () {
      final resolution = WindowsRoutingPolicy.resolve(
        advancedTunMode: true,
        systemProxyEnabled: false,
        directProcesses: const ['codex.exe', 'ssh.exe', 'CODEX.EXE'],
        vpnOnlyProcesses: const ['Codex.exe'],
      );

      expect(resolution.directProcesses, const ['ssh.exe']);
      expect(resolution.vpnOnlyProcesses, const ['Codex.exe']);
      expect(resolution.removedDirectConflicts, const ['codex.exe']);
    });

    test('normalizes empty and duplicate process entries', () {
      final resolution = WindowsRoutingPolicy.resolve(
        advancedTunMode: false,
        systemProxyEnabled: true,
        directProcesses: const [' ssh.exe ', '', 'SSH.EXE', 'git.exe'],
        vpnOnlyProcesses: const [' chrome.exe ', 'CHROME.EXE'],
      );

      expect(resolution.systemProxyEnabled, isTrue);
      expect(resolution.directProcesses, const ['ssh.exe', 'git.exe']);
      expect(resolution.vpnOnlyProcesses, const ['chrome.exe']);
    });
  });
}
