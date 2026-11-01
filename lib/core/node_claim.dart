// Node claims: "this repeater / radio is mine", for MANAGING it (name, position visibility, several radios, deleting its
// data, alerts). A claim never gates recording, upload or counting: nothing blocks a radio or a driver from feeding data.
//
// Wire contract (server: meshcore-insights; spec: meshsonar-infra/docs/planning/claim-observer-and-repeater-spec-2026-10-31.md):
//   POST   /api/cmh/claim-start     {pubkey, kind: sign|advert}            -> 201 ClaimChallenge
//   POST   /api/cmh/claim-complete  {challengeId, signature}               -> 200 {claim}
//   GET    /api/cmh/claim-status    ?challengeId=                          -> {state, claim?, seenAdvertAt?}
//   GET    /api/cmh/my-radios                                              -> {claims: [Claim]}
//   DELETE /api/cmh/claim           ?pubkey=                               -> {released: true}
//   PATCH  /api/cmh/claim           {pubkey, displayName?, positionPublic?, notes?} -> {claim}
// All with `x-driver-key`. The server NEVER receives a repeater admin password. Pure Dart: no Flutter imports.
import 'dart:typed_data';

import '../radio/crypto.dart' show fromHex;

/// A 32-byte MeshCore public key as 64 lower-case hex characters.
final RegExp _pubkeyRe = RegExp(r'^[0-9a-f]{64}$');
bool isPublicKeyHex(String s) => _pubkeyRe.hasMatch(s);

/// Normalises what a person pasted into a public key (spaces, `0x`, upper case); null when it is not 64 hex characters.
String? normalizePublicKey(String raw) {
  var t = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (t.startsWith('0x')) t = t.substring(2);
  return isPublicKeyHex(t) ? t : null;
}

enum ClaimNodeType { repeater, room, observer, companion, unknown }

ClaimNodeType parseClaimNodeType(Object? v) => switch (v) {
      'repeater' => ClaimNodeType.repeater,
      'room' => ClaimNodeType.room,
      'observer' => ClaimNodeType.observer,
      'companion' => ClaimNodeType.companion,
      _ => ClaimNodeType.unknown,
    };

/// How the claim was proven. `other` is any method a newer server adds (shown as "verified").
enum ClaimMethod { signature, advert, login, other }

ClaimMethod parseClaimMethod(Object? v) => switch (v) {
      'signature' => ClaimMethod.signature,
      'advert' => ClaimMethod.advert,
      'login' => ClaimMethod.login,
      _ => ClaimMethod.other,
    };

/// Why a claim ended (`releasedReason`): you gave it up, another owner proved control, or a moderator removed it.
enum ClaimEndReason { released, replaced, moderator, unknown }

ClaimEndReason parseEndReason(Object? v) => switch (v) {
      'released' => ClaimEndReason.released,
      'replaced' => ClaimEndReason.replaced,
      'moderator' => ClaimEndReason.moderator,
      _ => ClaimEndReason.unknown,
    };

String claimEndText(ClaimEndReason r) => switch (r) {
      ClaimEndReason.released => 'You released it',
      ClaimEndReason.replaced => 'Another owner proved control',
      ClaimEndReason.moderator => 'Removed by a moderator',
      ClaimEndReason.unknown => 'No longer yours',
    };

/// claim-start answered 409 `owner: "you"`: this key already owns the radio. Not an error: nothing is started, nothing on
/// the repeater is touched and no password is needed. [claim] is the existing claim when the server sent a readable one.
class ClaimAlreadyYours implements Exception {
  final NodeClaim? claim;
  const ClaimAlreadyYours(this.claim);
  @override
  String toString() => 'ClaimAlreadyYours';
}

/// The deaf-radio / low-battery check of an observer claim (`my-radios`, owner only; website `src/lib/observers/health.ts`).
/// State words: ok, quiet, deaf, offline. Absent from servers before observer health.
class ObserverHealth {
  final String state;
  final DateTime? lastStatusAt, flatSince;
  final int? flatMinutes, batteryMv;
  final bool batteryLow;

  /// falling, steady, rising or unknown.
  final String? batteryTrend;
  const ObserverHealth({required this.state, this.lastStatusAt, this.flatSince, this.flatMinutes, this.batteryMv, this.batteryLow = false, this.batteryTrend});

  static ObserverHealth? tryParse(Object? j) {
    if (j is! Map || j['state'] is! String) return null;
    final st = j['state'] as String;
    if (!const {'ok', 'quiet', 'deaf', 'offline'}.contains(st)) return null;
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
    final b = j['battery'];
    return ObserverHealth(
      state: st,
      lastStatusAt: t(j['lastStatusAt']),
      flatSince: t(j['flatSince']),
      flatMinutes: j['flatMinutes'] is num ? (j['flatMinutes'] as num).round() : null,
      batteryMv: b is Map && b['mv'] is num ? (b['mv'] as num).round() : null,
      batteryLow: b is Map && b['low'] == true,
      batteryTrend: b is Map && b['trend'] is String ? b['trend'] as String : null,
    );
  }

  /// One plain sentence for the state.
  String get words => switch (state) {
        'ok' => 'Hearing packets',
        'quiet' => 'Quiet: not hearing much${flatMinutes == null ? '' : ' (nothing new for ${flatMinutes! ~/ 60 > 0 ? '${flatMinutes! ~/ 60} h ' : ''}${flatMinutes! % 60} min)'}',
        'deaf' => 'Deaf: reporting, but its receiver has heard nothing for a while while other observers did',
        _ => 'Offline: no status report for over 15 minutes',
      };
}

