// What a radio must be able to do for a claim: sign with its own key, and log in to / talk to a repeater over the
// mesh. [MeshCoreCompanionLink] implements it (lib/radio/companion_link.dart); tests use a fake radio over the real
// frames (test/support/claim_radio_fake.dart). Pure Dart: no Flutter imports.
import 'dart:typed_data';

import 'protocol.dart' show RepeaterStatus;

enum ClaimRadioError {
  /// The radio link is gone (BLE dropped, app closed it).
  notConnected,

  /// The radio does not know this repeater and could not add it (contact table full).
  noContact,

  /// No answer from the repeater in time. For a login this is ALSO what a wrong password looks like: repeaters stay
  /// silent on a wrong password (simple_repeater/MyMesh.cpp handleLogin returns 0).
  silent,

  /// The radio answered with an error code, or an unexpected frame.
  radio,

  /// This firmware does not have the command (signing, login).
  unsupported,
}

class ClaimRadioException implements Exception {
  final ClaimRadioError kind;
  final String message;
  final int? errCode;
  const ClaimRadioException(this.kind, this.message, [this.errCode]);
  @override
  String toString() => 'ClaimRadioException(${kind.name}): $message${errCode == null ? '' : ' (err $errCode)'}';
}

/// What a repeater said when we logged in.
class RemoteLogin {
  /// The repeater says this login may run CLI commands (its ACL role is admin).
  final bool isAdmin;
  final int? firmwareLevel;

  /// The permission byte the repeater / room stored for this login (low two bits: 0 guest, 1 read only, 2 read and write,
  /// 3 admin); null on old firmware that does not send it. A room needs read and write to accept posts.
  final int? aclPermissions;
  const RemoteLogin({required this.isAdmin, this.firmwareLevel, this.aclPermissions});

  /// This login may post to a room (read and write, or admin).
  bool get canPost => isAdmin || ((aclPermissions ?? 0) & 3) >= 2;
}

abstract class ClaimRadio {
  bool get isConnected;

  /// This radio's own public key, lower-case hex (SELF_INFO bytes 4-35); null before the link started.
  String? get selfPublicKey;

  /// Ed25519 signature (64 bytes) by this radio's own identity key over [data] (up to 8 KB), using
  /// CMD_SIGN_START / SIGN_DATA / SIGN_FINISH.
  Future<Uint8List> sign(Uint8List data);

  /// Makes sure the radio has the repeater [pubkeyHex] as a contact (login and CLI need it). [nodeType] is a
  /// protocol.dart [AdvType] value.
  Future<void> ensureContact(String pubkeyHex, {required int nodeType, String name = ''});

  /// Logs in to [pubkeyHex] over the mesh. Throws [ClaimRadioException] (silent = no answer in [timeout]; also a wrong
  /// password). The password only goes into the radio's command frame; it is never stored or logged.
  Future<RemoteLogin> login(String pubkeyHex, String password, {Duration? timeout});

  /// Ends the keep-alive connection to [pubkeyHex] on the radio side. Never throws.
  Future<void> logout(String pubkeyHex);

  /// Sends one CLI command to a logged-in repeater and returns its reply text (e.g. `get name` -> `> My Repeater`).
  /// Throws [ClaimRadioException] (silent = no reply in [timeout]).
  Future<String> runCli(String pubkeyHex, String command, {Duration? timeout});

  /// One status request (uptime, airtime, counters); null when the repeater did not answer. Never throws.
  Future<RepeaterStatus?> status(String pubkeyHex, {Duration? timeout});
}
