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
enum ClaimMethod { signature, advert, other }

ClaimMethod parseClaimMethod(Object? v) => switch (v) {
      'signature' => ClaimMethod.signature,
      'advert' => ClaimMethod.advert,
      _ => ClaimMethod.other,
    };

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
  const NodeClaim({
    required this.pubkey,
    this.nodeType = ClaimNodeType.unknown,
    this.method = ClaimMethod.other,
    this.verifiedAt,
    this.displayName,
    this.positionPublic,
    this.notes,
    this.nodeName,
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
    return NodeClaim(
      pubkey: k,
      nodeType: parseClaimNodeType(j['nodeType']),
      method: parseClaimMethod(j['method']),
      verifiedAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      displayName: s(j['displayName']),
      positionPublic: j['positionPublic'] is bool ? j['positionPublic'] as bool : null,
      notes: s(j['notes']),
      nodeName: s(j['nodeName']),
    );
  }
}

enum ClaimKind { sign, advert }

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
    final kind = j['kind'] == 'advert' ? ClaimKind.advert : (j['kind'] == 'sign' ? ClaimKind.sign : null);
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
