import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/secret_redactor.dart';

void main() {
  group('SecretRedactor', () {
    test('masks UUID with visible prefix and suffix', () {
      expect(
        SecretRedactor.redact('id=123e4567-e89b-12d3-a456-426614174000'),
        contains('123e****4000'),
      );
    });

    test('masks subscription URLs', () {
      expect(
        SecretRedactor.redact(
          'https://net-it.pro/s/224f9a8414b5365893ffee422539713aecef525312693513/',
        ),
        'https://net-it.pro/.../****',
      );
    });

    test('masks protocol links and url credentials', () {
      final value = SecretRedactor.redact(
        'vless://123e4567-e89b-12d3-a456-426614174000@example.com '
        'https://user:pass@example.com',
      );
      expect(value, contains('vless://****'));
      expect(value, contains('https://****:****@example.com'));
      expect(value, isNot(contains('pass')));
    });

    test('masks json secrets and query parameters', () {
      final value = SecretRedactor.redact(
        '{"password":"secret","public_key":"pub","shortId":"sid"} '
        'token=abcdef&auth=qwerty',
      );
      expect(value, contains('"password":"****"'));
      expect(value, contains('"public_key":"****"'));
      expect(value, contains('"shortId":"****"'));
      expect(value, contains('token=****'));
      expect(value, contains('auth=****'));
    });
  });
}
