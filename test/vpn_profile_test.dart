import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/models/vpn_profile.dart';

void main() {
  test('keeps subscription source when profile is serialized', () {
    final expiresAt = DateTime(2027, 6, 7);
    final profile = VpnProfile(
      id: 'profile-a',
      name: 'Finland',
      kind: VpnProfileKind.vlessReality,
      originalInput: 'vless://profile',
      server: 'fi.example.com',
      port: 8443,
      expiresAt: expiresAt,
    ).withSubscriptionSource(' https://example.com/sub ');

    final restored = VpnProfile.fromJson(profile.toJson());

    expect(restored.subscriptionSource, 'https://example.com/sub');
    expect(restored.expiresAt, expiresAt);
    expect(restored.endpoint, 'fi.example.com:8443');
  });

  test('keeps server variant metadata when profile is serialized', () {
    const profile = VpnProfile(
      id: 'profile',
      name: 'DE Frankfurt • Naive HTTPS',
      kind: VpnProfileKind.naive,
      originalInput: 'naive+https://user:pass@example.com:443',
      server: 'example.com',
      port: 443,
      variantGroup: 'de-frankfurt-1',
      variantRole: 'naive-https',
      variantStrategy: 'compatibility',
      variantPriority: 20,
    );

    final restored = VpnProfile.fromJson(profile.toJson());

    expect(restored.variantGroup, 'de-frankfurt-1');
    expect(restored.variantRole, 'naive-https');
    expect(restored.variantStrategy, 'compatibility');
    expect(restored.variantPriority, 20);
  });
}
