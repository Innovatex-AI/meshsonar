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

String? _host(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty) return null;
  return u.host.toLowerCase();
}

/// The URL a saved [url] should become at startup, or null to leave it alone. Any scheme, case, path or trailing
/// slash on a retired host maps to [defaultServerUrl]; anything else (including [defaultServerUrl] itself) is null,
/// so applying it twice changes nothing.
String? migratedServerUrl(String url) {
  final h = _host(url);
  if (h == null || !retiredServerHosts.contains(h)) return null;
  return defaultServerUrl;
}

/// True when [a] and [b] are both addresses of the same MeshSonar server ([sameServerHosts]), so a driver key from
/// one is valid on the other.
bool isSameServer(String a, String b) {
  final ha = _host(a), hb = _host(b);
  return ha != null && hb != null && sameServerHosts.contains(ha) && sameServerHosts.contains(hb);
}
