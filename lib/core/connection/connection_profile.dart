/// A configured opencode server connection.
class ConnectionProfile {
  final String id;
  final String name;
  final String address;
  final String username;
  final String password;

  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.address,
    this.username = 'opencode',
    this.password = '',
  });

  /// Normalized base URL. Prefixes `http://` when no scheme given.
  String get baseUrl {
    final a = address.trim();
    if (a.isEmpty) return '';
    if (a.startsWith('http://') || a.startsWith('https://')) return a;
    return 'http://$a';
  }

  String get hostDisplay => address.trim();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'username': username,
        'password': password,
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> j) => ConnectionProfile(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        address: (j['address'] ?? '').toString(),
        username: (j['username'] ?? 'opencode').toString(),
        password: (j['password'] ?? '').toString(),
      );

  ConnectionProfile copyWith({
    String? name,
    String? address,
    String? username,
    String? password,
  }) =>
      ConnectionProfile(
        id: id,
        name: name ?? this.name,
        address: address ?? this.address,
        username: username ?? this.username,
        password: password ?? this.password,
      );
}
