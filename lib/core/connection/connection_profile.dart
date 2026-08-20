/// How a server connection authenticates.
enum AuthMethod { none, basic, oauth }

/// A configured opencode server connection.
class ConnectionProfile {
  final String id;
  final String name;
  final String address;
  final String username;
  final String password;
  final AuthMethod authMethod;
  final String oidcIssuer;
  final String clientId;
  final String accessToken;
  final String refreshToken;
  final int? tokenExpiresAt;
  final String tokenEndpoint;

  static const defaultClientId = 'openbuilder-app';

  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.address,
    this.username = 'opencode',
    this.password = '',
    this.authMethod = AuthMethod.none,
    this.oidcIssuer = '',
    this.clientId = defaultClientId,
    this.accessToken = '',
    this.refreshToken = '',
    this.tokenExpiresAt,
    this.tokenEndpoint = '',
  });

  /// Normalized base URL. Prefixes `http://` when no scheme given.
  String get baseUrl {
    final a = address.trim();
    if (a.isEmpty) return '';
    if (a.startsWith('http://') || a.startsWith('https://')) return a;
    return 'http://$a';
  }

  String get hostDisplay => address.trim();

  bool get needsLogin {
    if (authMethod == AuthMethod.oauth) return accessToken.isEmpty;
    if (authMethod == AuthMethod.basic) return password.isEmpty;
    return false;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'username': username,
        'password': password,
        'authMethod': authMethod.name,
        'oidcIssuer': oidcIssuer,
        'clientId': clientId,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'tokenExpiresAt': tokenExpiresAt,
        'tokenEndpoint': tokenEndpoint,
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> j) {
    final rawMethod = (j['authMethod'] ?? '').toString();
    AuthMethod method;
    if (rawMethod == 'basic' || rawMethod == 'oauth' || rawMethod == 'none') {
      method = AuthMethod.values
          .firstWhere((m) => m.name == rawMethod, orElse: () => AuthMethod.none);
    } else {
      // Legacy profiles (pre-oauth) carried only basic credentials.
      method = (j['password'] ?? '').toString().isNotEmpty
          ? AuthMethod.basic
          : AuthMethod.none;
    }
    final clientId = (j['clientId'] ?? '').toString();
    return ConnectionProfile(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      address: (j['address'] ?? '').toString(),
      username: (j['username'] ?? 'opencode').toString(),
      password: (j['password'] ?? '').toString(),
      authMethod: method,
      oidcIssuer: (j['oidcIssuer'] ?? '').toString(),
      clientId: clientId.isEmpty ? defaultClientId : clientId,
      accessToken: (j['accessToken'] ?? '').toString(),
      refreshToken: (j['refreshToken'] ?? '').toString(),
      tokenExpiresAt: j['tokenExpiresAt'] == null
          ? null
          : int.tryParse(j['tokenExpiresAt'].toString()),
      tokenEndpoint: (j['tokenEndpoint'] ?? '').toString(),
    );
  }

  ConnectionProfile copyWith({
    String? name,
    String? address,
    String? username,
    String? password,
    AuthMethod? authMethod,
    String? oidcIssuer,
    String? clientId,
    String? accessToken,
    String? refreshToken,
    Object? tokenExpiresAt = _unset,
    String? tokenEndpoint,
  }) =>
      ConnectionProfile(
        id: id,
        name: name ?? this.name,
        address: address ?? this.address,
        username: username ?? this.username,
        password: password ?? this.password,
        authMethod: authMethod ?? this.authMethod,
        oidcIssuer: oidcIssuer ?? this.oidcIssuer,
        clientId: clientId ?? this.clientId,
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        tokenExpiresAt: identical(tokenExpiresAt, _unset)
            ? this.tokenExpiresAt
            : tokenExpiresAt as int?,
        tokenEndpoint: tokenEndpoint ?? this.tokenEndpoint,
      );

  static const _unset = Object();
}
