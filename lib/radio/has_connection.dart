// CMD_HAS_CONNECTION (28): asks the companion radio whether it still holds a live login to a node, so the login sheet can be
// skipped ("Resumed session"). The frame is [28][32-byte node key]; the radio answers OK when a connection exists and
// ERR_NOT_FOUND when not (MyMesh.cpp CMD_HAS_CONNECTION). Kept out of protocol.dart / companion_link.dart (Chat WP12 owns them);
// the link method that sends it is wired later, so until then [AdminSessions] resume relies on this app run's own memory and
// the hardware check is on Andy's real-radio list (HANDOFF section 105).
import 'dart:typed_data';

import 'claim_radio.dart' show RemoteLogin;
import 'protocol.dart' show ErrCode, ErrFrame, Frame, OkFrame;

const int cmdHasConnection = 28;

Uint8List encodeHasConnection(List<int> pubKey32) {
  assert(pubKey32.length == 32);
  return Uint8List.fromList([cmdHasConnection, ...pubKey32]);
}

/// True = still connected; false = the radio does not hold a login; null = the answer could not be read.
bool? hasConnectionFromFrame(Frame f) {
  if (f is OkFrame) return true;
  if (f is ErrFrame && f.code == ErrCode.notFound) return false;
  return null;
}

/// Logins this app run made and did not log out of, by node key (64 hex), so reopening the node skips the sheet while the
/// radio still holds the connection. Holds no password.
class AdminSessions {
  static final Map<String, RemoteLogin> _live = {};
  static RemoteLogin? of(String keyHex) => _live[keyHex.toLowerCase()];
  static void set(String keyHex, RemoteLogin l) => _live[keyHex.toLowerCase()] = l;
  static void drop(String keyHex) => _live.remove(keyHex.toLowerCase());
  static void clear() => _live.clear();
}