class NodeClaim {
  /// Lower-case hex public key.
  final String pubkey;
  final ClaimNodeType nodeType;
  final ClaimMethod method;
  final DateTime? verifiedAt;
  final String? displayName;

  /// null = the owner has not chosen (the server default applies).
  final bool? positionPublic;
  final String? notes;

  /// The name the node advertises, when the server knows it.
  final String? nodeName;

  /// An ended claim (my-radios lists those of the last 90 days after the active ones).
  final bool ended;
  final DateTime? releasedAt;
  final ClaimEndReason? endReason;

  /// Observer claims only, when the server sends it.
  final ObserverHealth? health;
  const NodeClaim({
    required this.pubkey,
    this.nodeType = ClaimNodeType.unknown,
    this.method = ClaimMethod.other,
    this.verifiedAt,
    this.displayName,
    this.positionPublic,
    this.notes,
    this.nodeName,
    this.ended = false,
    this.releasedAt,
    this.endReason,
    this.health,
  });

  /// What to call this radio: the owner's name for it, else the name it advertises, else a short key.
  String get label {
    final d = displayName?.trim(), n = nodeName?.trim();
    if (d != null && d.isNotEmpty) return d;
    if (n != null && n.isNotEmpty) return n;
    return 'Radio ${pubkey.substring(0, 8)}';
  }

  /// Throws [FormatException] when [j] is not a claim.
  static NodeClaim parse(Object? j) {
    if (j is! Map) throw const FormatException('not a claim');
    final key = j['pubkey'];
    final k = key is String ? normalizePublicKey(key) : null;
    if (k == null) throw const FormatException('claim without a public key');
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    final at = j['verifiedAt'];
    final rel = j['releasedAt'] is String ? DateTime.tryParse(j['releasedAt'] as String)?.toUtc() : null;
    final ended = j['status'] == 'released' || rel != null || j['releasedReason'] != null;
    return NodeClaim(
      pubkey: k,
      nodeType: parseClaimNodeType(j['nodeType']),
      method: parseClaimMethod(j['method']),
      verifiedAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      displayName: s(j['displayName']),
      positionPublic: j['positionPublic'] is bool ? j['positionPublic'] as bool : null,
      notes: s(j['notes']),
      nodeName: s(j['nodeName']),
      ended: ended,
      releasedAt: rel,
      endReason: ended ? parseEndReason(j['releasedReason']) : null,
      health: ObserverHealth.tryParse(j['health']),
    );
  }
}

enum ClaimKind { sign, advert, login }

/// The server's answer to claim-start.
class ClaimChallenge {
  final String id;
  final ClaimKind kind;

  /// kind sign: the bytes to sign (the server sends them as hex of the UTF-8 text).
  final Uint8List? message;

  /// kind advert: `MS` + 4 Crockford base32 characters, to put in the repeater's name.
  final String? code;
  final DateTime expiresAt;
  final String? instructions;
  const ClaimChallenge({required this.id, required this.kind, this.message, this.code, required this.expiresAt, this.instructions});

  /// Throws [FormatException] when the body does not match what was asked for.
  static ClaimChallenge parse(Map<String, dynamic> j, {required ClaimKind asked}) {
    final id = j['challengeId'];
    if (id is! String || id.isEmpty) throw const FormatException('no challenge id');
    final kind = switch (j['kind']) { 'advert' => ClaimKind.advert, 'sign' => ClaimKind.sign, 'login' => ClaimKind.login, _ => null };
    if (kind == null || kind != asked) throw const FormatException('wrong challenge kind');
    final exp = j['expiresAt'] is String ? DateTime.tryParse(j['expiresAt'] as String)?.toUtc() : null;
    if (exp == null) throw const FormatException('no expiry');
    if (kind == ClaimKind.sign) {
      final m = j['message'];
      if (m is! String || m.isEmpty || m.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(m)) {
        throw const FormatException('bad message to sign');
      }
      return ClaimChallenge(id: id, kind: kind, message: fromHex(m), expiresAt: exp);
    }
    if (kind == ClaimKind.login) return ClaimChallenge(id: id, kind: kind, expiresAt: exp, instructions: j['instructions'] is String ? j['instructions'] as String : null);
    final code = j['code'];
    if (code is! String || !RegExp(r'^MS[0-9A-Z]{4}$').hasMatch(code)) throw const FormatException('bad claim code');
    return ClaimChallenge(
        id: id, kind: kind, code: code, expiresAt: exp, instructions: j['instructions'] is String ? j['instructions'] as String : null);
  }
}

enum ClaimState { pending, verified, expired }

class ClaimStatus {
  final ClaimState state;
  final NodeClaim? claim;

  /// When an observer first reported the code in an advert, if it has.
  final DateTime? seenAdvertAt;
  const ClaimStatus({required this.state, this.claim, this.seenAdvertAt});

  static ClaimStatus parse(Map<String, dynamic> j) {
    final state = switch (j['state']) {
      'pending' => ClaimState.pending,
      'verified' => ClaimState.verified,
      'expired' => ClaimState.expired,
      _ => throw const FormatException('unknown claim state'),
    };
    final seen = j['seenAdvertAt'];
    return ClaimStatus(
      state: state,
      claim: j['claim'] == null ? null : NodeClaim.parse(j['claim']),
      seenAdvertAt: seen is String ? DateTime.tryParse(seen)?.toUtc() : null,
    );
  }
}
