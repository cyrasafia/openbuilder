import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../connection/auth_code_client.dart';
import '../connection/connection_profile.dart';
import '../connection/connection_store.dart';

/// Bearer lifecycle for oauth profiles: proactive refresh near expiry
/// (single-flight shared across dio instances via a static map) and one 401
/// retry after refresh. basic pass through untouched.
///
/// Two-layer 401 diagnosis (oauth = gateway Bearer + opencode credential):
/// a definitive refresh rejection breaks the GATEWAY layer (full re-login);
/// a retry that carries a fresh gateway token yet still 401s breaks the
/// OPENCODE layer (only the opencode password needs re-entry).
class AuthInterceptor extends Interceptor {
  final Dio dio;
  final ConnectionProfile profile;
  final ConnectionStore? store;
  final AuthCodeClient tokenClient;

  AuthInterceptor(this.dio, this.profile,
      {this.store, AuthCodeClient? tokenClient})
      : tokenClient = tokenClient ?? AuthCodeClient();

  static final Map<String, Future<TokenResult?>> _refreshInFlight = {};

  static const _retriedKey = 'ob_auth_retried';
  static const _expirySlack = Duration(seconds: 60);

  /// Prefer the live profile from the store — token rotation must be visible
  /// to long-lived dio instances (SSE) built from an older snapshot.
  ConnectionProfile get _current => store?.byId(profile.id) ?? profile;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final p = _current;
    if (p.authMethod != AuthMethod.oauth || !_nearExpiry(p)) {
      _attach(options, p);
      handler.next(options);
      return;
    }
    if (p.refreshToken.isEmpty) {
      _attach(options, p);
      handler.next(options);
      return;
    }
    _refresh(p).then((tokens) {
      if (tokens == null) store?.markAuthBroken(p.id);
      _attach(options, p, override: tokens?.accessToken);
      handler.next(options);
    }).catchError((Object _) {
      _attach(options, p);
      handler.next(options);
    });
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final p = _current;
    final isOauth401 = p.authMethod == AuthMethod.oauth &&
        err.response?.statusCode == 401;
    if (!isOauth401) {
      handler.next(err);
      return;
    }
    if (err.requestOptions.extra[_retriedKey] == true) {
      // The post-refresh replay with a fresh gateway token was still
      // rejected: the gateway layer is fine — the opencode credential is
      // what failed. Keep the gateway tokens; only the password needs
      // re-entry (see design/v2/design-auth-adaptation.md §401 诊断).
      store?.markAuthBroken(p.id, scope: AuthBrokenScope.opencode);
      handler.next(err);
      return;
    }
    if (p.refreshToken.isEmpty) {
      store?.markAuthBroken(p.id);
      handler.next(err);
      return;
    }
    _refresh(p).then((tokens) {
      if (tokens == null) {
        store?.markAuthBroken(p.id);
        handler.next(err);
        return;
      }
      final options = err.requestOptions
        ..extra[_retriedKey] = true
        ..headers['Authorization'] = 'Bearer ${tokens.accessToken}';
      dio.fetch(options).then(
        (resp) => handler.resolve(resp),
        onError: (Object e, StackTrace _) =>
            handler.next(e is DioException ? e : err),
      );
    }).catchError((Object _) {
      // Transient refresh failure (token endpoint unreachable): keep the
      // profile intact — the next request retries the refresh.
      handler.next(err);
    });
  }

  bool _nearExpiry(ConnectionProfile p) {
    final expiresAt = p.tokenExpiresAt;
    if (expiresAt == null) return false;
    return DateTime.now().millisecondsSinceEpoch >
        expiresAt - _expirySlack.inMilliseconds;
  }

  void _attach(RequestOptions options, ConnectionProfile p,
      {String? override}) {
    final token = override ?? p.accessToken;
    if (token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
  }

  Future<TokenResult?> _refresh(ConnectionProfile p) {
    final pending = _refreshInFlight[p.id];
    if (pending != null) return pending;
    // Transient transport failures propagate (callers must NOT mark
    // authBroken — the credentials may be fine); definitive auth rejections
    // resolve to null.
    final future = _doRefresh(p);
    _refreshInFlight[p.id] = future;
    unawaited(future.whenComplete(() {
      if (identical(_refreshInFlight[p.id], future)) {
        _refreshInFlight.remove(p.id);
      }
    }).catchError((Object _) => null));
    return future;
  }

  Future<TokenResult?> _doRefresh(ConnectionProfile p) async {
    try {
      final tokens = await tokenClient.refreshToken(
        tokenEndpoint: p.tokenEndpoint,
        clientId: p.clientId,
        refreshToken: p.refreshToken,
      );
      // Re-read before persisting: the live entry may have gained a new
      // opencode password while the refresh was in flight — writing the
      // stale snapshot would roll it back.
      final latest = store?.byId(p.id) ?? p;
      final updated = latest.copyWith(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        tokenExpiresAt: tokens.expiresAtMs,
      );
      await store?.update(updated);
      return tokens;
    } on DioException catch (e) {
      // dio may re-wrap adapter errors and drop `.response`; the type still
      // tells HTTP rejection (AuthCodeClient validates status < 400) apart
      // from transport failures (connectionError/timeout/…).
      final httpRejection =
          e.response?.statusCode != null || e.type == DioExceptionType.badResponse;
      if (httpRejection) return null;
      rethrow;
    } on Object {
      return null;
    }
  }
}

