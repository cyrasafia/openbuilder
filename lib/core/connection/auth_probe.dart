import 'dart:convert';

import 'package:dio/dio.dart';


class OidcMetadata {
  final String issuer;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? parEndpoint;

  const OidcMetadata({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.parEndpoint,
  });
}

enum AuthProbeOutcome { oauth, basic, none, unknown, unreachable }

class AuthProbeResult {
  final AuthProbeOutcome outcome;
  final OidcMetadata? oidc;
  final String? version;

  const AuthProbeResult({
    required this.outcome,
    this.oidc,
    this.version,
  });
}

/// Detects how a server authenticates: OIDC (oauth) via RFC 8414 metadata,
/// basic via a 401 challenge on health, or none. See design-oauth-login.md.
class AuthProbe {
  final Dio dio;

  AuthProbe({Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {'Accept': 'application/json'},
              validateStatus: (_) => true,
              followRedirects: false,
              maxRedirects: 0,
            ));

  Future<AuthProbeResult> probe(String baseUrl) async {
    final health = await _health(baseUrl);
    if (health == null) {
      return const AuthProbeResult(outcome: AuthProbeOutcome.unreachable);
    }
    final meta = await _discoverOidc(baseUrl);
    if (meta != null) {
      return AuthProbeResult(
        outcome: AuthProbeOutcome.oauth,
        oidc: meta,
        version: health.version,
      );
    }
    if (health.unauthorized) {
      return AuthProbeResult(
        outcome: AuthProbeOutcome.basic,
        version: health.version,
      );
    }
    if (health.ok) {
      return AuthProbeResult(
        outcome: AuthProbeOutcome.none,
        version: health.version,
      );
    }
    return const AuthProbeResult(outcome: AuthProbeOutcome.unknown);
  }

  /// Fetch metadata for a manually supplied issuer (probe fallback).
  Future<OidcMetadata?> metadataForIssuer(String issuer) =>
      _metadataFromWellKnown(issuer);

  Future<_HealthProbe?> _health(String baseUrl) async {
    for (final path in const ['/global/health', '/api/health']) {
      try {
        final resp = await _getText('$baseUrl$path');
        if (resp.statusCode == 404) continue;
        final body = _jsonMap(resp.data);
        return _HealthProbe(
          ok: resp.statusCode == 200,
          unauthorized: resp.statusCode == 401,
          version: body?['version']?.toString(),
        );
      } on DioException {
        continue;
      }
    }
    return null;
  }

  Future<OidcMetadata?> _discoverOidc(String baseUrl) async {
    try {
      // One fetch serves both outcomes: 200 → parse directly; 3xx → follow
      // to the auth-portal origin (gateway topology — the metadata lives
      // there, not on the API host).
      final resp = await _getText(
          '$baseUrl/.well-known/oauth-authorization-server');
      final status = resp.statusCode ?? 0;
      if (status == 200) return _metaFromJson(resp.data);
      if (status >= 300 && status < 400) {
        final origin = _originOf(resp.headers.value('location'), baseUrl);
        if (origin != null) return _metadataFromWellKnown(origin);
      }
      return null;
    } on DioException {
      return null;
    }
  }

  Future<Response<String>> _getText(String url) =>
      dio.get<String>(url, options: Options(responseType: ResponseType.plain));

  Map? _jsonMap(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  OidcMetadata? _metaFromJson(String? body) {
    final m = _jsonMap(body);
    if (m == null) return null;
    final issuer = m['issuer']?.toString() ?? '';
    final authorization = m['authorization_endpoint']?.toString() ?? '';
    final token = m['token_endpoint']?.toString() ?? '';
    if (issuer.isEmpty || authorization.isEmpty || token.isEmpty) {
      return null;
    }
    final par = m['pushed_authorization_request_endpoint']?.toString();
    return OidcMetadata(
      issuer: issuer,
      authorizationEndpoint: authorization,
      tokenEndpoint: token,
      parEndpoint: (par == null || par.isEmpty) ? null : par,
    );
  }

  Future<OidcMetadata?> _metadataFromWellKnown(String origin) async {
    try {
      final resp =
          await _getText('$origin/.well-known/oauth-authorization-server');
      if (resp.statusCode != 200) return null;
      return _metaFromJson(resp.data);
    } on DioException {
      return null;
    }
  }

  String? _originOf(String? location, String base) {
    if (location == null || location.isEmpty) return null;
    final resolved = Uri.parse(base).resolve(location);
    if (!resolved.hasScheme || !resolved.hasAuthority || resolved.host.isEmpty) {
      return null;
    }
    final s = resolved.toString();
    final pathStart = s.indexOf('/', s.indexOf('//') + 2);
    return pathStart == -1 ? s : s.substring(0, pathStart);
  }
}

class _HealthProbe {
  final bool ok;
  final bool unauthorized;
  final String? version;

  const _HealthProbe({
    required this.ok,
    required this.unauthorized,
    this.version,
  });
}
