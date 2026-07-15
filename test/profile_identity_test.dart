import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/models/vpn_profile.dart';
import 'package:yurich_connect_windows/src/services/profile_identity.dart';

void main() {
  group('ProfileIdentity', () {
    test('keeps identity when only display name and expiry change', () {
      final oldProfile = _vless(
        id: 'old-id',
        name: 'Germany 1',
        expiresAt: DateTime(2026, 6, 1),
      );
      final refreshed = _vless(
        id: 'new-id',
        name: 'Germany Premium',
        expiresAt: DateTime(2027, 6, 1),
      );

      expect(
        ProfileIdentity.connectionKey(oldProfile),
        ProfileIdentity.connectionKey(refreshed),
      );

      final merged = ProfileIdentity.merge(
        current: [oldProfile],
        incoming: [refreshed],
        identitySource: [oldProfile],
      );

      expect(merged, hasLength(1));
      expect(merged.single.id, 'old-id');
      expect(merged.single.name, 'Germany Premium');
      expect(merged.single.expiresAt?.year, 2027);
    });

    test('removes duplicates and keeps XHTTP profiles during migration', () {
      final supported = _vless(id: 'first', name: 'Primary');
      final duplicate = _vless(id: 'second', name: 'Renamed');
      final xhttp = _vless(
        id: 'xhttp',
        name: 'Experimental',
        transport: 'xhttp',
        backend: VpnCoreBackend.xray,
      );

      final migrated = ProfileIdentity.merge(
        current: const [],
        incoming: [supported, duplicate, xhttp],
        identitySource: [supported, duplicate, xhttp],
      );

      expect(migrated, hasLength(2));
      expect(migrated.first.id, 'first');
      expect(migrated.first.name, 'Renamed');
      expect(migrated.last.id, 'xhttp');
      expect(ProfileIdentity.isXhttpProfile(migrated.last), isTrue);
    });

    test('does not merge profiles with different credentials', () {
      final first = _vless(id: 'first', name: 'One');
      final second = _vless(
        id: 'second',
        name: 'Two',
        uuid: '22222222-2222-4222-8222-222222222222',
      );

      final merged = ProfileIdentity.merge(
        current: [first],
        incoming: [second],
      );

      expect(merged, hasLength(2));
    });

    test('keeps a deletion slot stable after credential rotation', () {
      final oldProfile = _vless(
        id: 'old',
        name: 'Germany Old',
      ).withSubscriptionSource('https://example.com/sub');
      final rotated = _vless(
        id: 'rotated',
        name: 'Germany New',
        uuid: '22222222-2222-4222-8222-222222222222',
      ).withSubscriptionSource('https://example.com/sub');

      expect(
        ProfileIdentity.deletionKeys(
          oldProfile,
        ).intersection(ProfileIdentity.deletionKeys(rotated)),
        isNotEmpty,
      );
    });
  });
}

VpnProfile _vless({
  required String id,
  required String name,
  String uuid = '11111111-1111-4111-8111-111111111111',
  String transport = 'tcp',
  DateTime? expiresAt,
  VpnCoreBackend backend = VpnCoreBackend.auto,
}) {
  return VpnProfile(
    id: id,
    name: name,
    kind: VpnProfileKind.vlessReality,
    originalInput:
        'vless://$uuid@example.com:443?security=reality&type=$transport#${Uri.encodeComponent(name)}',
    server: 'example.com',
    port: 443,
    outbound: {
      'type': 'vless',
      'tag': 'proxy',
      'server': 'example.com',
      'server_port': 443,
      'uuid': uuid,
      if (transport != 'tcp') 'transport': {'type': transport},
      'tls': {
        'enabled': true,
        'server_name': 'www.example.com',
        'reality': {'enabled': true, 'public_key': 'public-key'},
      },
    },
    expiresAt: expiresAt,
    coreBackend: backend,
  );
}