/// Re-attach [base]'s interceptors to [copy]. An [AuthInterceptor] is
/// REBOUND to [copy] (not shared): its 401 retry runs `dio.fetch` on the dio
/// it was constructed with, and retrying on [base] would bypass [copy]'s
/// transport quirks (e.g. raw_download's `autoUncompress = false`, whose
/// content-encoding accounting would then double-decompress gzip bodies).
void copyInterceptors(Dio base, Dio copy) {
  for (final interceptor in base.interceptors) {
    copy.interceptors.add(interceptor is AuthInterceptor
        ? AuthInterceptor(copy, interceptor.profile,
            store: interceptor.store, tokenClient: interceptor.tokenClient)
        : interceptor);
  }
}

/// Authorization headers for a profile — the single source shared by the dio
/// factory and the SSE transports. Returned map content must be copied into a
/// long-lived map by the caller (see ServerStore._sseHeaders). The Basic
/// username is fixed to `opencode`: v2 servers reject any other value (see
/// design/v2/design-server-auth.md §用户名语义).
Map<String, String> authHeadersFor(ConnectionProfile p) {
  switch (p.authMethod) {
    case AuthMethod.basic:
      if (p.password.isEmpty) return const {};
      return {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('opencode:${p.password}'))}',
      };
    case AuthMethod.oauth:
      if (p.accessToken.isEmpty) return const {};
      return {'Authorization': 'Bearer ${p.accessToken}'};
  }
}

/// Query parameters carrying the opencode credential past a gateway. The
/// Authorization header is already taken by the gateway's Bearer token, so
/// the opencode credential rides the server's native `?auth_token=` bypass
/// (it rewrites the value into a Basic header server-side).
Map<String, String> authQueryFor(ConnectionProfile p) {
  if (p.authMethod != AuthMethod.oauth || p.password.isEmpty) {
    return const {};
  }
  return {
    'auth_token': base64Encode(utf8.encode('opencode:${p.password}')),
  };
}

/// Appends [authQueryFor] to every request (REST and SSE share this). Reads
/// the live profile from the store so password updates reach long-lived dio
/// instances built from an older snapshot.
class AuthTokenQueryInterceptor extends Interceptor {
  final ConnectionProfile profile;
  final ConnectionStore? store;

  AuthTokenQueryInterceptor(this.profile, {this.store});

  ConnectionProfile get _current => store?.byId(profile.id) ?? profile;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Merge, never replace: business query parameters (limit, directory,
    // search…) must survive. Only `auth_token` is ours to manage — drop a
    // stale one (password cleared / retry re-entry) before re-adding.
    options.queryParameters
      ..removeWhere((k, v) => k == 'auth_token')
      ..addAll(authQueryFor(_current));
    handler.next(options);
  }
}

/// Builds a configured [Dio] for a [ConnectionProfile] (base URL + auth).
///
/// [store] is REQUIRED for oauth profiles: token rotation must be persisted
/// (the IdP revokes the old refresh token on every refresh), and a store-less
/// interceptor would silently consume the persisted refresh token.
Dio dioFor(ConnectionProfile p, {ConnectionStore? store}) {
  if (p.authMethod == AuthMethod.oauth && store == null) {
    // Runtime (not assert): release builds must fail loudly here too — a
    // store-less interceptor silently consumes rotated refresh tokens
    // (Authelia revokes the old one on every refresh).
    throw ArgumentError.value(
      store,
      'store',
      'oauth profiles need a ConnectionStore so refreshed tokens persist',
    );
  }
  final dio = Dio(BaseOptions(
    baseUrl: p.baseUrl,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 20),
    sendTimeout: const Duration(seconds: 20),
    headers: {'Accept': 'application/json'},
  ));
  switch (p.authMethod) {
    case AuthMethod.basic:
      if (p.password.isNotEmpty) {
        dio.options.headers['Authorization'] =
            'Basic ${base64Encode(utf8.encode('opencode:${p.password}'))}';
      }
      break;
    case AuthMethod.oauth:
      dio.interceptors.add(AuthInterceptor(dio, p, store: store));
      dio.interceptors.add(AuthTokenQueryInterceptor(p, store: store));
      break;
  }
  return dio;
}
