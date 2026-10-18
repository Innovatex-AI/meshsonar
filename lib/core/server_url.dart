// The default server and the one place that knows which server addresses are the same server.
//
// 0.5.0: the website moved from Lovable (cmh-meshcore.lovable.app) to MeshSonar's own server. meshsonar.com (the hub)
// and cmh.meshsonar.com serve the same /api/cmh/* API from the same database, so a driver key issued by any of these
// addresses works on the others. Pure Dart (no Flutter).

/// The MeshSonar server new installs use.
const String defaultServerUrl = 'https://meshsonar.com';

/// Hosts that serve the same MeshSonar server (same API and database). Moving between two of these keeps the driver
/// key; any other server change removes it. Deliberately an explicit list (not "any *.meshsonar.com"): a key only
/// works on the database that issued it.
const Set<String> sameServerHosts = {'cmh-meshcore.lovable.app', 'meshsonar.com', 'cmh.meshsonar.com'};

/// Retired hosts: a saved server URL on one of these is rewritten to [defaultServerUrl] at startup (key kept).
const Set<String> retiredServerHosts = {'cmh-meshcore.lovable.app'};

/// Parses [url]; null when it has no host, or when its authority has an `@` at all (Uri reports `https://@host` as
/// empty userinfo, which must not pass for a plain address).
Uri? _parse(String url) {
  final t = url.trim();
  final u = Uri.tryParse(t);
  if (u == null || u.host.isEmpty) return null;
  final afterScheme = t.indexOf('//');
  if (afterScheme >= 0) {
    final rest = t.substring(afterScheme + 2);
    final end = rest.indexOf(RegExp(r'[/?#]'));
    if ((end < 0 ? rest : rest.substring(0, end)).contains('@')) return null;
  }
  return u;
}

/// No userinfo and the scheme's default port (written or not).
bool _plainAuthority(Uri u) => u.userInfo.isEmpty && (!u.hasPort || u.port == (u.scheme == 'http' ? 80 : 443));

/// The URL a saved [url] should become at startup, or null to leave it alone. A retired host with any scheme, case,
/// path or trailing slash maps to [defaultServerUrl] (always https); one with userinfo or a non-default port is left
/// alone (it was never what the app saved). Anything else, [defaultServerUrl] included, is null, so applying it twice
/// changes nothing.
String? migratedServerUrl(String url) {
  final u = _parse(url);
  if (u == null || !(u.scheme == 'https' || u.scheme == 'http')) return null;
  if (!retiredServerHosts.contains(u.host.toLowerCase()) || !_plainAuthority(u)) return null;
  return defaultServerUrl;
}

/// An address that may stand in for the MeshSonar server: https, the default port (none or 443), no userinfo, no
/// query or fragment, an empty path or "/", and a host in [sameServerHosts].
bool _isAliasAddress(Uri u) =>
    u.scheme == 'https' &&
    _plainAuthority(u) &&
    !u.hasQuery &&
    !u.hasFragment &&
    (u.path.isEmpty || u.path == '/') &&
    sameServerHosts.contains(u.host.toLowerCase());

/// True when [a] and [b] are both plain https addresses of the same MeshSonar server (see [_isAliasAddress]), so a
/// driver key from one is valid on the other. Anything else (http, a port, userinfo, a sub-path, another host) is a
/// different server: the key is removed after asking.
bool isSameServer(String a, String b) {
  final ua = _parse(a), ub = _parse(b);
  return ua != null && ub != null && _isAliasAddress(ua) && _isAliasAddress(ub);
}
