// What the repeater admin layer needs from a radio beyond a claim: binary and anonymous requests, remote telemetry, the
// raw status block and a CLI call that matches its reply by tag. [MeshCoreCompanionLink] implements it; a
// [RadioSession] over such a link forwards it (LinkRadioSession). Pure Dart.
import 'dart:typed_data';

import 'claim_radio.dart';

abstract class RepeaterAdminRadio implements ClaimRadio {
  /// CMD_SEND_BINARY_REQ: [request] is the request bytes (see repeater_wire.dart); returns the answer's data, zero padding
  /// included. Throws [ClaimRadioException] (silent = no answer in time).
  Future<Uint8List> binaryRequest(String keyHex, List<int> request, {Duration? timeout});

  /// CMD_SEND_ANON_REQ: works without a login, direct route only, and the repeater answers at most 4 per 180 s to
  /// everybody together. Same return and errors as [binaryRequest].
  Future<Uint8List> anonRequest(String keyHex, List<int> request, {Duration? timeout});

  /// The remote node's CayenneLPP telemetry block (big endian, zero padded).
  Future<Uint8List> telemetryRequest(String keyHex, {Duration? timeout});

  /// The 56-byte status block plus padding (STATUS_REQ), for [RepeaterStats.parse].
  Future<Uint8List> statusBytes(String keyHex, {Duration? timeout});

  /// Sends `[tag]|[command]` as CLI data and waits for the reply that starts with the same `[tag]|` (a late reply to an
  /// earlier command is skipped). [tag] is two characters. Returns the reply without the tag.
  Future<String> runTaggedCli(String keyHex, String tag, String command, {Duration? timeout});
}
