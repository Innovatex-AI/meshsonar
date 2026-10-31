// "Delete my account" inside the app (App Store guideline 5.1.1(v)): what the server answered to
// `DELETE driver-delete`, in words a person can act on. Kept out of app_state.dart like context_upload_hook.dart.
import '../core/api.dart';
import 'messages.dart';

enum AccountDeleteStatus {
  /// The server deleted the key and everything uploaded with it; this phone forgot the key.
  done,

  /// The server no longer knew the key (401): nothing of it is left on the server. This phone forgot the key.
  alreadyGone,

  /// No driver key on this phone: no account exists to delete.
  noKey,

  /// This server has no `driver-delete` (capability absent, or 404/405): the website hand-off is the way.
  unavailable,

  /// 429: 5 deletes an hour.
  rateLimited,

  /// No connection. Nothing was changed and nothing is queued: the person presses the button again with signal.
  offline,

  /// Any other failure. Nothing was changed.
  failed,
}

class AccountDeleteOutcome {
  final AccountDeleteStatus status;
  final String message;
  final DriverDeleteResult? result;
  const AccountDeleteOutcome(this.status, this.message, {this.result});

  /// The key is gone from the server (deleted now, or it already was) and from this phone.
  bool get removed => status == AccountDeleteStatus.done || status == AccountDeleteStatus.alreadyGone;

  factory AccountDeleteOutcome.fromResult(DriverDeleteResult r) => AccountDeleteOutcome(AccountDeleteStatus.done, accountDeletedText(r), result: r);

  factory AccountDeleteOutcome.fromError(Object e) {
    if (e is CmatException) {
      switch (e.status) {
        case 401:
          return const AccountDeleteOutcome(AccountDeleteStatus.alreadyGone,
              'The server no longer has this driver key, so nothing of yours is left there. The key is removed from this phone.');
        case 404 || 405:
          return const AccountDeleteOutcome(AccountDeleteStatus.unavailable, accountDeleteUnavailableText);
        case 429:
          return const AccountDeleteOutcome(AccountDeleteStatus.rateLimited,
              'The server allows 5 delete requests an hour. Nothing was deleted. Try again in an hour.');
        case null:
          return const AccountDeleteOutcome(AccountDeleteStatus.offline, accountDeleteOfflineText);
      }
    }
    return AccountDeleteOutcome(AccountDeleteStatus.failed,
        '${friendlyError(e, action: 'Deleting your account')} Nothing was deleted. Your key and drives are unchanged; you can try again.');
  }

  static const AccountDeleteOutcome noKey = AccountDeleteOutcome(
      AccountDeleteStatus.noKey, 'This phone has no driver key, so there is no account to delete.');
  static const AccountDeleteOutcome unavailable = AccountDeleteOutcome(AccountDeleteStatus.unavailable, accountDeleteUnavailableText);
}

/// Said when the app cannot reach the server. Deleting an account is never queued behind the person's back.
const String accountDeleteOfflineText = 'Deleting your account needs an internet connection and there is none right now. Nothing was '
    'deleted and nothing is waiting to be sent. Try again when you have signal.';

const String accountDeleteUnavailableText = 'This server cannot delete an account from the app. Use the website to delete it.';

/// "The server deleted your driver key, 3 drives (120 pings), ... "
String accountDeletedText(DriverDeleteResult r) {
  String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
  final held = r.sessions == 0 && r.pings == 0
      ? 'It held no drives.'
      : 'It also deleted ${n(r.sessions, 'drive', 'drives')} (${n(r.pings, 'ping', 'pings')}), '
          '${n(r.samples, 'phone and radio reading', 'phone and radio readings')}, ${n(r.telemetry, 'packet header', 'packet headers')} '
          'and ${n(r.reports, 'problem report', 'problem reports')}.';
  return 'The server deleted your driver key. $held';
}
