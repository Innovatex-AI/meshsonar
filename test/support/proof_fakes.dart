// A fake MeshSonar server for radio proof (ID step 2): hands out `meshsonar-login:v1:...` text, verifies the radio's REAL Ed25519
// signature, and answers the three outcomes of the plan (claimed / yours / owned_by_other) and the decide step.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/person_identity.dart';
import 'package:meshsonar/core/person_observers.dart';
import 'package:meshsonar/radio/crypto.dart' show fromHex;

import '../ui/fakes.dart' show FakeCmatClient;

class FakeProofClient extends FakeCmatClient {
  FakeProofClient([Uri? baseUrl]) : super(baseUrl ?? Uri.parse('https://example.org'));
  final cr.Ed25519 _ed = cr.Ed25519();
  int _n = 0;
  final Map<String, ({String pubkey, String text, bool used})> _proofs = {};

  /// What the next complete answers when the signature is good: claimed (default), yours, ownedByOther.
  ProofKind answer = ProofKind.claimed;
  String? ownerName = 'KE4BFI';
  bool canJoin = true, askFirst = false;
  DateTime? decideUntil;

  /// Replaces the text the server issues (to prove the app refuses what it must not sign).
  String Function(String pubkey)? textMaker;
  Object? startError, completeError, decideError;

  /// decide answers in order; the last repeats.
  List<DecideResult> decideAnswers = const [DecideResult(DecideKind.joined)];
  int _d = 0;

  /// false = the app tests use a radio that signs zeros; the flow tests keep the real check.
  bool verifySignature = true;

  final List<String> wire = [];
  int completes = 0, decides = 0;
  final List<bool> decisions = [];

  @override
  Future<ProofStart> radioProofStart(String driverKey, String pubkey) async {
    wire.add('start $driverKey $pubkey');
    if (startError != null) throw startError!;
    final id = 'proof-${++_n}';
    final text = textMaker?.call(pubkey) ??
        'meshsonar-login:v1:meshsonar.com:connect:$pubkey:${'ab' * 16}:${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120}';
    _proofs[id] = (pubkey: pubkey, text: text, used: false);
    return ProofStart(proofId: id, message: Uint8List.fromList(utf8.encode(text)), expiresAt: DateTime.now().add(const Duration(minutes: 2)));
  }

  @override
  Future<ProofResult> radioProofComplete(String driverKey, String proofId, String signatureHex) async {
    wire.add('complete $driverKey $proofId');
    completes++;
    if (completeError != null) throw completeError!;
    final p = _proofs[proofId];
    if (p == null || p.used) throw const CmatException('used', status: 410, code: 'used');
    final ok = !verifySignature ||
        await _ed.verify(utf8.encode(p.text),
        signature: cr.Signature(fromHex(signatureHex), publicKey: cr.SimplePublicKey(fromHex(p.pubkey), type: cr.KeyPairType.ed25519)));
    if (!ok) throw const CmatException('bad', status: 422, code: 'bad_signature');
    _proofs[proofId] = (pubkey: p.pubkey, text: p.text, used: true);
    final claim = NodeClaim(pubkey: p.pubkey, nodeType: ClaimNodeType.companion, method: ClaimMethod.signature, displayName: 'My radio');
    return switch (answer) {
      ProofKind.claimed => ProofResult(kind: ProofKind.claimed, claim: claim),
      ProofKind.yours => ProofResult(kind: ProofKind.yours, claim: claim),
      ProofKind.ownedByOther => ProofResult(
          kind: ProofKind.ownedByOther,
          proofId: proofId,
          decideUntil: decideUntil ?? DateTime.now().add(const Duration(minutes: 10)),
          ownerName: ownerName,
          ownerNodeType: ClaimNodeType.companion,
          askFirst: askFirst,
          canJoin: canJoin),
    };
  }

  @override
  Future<DecideResult> radioProofDecide(String driverKey, String proofId, {required bool join}) async {
    wire.add('decide $proofId ${join ? 'join' : 'take'}');
    decides++;
    decisions.add(join);
    if (decideError != null) throw decideError!;
    final r = decideAnswers[_d < decideAnswers.length ? _d : decideAnswers.length - 1];
    _d++;
    return r;
  }

