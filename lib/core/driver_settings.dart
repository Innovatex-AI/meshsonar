// The account-level settings the server holds for a person (`GET/POST /api/cmh/driver-settings`, capability
// `driverSettings`; wire contract meshsonar-infra docs/planning/build-66-settings-contract.md) and the zone purge answer
// (`POST /api/cmh/driver-privacy/purge`, capability `zonePurge`). Pure Dart: no Flutter imports.
import 'privacy_zones.dart';

/// The fields that can be edited from the app and that the server stamps with an `updatedAt` each.
enum SettingField { callsign, display, anonymous, leaderboardOptIn }

const int kDisplayNameMax = 40;
const int kCallsignMin = 3;
const int kCallsignMax = 20;
final RegExp _callsignRe = RegExp(r'^[A-Z0-9/-]{3,20}$');

/// What is wrong with a callsign being typed, in plain words (null = fine; empty clears it).
String? callsignProblem(String raw) {
  final t = raw.trim().toUpperCase();
  if (t.isEmpty) return null;
  return _callsignRe.hasMatch(t) ? null : 'Letters, digits, / or - (3 to 20 characters).';
}

/// The callsign as the server stores it: trimmed, upper-case; null clears.
String? cleanCallsign(String raw) {
  final t = raw.trim().toUpperCase();
  return t.isEmpty ? null : t;
}

/// The display name as the server stores it: control characters removed, trimmed, at most 40 characters; null clears.
String? cleanDisplayName(String raw) {
  final t = raw.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '').trim();
  if (t.isEmpty) return null;
  return t.length > kDisplayNameMax ? t.substring(0, kDisplayNameMax).trim() : t;
}

/// The server's record of the person's settings.
class DriverSettings {
  /// `account` (key linked to a website account) or `driver` (this key alone).
  final ZoneScope scope;
  final String? callsign;
  final String? display;
  final bool anonymous;

  /// Null on a `driver` scope key: the leaderboard needs an account.
  final bool? leaderboardOptIn;
  final int trimM;
  final List<PrivacyZone> zones;

  /// Last change of each field, anywhere (app, website, admin). Missing or null = never changed.
  final Map<String, DateTime> updatedAt;
  const DriverSettings({
    required this.scope,
    this.callsign,
    this.display,
    this.anonymous = false,
    this.leaderboardOptIn,
    this.trimM = kTrimDefaultM,
    this.zones = const [],
    this.updatedAt = const {},
  });

  /// Null when [j] is not `{settings: {...}}`.
  static DriverSettings? tryParse(Object? j) {
    final s = j is Map ? j['settings'] : null;
    if (s is! Map) return null;
    final anon = s['anonymous'];
    final lb = s['leaderboardOptIn'];
    final t = s['trimM'];
    final zones = s['privacyZones'];
    final up = <String, DateTime>{};
    final u = s['updatedAt'];
    if (u is Map) {
      for (final e in u.entries) {
        final v = e.value is String ? DateTime.tryParse(e.value as String) : null;
        if (e.key is String && v != null) up[e.key as String] = v.toUtc();
      }
    }
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    return DriverSettings(
      scope: parseZoneScope(s['scope']) ?? ZoneScope.driver,
      callsign: str(s['callsign']),
      display: str(s['display']),
      anonymous: anon == true,
      leaderboardOptIn: lb is bool ? lb : null,
      trimM: t is num && t.isFinite ? t.round().clamp(0, kTrimMaxM) : kTrimDefaultM,
      zones: zones is List ? [for (final x in zones) ?PrivacyZone.tryParse(x)] : const [],
      updatedAt: up,
    );
  }

  Object? valueOf(SettingField f) => switch (f) {
        SettingField.callsign => callsign,
        SettingField.display => display,
        SettingField.anonymous => anonymous,
        SettingField.leaderboardOptIn => leaderboardOptIn ?? false,
      };

  Map<String, dynamic> toJson() => {
        'scope': scope.name,
        'callsign': callsign,
        'display': display,
        'anonymous': anonymous,
        'leaderboardOptIn': leaderboardOptIn,
        'trimM': trimM,
        'privacyZones': [for (final z in zones) z.toJson()],
        'updatedAt': {for (final e in updatedAt.entries) e.key: e.value.toIso8601String()},
      };
}

/// What `POST driver-privacy/purge` answered: how many earlier uploads inside the zones were (or, for a dry run, would be)
/// removed from the server.
class ZonePurgeResult {
  final bool dryRun;
  final int pings;
  final int positions;
  final int heard;
  final int sessions;
  const ZonePurgeResult({this.dryRun = false, this.pings = 0, this.positions = 0, this.heard = 0, this.sessions = 0});

  /// Anything stored inside the zones at all.
  int get total => pings + positions + heard;

  static ZonePurgeResult? tryParse(Object? j) {
    if (j is! Map) return null;
    final p = j['purged'];
    if (p is! Map) return null;
    int n(Object? v) => v is num && v.isFinite ? v.round() : 0;
    return ZonePurgeResult(
        dryRun: j['dryRun'] == true, pings: n(p['pings']), positions: n(p['positions']), heard: n(p['heard']), sessions: n(p['sessions']));
  }
}
