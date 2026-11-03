// The result of one login to a repeater or room, in the words the login sheet needs. Wrong password (the node answered with
// PUSH 0x86) and no reply (silence) are different outcomes on purpose: the sheet shows them differently. Pure Dart.
import 'claim_radio.dart';
import 'repeater_admin.dart' show AdminErrorKind, AdminException, loginRefusedMessage;

enum LoginKind {
  /// Logged in with the admin password.
  admin,

  /// Logged in as a guest (read only, or read and post in a room).
  guest,

  /// The node answered and did not accept the password (0x86).
  wrongPassword,

  /// No answer in time: wrong password on silent firmware, out of range, stale route or a busy node.
  noReply,

  /// Another remote request holds the radio's single slot; the login did not run.
  busy,
  notConnected,
  cancelled,
  other,
}

class LoginOutcome {
  final LoginKind kind;
  final String message;

  /// Seconds the login waited for an answer (set for noReply).
  final int? waitedSecs;
  const LoginOutcome(this.kind, [this.message = '', this.waitedSecs]);

  bool get ok => kind == LoginKind.admin || kind == LoginKind.guest;
  bool get isAdmin => kind == LoginKind.admin;
}

/// Maps what the radio layer throws to a [LoginKind].
LoginOutcome classifyLoginError(Object e, {int? waitedSecs}) {
  if (e is AdminException) {
    return switch (e.kind) {
      AdminErrorKind.wrongPassword => LoginOutcome(LoginKind.wrongPassword, e.message),
      AdminErrorKind.silent => LoginOutcome(LoginKind.noReply, e.message, waitedSecs),
      AdminErrorKind.radioLost => LoginOutcome(LoginKind.notConnected, e.message),
      AdminErrorKind.busy => LoginOutcome(LoginKind.busy, e.message),
      AdminErrorKind.cancelled => LoginOutcome(LoginKind.cancelled, e.message),
      _ => LoginOutcome(LoginKind.other, e.message),
    };
  }
  if (e is ClaimRadioException) {
    return switch (e.kind) {
      ClaimRadioError.silent => LoginOutcome(LoginKind.noReply, e.message, waitedSecs),
      ClaimRadioError.notConnected => LoginOutcome(LoginKind.notConnected, 'Your radio is not connected.'),
      ClaimRadioError.radio when e.message == loginRefusedMessage => const LoginOutcome(LoginKind.wrongPassword, 'That password was not accepted.'),
      _ => LoginOutcome(LoginKind.other, e.message),
    };
  }
  return const LoginOutcome(LoginKind.other, 'Something went wrong. Try again.');
}
