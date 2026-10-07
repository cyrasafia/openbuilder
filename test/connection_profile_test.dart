import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';

void main() {
  group('legacy migration (pre-oauth JSON)', () {
    test('password present → basic', () {
      final p = ConnectionProfile.fromJson({
        'id': '1',
        'name': 'n',
        'address': 'http://a',
        'username': 'opencode',
        'password': 'secret',
      });
      expect(p.authMethod, AuthMethod.basic);
      expect(p.clientId, ConnectionProfile.defaultClientId);
    });

    test('empty password → basic (needs login; none no longer exists)', () {
      final p = ConnectionProfile.fromJson({
        'id': '1',
        'name': 'n',
        'address': 'http://a',
        'password': '',
      });
      expect(p.authMethod, AuthMethod.basic);
      expect(p.needsLogin, isTrue);
    });

    test("stored 'none' migrates to basic (v2 always enforces auth)", () {
      final p = ConnectionProfile.fromJson({
        'id': '1',
        'name': 'n',
        'address': 'http://a',
        'authMethod': 'none',
      });
      expect(p.authMethod, AuthMethod.basic);
      expect(p.needsLogin, isTrue);
    });
  });

  group('oauth fields round-trip', () {
    test('full oauth profile survives toJson/fromJson', () {
      final p = ConnectionProfile(
        id: '2',
        name: 'oc',
        address: 'https://oc.test',
        authMethod: AuthMethod.oauth,
        oidcIssuer: 'https://auth.test',
        clientId: 'custom-id',
        accessToken: 'at',
        refreshToken: 'rt',
        tokenExpiresAt: 123456,
        tokenEndpoint: 'https://auth.test/token',
      );
      final restored = ConnectionProfile.fromJson(p.toJson());
      expect(restored.authMethod, AuthMethod.oauth);
      expect(restored.oidcIssuer, 'https://auth.test');
      expect(restored.clientId, 'custom-id');
      expect(restored.accessToken, 'at');
      expect(restored.refreshToken, 'rt');
      expect(restored.tokenExpiresAt, 123456);
      expect(restored.tokenEndpoint, 'https://auth.test/token');
    });

    test('missing optional oauth fields default cleanly', () {
      final p = ConnectionProfile.fromJson({
        'id': '3',
        'name': 'n',
        'address': 'http://a',
        'authMethod': 'oauth',
      });
      expect(p.authMethod, AuthMethod.oauth);
      expect(p.accessToken, '');
      expect(p.tokenExpiresAt, isNull);
    });

    test('unknown authMethod value falls back to password heuristic', () {
      final p = ConnectionProfile.fromJson({
        'id': '4',
        'name': 'n',
        'address': 'http://a',
        'authMethod': 'bogus',
        'password': 'x',
      });
      expect(p.authMethod, AuthMethod.basic);
    });
  });

  group('needsLogin', () {
    test('oauth needs BOTH the gateway token and the opencode password', () {
      expect(
        ConnectionProfile(
                id: 'a',
                name: 'n',
                address: 'a',
                authMethod: AuthMethod.oauth)
            .needsLogin,
        isTrue,
      );
      expect(
        ConnectionProfile(
                id: 'a',
                name: 'n',
                address: 'a',
                authMethod: AuthMethod.oauth,
                accessToken: 't')
            .needsLogin,
        isTrue,
        reason: 'the gateway token alone cannot pass opencode behind the '
            'gateway (v2 enforces its own password)',
      );
      expect(
        ConnectionProfile(
                id: 'a',
                name: 'n',
                address: 'a',
                authMethod: AuthMethod.oauth,
                accessToken: 't',
                password: 'pw')
            .needsLogin,
        isFalse,
      );
    });

    test('basic without password → needs login; oauth needs password too',
        () {
      expect(
        ConnectionProfile(
                id: 'a', name: 'n', address: 'a', authMethod: AuthMethod.basic)
            .needsLogin,
        isTrue,
      );
      expect(
        ConnectionProfile(
                id: 'a',
                name: 'n',
                address: 'a',
                authMethod: AuthMethod.oauth,
                accessToken: 'at')
            .needsLogin,
        isTrue,
        reason: 'gateway token alone is useless — v2 enforces its own '
            'password behind the gateway',
      );
      expect(
        ConnectionProfile(
                id: 'a',
                name: 'n',
                address: 'a',
                authMethod: AuthMethod.oauth,
                accessToken: 'at',
                password: 'pw')
            .needsLogin,
        isFalse,
      );
    });
  });

  group('copyWith tokenExpiresAt sentinel', () {
    test('omitted keeps value; explicit null clears it', () {
      const p = ConnectionProfile(
          id: 'x', name: 'n', address: 'a', tokenExpiresAt: 42);
      expect(p.copyWith(name: 'm').tokenExpiresAt, 42);
      expect(p.copyWith(tokenExpiresAt: null).tokenExpiresAt, isNull);
    });
  });
}
