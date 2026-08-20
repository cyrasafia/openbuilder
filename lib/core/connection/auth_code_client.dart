import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'auth_probe.dart';

class LoginSession {
  final String authorizationUrl;
  final String codeVerifier;
  final String state;

  const LoginSession({
    required this.authorizationUrl,
    required this.codeVerifier,
    required this.state,
  });
}

class TokenResult {
  final String accessToken;
  final String refreshToken;
  final int? expiresAtMs;

  const TokenResult({
    required this.accessToken,
    required this.refreshToken,
    this.expiresAtMs,
  });
}

/// authorization_code + PKCE(S256) + PAR client. Pure protocol, no UI and no
/// sockets — the loopback receiver lives in [LoopbackCallbackServer] and the
/// orchestration in [OAuthLoginController]. See design-oauth-login.md.
class AuthCodeClient {
  final Dio dio;

  static const scope = 'offline_access authelia.bearer.authz';

  AuthCodeClient({Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'Accept': 'application/json'},
            ));

  Future<LoginSession> startLogin({
    required OidcMetadata meta,
    required String clientId,
    required String audience,
    required String redirectUri,
  }) async {
    final verifier = _randomVerifier();
    final state = _randomState();
    final challenge = _s256(verifier);
    var url = Uri.parse(meta.authorizationEndpoint);
    if (meta.parEndpoint != null) {
      final requestUri = await _pushAuthorizationRequest(
        parEndpoint: meta.parEndpoint!,
        clientId: clientId,
        redirectUri: redirectUri,
        audience: audience,
        challenge: challenge,
        state: state,
      );
      url = url.replace(queryParameters: {
        'client_id': clientId,
        'request_uri': requestUri,
      });
    } else {
      url = url.replace(queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': scope,
        'audience': audience,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
      });
    }
    return LoginSession(
      authorizationUrl: url.toString(),
      codeVerifier: verifier,
      state: state,
    );
  }

  Future<String> _pushAuthorizationRequest({
    required String parEndpoint,
    required String clientId,
    required String redirectUri,
    required String audience,
    required String challenge,
    required String state,
  }) async {
    final resp = await dio.post<Object>(
      parEndpoint,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => s != null && s < 400,
      ),
      data: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': scope,
        'audience': audience,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );
    if (resp.data is! Map) {
      throw DioException.badResponse(
        statusCode: resp.statusCode ?? 0,
        requestOptions: resp.requestOptions,
        response: resp,
      );
    }
    final uri = (resp.data as Map)['request_uri']?.toString() ?? '';
    if (uri.isEmpty) {
      throw DioException.badResponse(
        statusCode: resp.statusCode ?? 0,
        requestOptions: resp.requestOptions,
        response: resp,
      );
    }
    return uri;
  }

  Future<TokenResult> exchangeCode({
    required String tokenEndpoint,
    required String clientId,
    required String redirectUri,
    required String code,
    required String verifier,
  }) async {
    final resp = await dio.post<Object>(
      tokenEndpoint,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => s != null && s < 400,
      ),
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': verifier,
      },
    );
    return _tokenResult(resp);
  }

  Future<TokenResult> refreshToken({
    required String tokenEndpoint,
    required String clientId,
    required String refreshToken,
  }) async {
    final resp = await dio.post<Object>(
      tokenEndpoint,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => s != null && s < 400,
      ),
      data: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      },
    );
    return _tokenResult(resp);
  }

  TokenResult _tokenResult(Response<Object> resp) {
    if (resp.data is! Map) {
      throw DioException.badResponse(
        statusCode: resp.statusCode ?? 0,
        requestOptions: resp.requestOptions,
        response: resp,
      );
    }
    final m = resp.data as Map;
    final access = m['access_token']?.toString() ?? '';
    if (access.isEmpty) {
      throw DioException.badResponse(
        statusCode: resp.statusCode ?? 0,
        requestOptions: resp.requestOptions,
        response: resp,
      );
    }
    final refresh = m['refresh_token']?.toString() ?? '';
    final expiresIn = int.tryParse(m['expires_in']?.toString() ?? '');
    return TokenResult(
      accessToken: access,
      refreshToken: refresh,
      expiresAtMs: expiresIn == null
          ? null
          : DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    );
  }

  String _randomVerifier() {
    final rnd = Random.secure();
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(64, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  String _randomState() {
    final rnd = Random.secure();
    final bytes = List.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _s256(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
