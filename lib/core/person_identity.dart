// ID steps 2 and 3 on the wire (site PRs meshcore-insights #366 and #368; docs/PLATFORM_CONTRACT.md "Radio proof" and
// "Devices and the email hand-off"). Everything here is behind `capabilities.radioProof`, which the server advertises only
// while app_config.radio_proof is 'on' (OFF on production at build 73): without it the app makes none of these calls.
//   POST radio-proof-start {pubkey}                 -> {proofId, purpose, message (hex of UTF-8 text), expiresAt}
//   POST radio-proof-complete {proofId, signature}  -> claimed | yours {claim} | owned_by_other {...}
//   POST radio-proof-decide {proofId, decision}     -> joined | taken | join_pending | join_denied | refused
//   GET person-notices, POST person-notice, GET|POST person-prefs
//   GET person-devices, POST person-device-rename, POST person-device-remove, POST link-start
// Parsing is tolerant: a row that cannot be read is skipped. Never a key, a key hint or an email. Pure Dart.
import 'dart:convert';
import 'dart:typed_data';

import '../radio/crypto.dart' show fromHex;
import 'node_claim.dart';

/// The capability flag in `site-config.capabilities`.
const String kRadioProofCapability = 'radioProof';

/// Every text the radio is asked to sign for this feature starts with this; the app refuses anything else.
const String kProofTextPrefix = 'meshsonar-';

/// What the server's text must look like for [pubkeyHex]: `meshsonar-login:v1:<host>:connect:<pubkey>:<random>:<expiry>`.
/// The app checks the prefix, the purpose and that it names THIS radio, so a text for a broker login (`v1_...`) or for
/// another key can never be signed. Returns the UTF-8 text, or null when the bytes must not be signed.
String? signableProofText(Uint8List bytes, String pubkeyHex) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    return null;
  }
  if (!text.startsWith(kProofTextPrefix) || text.startsWith('v1_')) return null;
  final parts = text.split(':');
  if (parts.length != 7 || parts[0] != 'meshsonar-login' || parts[1] != 'v1' || parts[3] != 'connect') return null;
  if (parts[4].toLowerCase() != pubkeyHex.toLowerCase()) return null;
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(parts[5]) || int.tryParse(parts[6]) == null) return null;
  return text;
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
String? _s(Object? v, [int max = 120]) => v is String && v.trim().isNotEmpty ? (v.length > max ? v.substring(0, max) : v) : null;

class ProofStart {
  final String proofId;
  final Uint8List message;
  final DateTime expiresAt;
  const ProofStart({required this.proofId, required this.message, required this.expiresAt});

  static ProofStart parse(Map<String, dynamic> j) {
    final id = j['proofId'], m = j['message'];
    final exp = _time(j['expiresAt']);
    if (id is! String || id.isEmpty) throw const FormatException('no proof id');
    if (m is! String || m.isEmpty || m.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(m)) throw const FormatException('bad message');
    if (exp == null) throw const FormatException('no expiry');
    return ProofStart(proofId: id, message: fromHex(m), expiresAt: exp);
  }
}

enum ProofKind { claimed, yours, ownedByOther }

/// The answer of radio-proof-complete.
class ProofResult {
  final ProofKind kind;
  final NodeClaim? claim;

  // owned_by_other
  final String? proofId;
  final DateTime? decideUntil;

  /// The owner's callsign or display name; null when that person is anonymous. Never an email.
  final String? ownerName;
  final ClaimNodeType ownerNodeType;
  final bool askFirst;

  /// False for a device that is signed in to an account: it may only take the radio.
  final bool canJoin;
  const ProofResult({
    required this.kind,
    this.claim,
    this.proofId,
    this.decideUntil,
    this.ownerName,
    this.ownerNodeType = ClaimNodeType.unknown,
    this.askFirst = false,
    this.canJoin = true,
  });

  static ProofResult parse(Map<String, dynamic> j) {
    switch (j['outcome']) {
      case 'claimed':
        return ProofResult(kind: ProofKind.claimed, claim: NodeClaim.parse(j['claim']));
      case 'yours':
        return ProofResult(kind: ProofKind.yours, claim: NodeClaim.parse(j['claim']));
      case 'owned_by_other':
        final id = j['proofId'];
        if (id is! String || id.isEmpty) throw const FormatException('no proof id');
        final o = j['owner'] is Map ? j['owner'] as Map : const {};
        return ProofResult(
          kind: ProofKind.ownedByOther,
          proofId: id,
          decideUntil: _time(j['decideUntil']),
          ownerName: _s(o['name'], 60),
          ownerNodeType: parseClaimNodeType(o['nodeType']),
          askFirst: j['askFirst'] == true,
          canJoin: j['canJoin'] != false,
        );
    }
    throw const FormatException('unknown outcome');
  }
}

enum DecideKind { joined, taken, joinPending, joinDenied, refused }

class DecideResult {
  final DecideKind kind;
  final NodeClaim? claim;
  final String? requestId;

  /// refused: `device_has_account`.
  final String? reason;
  const DecideResult(this.kind, {this.claim, this.requestId, this.reason});

  static DecideResult parse(Map<String, dynamic> j) {
    switch (j['outcome']) {
      case 'joined':
        return const DecideResult(DecideKind.joined);
      case 'taken':
        NodeClaim? c;
        try {
          c = NodeClaim.parse(j['claim']);
        } on FormatException {
          c = null;
        }
        return DecideResult(DecideKind.taken, claim: c);
      case 'join_pending':
        return DecideResult(DecideKind.joinPending, requestId: _s(j['requestId'], 64));
      case 'join_denied':
        return const DecideResult(DecideKind.joinDenied);
      case 'refused':
        return DecideResult(DecideKind.refused, reason: _s(j['reason'], 40));
    }
    throw const FormatException('unknown outcome');
  }
}