  // ---- ID step 3 ----
  List<PersonDevice> devices = [
    const PersonDevice(id: 'd1', name: 'iPhone', model: 'iPhone17,1', appBuild: '73', os: 'iOS 27.2', current: true),
    const PersonDevice(id: 'd2', name: 'iPad', model: 'iPad16,3', appBuild: '72', os: 'iPadOS 27.2'),
  ];
  List<PersonNotice> notices = const [];
  bool askFirstPref = false;
  Object? linkError;
  Uri linkUrl = Uri.parse('https://meshsonar.com/link?code=ABCDEFGHJKMN');

  @override
  Future<List<PersonDevice>> personDevices(String driverKey) async {
    wire.add('person-devices');
    return List.of(devices);
  }

  @override
  Future<PersonNotices> personNotices(String driverKey) async {
    wire.add('person-notices');
    return PersonNotices(List.of(notices), askFirstPref);
  }

  @override
  Future<void> renameDevice(String driverKey, String id, String? name) async {
    wire.add('rename $id ${name ?? '-'}');
    devices = [
      for (final d in devices) d.id == id ? PersonDevice(id: d.id, name: name ?? 'Device', nameSet: name != null, current: d.current, model: d.model, appBuild: d.appBuild, os: d.os) : d,
    ];
  }

  @override
  Future<void> removeDevice(String driverKey, String id) async {
    wire.add('remove $id');
    devices = [for (final d in devices) if (d.id != id) d];
  }

  @override
  Future<void> personNoticeAct(String driverKey, String id, String action) async {
    wire.add('notice $id $action');
    notices = [
      for (final n in notices)
        if (n.id == id)
          PersonNotice(id: n.id, kind: n.kind, createdAt: n.createdAt, read: true, resolution: action == 'approve' ? 'approved' : (action == 'deny' ? 'denied' : n.resolution), pubkey: n.pubkey, nodeName: n.nodeName, deviceName: n.deviceName)
        else
          n,
    ];
  }

  @override
  Future<bool> setAskFirst(String driverKey, bool askFirst) async {
    wire.add('ask-first $askFirst');
    return askFirstPref = askFirst;
  }

  @override
  Future<LinkStart> linkStart(String driverKey) async {
    wire.add('link-start');
    if (linkError != null) throw linkError!;
    return LinkStart(code: 'ABCDEFGHJKMN', url: linkUrl, expiresAt: DateTime.now().add(const Duration(minutes: 10)));
  }

  // ---- ID step 5: the person's observers ----
  PersonObservers observerList = PersonObservers.empty;
  Object? observersError, offerError, prefError, claimError;

  @override
  Future<PersonObservers> personObservers(String driverKey) async {
    wire.add('person-observers');
    if (observersError != null) throw observersError!;
    return observerList;
  }

  @override
  Future<OfferOutcome> answerObserverOffer(String driverKey, String key, {required bool accept}) async {
    wire.add('offer $key ${accept ? 'accept' : 'decline'}');
    if (offerError != null) throw offerError!;
    observerList = PersonObservers(observerList.observers, [for (final o in observerList.offers) if (o.key != key) o]);
    return accept ? OfferOutcome.accepted : OfferOutcome.declined;
  }

  @override
  Future<void> setShowRadioName(String driverKey, String key, bool show) async {
    wire.add('pref $key $show');
    if (prefError != null) throw prefError!;
  }

  @override
  Future<NodeClaim> updateClaim(String driverKey, String pubkey, Map<String, Object?> changes) async {
    wire.add('claim-update $pubkey ${changes.entries.map((e) => '${e.key}=${e.value}').join(',')}');
    if (claimError != null) throw claimError!;
    return NodeClaim(pubkey: pubkey, method: ClaimMethod.signature);
  }

  @override
  Future<void> releaseClaim(String driverKey, String pubkey) async {
    wire.add('claim-release $pubkey');
    if (claimError != null) throw claimError!;
    observerList = PersonObservers([for (final o in observerList.observers) if (o.key != pubkey) o], observerList.offers);
  }
}
