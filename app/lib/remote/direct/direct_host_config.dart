import 'dart:math' as math;

/// One saved direct-connect host: a `dsh web` reached over its own
/// HTTPS origin (user's nginx / tunnel), no SSH, no relay server.
/// Persisted as JSON in SharedPreferences; the launch token lives in
/// the [SecretStore] under [DirectSecrets].
class DirectHostConfig {
  const DirectHostConfig({required this.id, required this.name, required this.url});

  /// Stable id (`direct-<hex>`); also the secret-store namespace.
  final String id;

  /// Display name ("电脑").
  final String name;

  /// Public origin, e.g. `https://dsh.example.com`. Normalized to
  /// scheme://host[:port] (no path/query).
  final String url;

  Uri get baseUri => Uri.parse(url);

  /// Fields that require a fresh login when they change.
  String get connectionKey => url;

  DirectHostConfig copyWith({String? name, String? url}) =>
      DirectHostConfig(id: id, name: name ?? this.name, url: url ?? this.url);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url};

  static DirectHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['url'];
    if (id is! String || url is! String || id.isEmpty || url.isEmpty) return null;
    final name = raw['name'];
    return DirectHostConfig(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : url,
      url: url,
    );
  }

  /// Parse what a person typed: a full launch URL (`https://h/?token=x`),
  /// an origin, or a bare domain. `null` when nothing usable is there.
  static String? normalizeOrigin(String text) {
    var t = text.trim();
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = 'https://$t';
    final uri = Uri.tryParse(t);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null).toString();
  }

  static String? tokenFrom(String text) {
    final uri = Uri.tryParse(text.trim());
    final t = uri?.queryParameters['token'];
    return (t == null || t.isEmpty) ? null : t;
  }

  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'direct-$hex';
  }

  @override
  bool operator ==(Object other) =>
      other is DirectHostConfig && other.id == id && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(id, name, url);
}

/// The launch token for one direct host, stored in the [SecretStore].
class DirectSecrets {
  const DirectSecrets({this.token});

  /// The `?token=` from `dsh web`'s startup line. Good for that process's
  /// lifetime; when it rotates the person pastes the new launch URL again.
  final String? token;

  static String tokenKey(String hostId) => 'direct.$hostId.token';

  /// The signed session cookie from the last token login (JSON). The Host's
  /// signing secret is durable across restarts, so this credential outlives
  /// them; the launch token is only the bootstrap.
  static String cookieKey(String hostId) => 'direct.$hostId.cookie';

  bool get isEmpty => token == null || token!.isEmpty;
}