/// One device of the person (`person-devices`). Never carries a key.
class PersonDevice {
  final String id;
  final String name;
  final bool nameSet;

  /// `app` or `meshmapper` (a MeshMapper import).
  final String kind;
  final String status;
  final DateTime? createdAt, lastSeenAt;
  final String? model, appBuild, os;

  /// This phone.
  final bool current;
  const PersonDevice({
    required this.id,
    required this.name,
    this.nameSet = false,
    this.kind = 'app',
    this.status = 'approved',
    this.createdAt,
    this.lastSeenAt,
    this.model,
    this.appBuild,
    this.os,
    this.current = false,
  });

  bool get isImport => kind == 'meshmapper';
  bool get removed => status == 'revoked' || status == 'banned' || status == 'rejected';

  /// "iPhone17,1 · build 73 · iOS 27.2" with whatever the device reported.
  String get detail {
    final b = appBuild;
    return [if (isImport) 'MeshMapper import', ?model, if (b != null) 'build $b', ?os].join(' · ');
  }

  static PersonDevice? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 64);
    if (id == null) return null;
    return PersonDevice(
      id: id,
      name: _s(j['name'], 60) ?? 'Device',
      nameSet: j['nameSet'] == true,
      kind: j['kind'] == 'meshmapper' ? 'meshmapper' : 'app',
      status: _s(j['status'], 16) ?? 'approved',
      createdAt: _time(j['createdAt']),
      lastSeenAt: _time(j['lastSeenAt']),
      model: _s(j['model'], 40),
      appBuild: _s(j['appBuild'], 20),
      os: _s(j['os'], 30),
      current: j['current'] == true,
    );
  }
}

/// A notice for the person (`person-notices`): a device joined, a radio was taken, or a device asks to join.
class PersonNotice {
  final String id;

  /// `device_joined`, `radio_taken` or `join_request`.
  final String kind;
  final DateTime? createdAt;
  final bool read;

  /// null (open), `approved` or `denied`.
  final String? resolution;
  final String? pubkey, nodeName;
  final String? deviceId, deviceName;
  final bool deviceRemoved;
  const PersonNotice({
    required this.id,
    required this.kind,
    this.createdAt,
    this.read = false,
    this.resolution,
    this.pubkey,
    this.nodeName,
    this.deviceId,
    this.deviceName,
    this.deviceRemoved = false,
  });

  bool get isOpenRequest => kind == 'join_request' && resolution == null;

  /// One plain sentence.
  String get words {
    final dev = deviceName ?? 'A device';
    final radio = nodeName ?? (pubkey == null ? 'a radio' : 'radio ${pubkey!.substring(0, pubkey!.length < 8 ? pubkey!.length : 8)}');
    return switch (kind) {
      'device_joined' => '$dev joined your account.',
      'radio_taken' => 'Someone proved they hold $radio, so it moved to their account. Your drives and devices were not touched.',
      'join_request' =>
        resolution == 'approved'
            ? 'You approved $dev.'
            : resolution == 'denied'
            ? 'You turned $dev down.'
            : '$dev wants to join your account because it connected $radio.',
      _ => 'Something changed on your account.',
    };
  }

  static PersonNotice? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 64), kind = _s(j['kind'], 24);
    if (id == null || kind == null) return null;
    final d = j['device'] is Map ? j['device'] as Map : null;
    return PersonNotice(
      id: id,
      kind: kind,
      createdAt: _time(j['createdAt']),
      read: j['read'] == true,
      resolution: j['resolution'] is String ? j['resolution'] as String : null,
      pubkey: _s(j['pubkey'], 64),
      nodeName: _s(j['nodeName'], 60),
      deviceId: d == null ? null : _s(d['id'], 64),
      deviceName: d == null ? null : _s(d['name'], 60),
      deviceRemoved: d != null && d['removed'] == true,
    );
  }
}

class PersonNotices {
  final List<PersonNotice> notices;
  final bool askFirst;
  const PersonNotices(this.notices, this.askFirst);
  int get unread => notices.where((n) => !n.read || n.isOpenRequest).length;

  static PersonNotices parse(Map<String, dynamic> j) => PersonNotices([
    if (j['notices'] is List)
      for (final n in j['notices'] as List) ?PersonNotice.tryParse(n),
  ], j['askFirst'] == true);
}

/// `link-start`: open [url] in the system browser; the person signs in on the site and adds this device there.
class LinkStart {
  final String code;
  final Uri url;
  final DateTime expiresAt;
  const LinkStart({required this.code, required this.url, required this.expiresAt});

  static LinkStart parse(Map<String, dynamic> j) {
    final c = j['code'], u = j['url'] is String ? Uri.tryParse(j['url'] as String) : null;
    final exp = _time(j['expiresAt']);
    // only ever the MeshSonar site, over https: a link the server sends is not opened blindly
    if (c is! String ||
        c.isEmpty ||
        u == null ||
        u.scheme != 'https' ||
        !(u.host == 'meshsonar.com' || u.host.endsWith('.meshsonar.com')) ||
        exp == null) {
      throw const FormatException('bad link');
    }
    return LinkStart(code: c, url: u, expiresAt: exp);
  }
}
