// Drive-context upload and erase, the parts of AppState that are not state (stream 7 WP5): what an erase request
// answered, in words a person in a car can read. Kept out of app_state.dart so that file only gains a few lines.
import '../core/api.dart';
import 'messages.dart';

enum ContextEraseStatus {
  /// The server erased it (counts in [ContextEraseOutcome.result]).
  done,

  /// This server has no `DELETE drive-context` (capabilities.driveContextErase absent).
  unavailable,

  /// No driver key on this phone, so nothing of this phone's is on a server.
  noKey,

  /// 401 / 403: the server does not recognise the key.
  keyRefused,

  /// 429: 10 erase calls an hour.
  rateLimited,

  /// No connection; the request is remembered and retried.
  offline,
  failed,
}

class ContextEraseOutcome {
  final ContextEraseStatus status;
  final ContextEraseResult? result;
  final String message;
  const ContextEraseOutcome(this.status, this.message, {this.result});

  bool get done => status == ContextEraseStatus.done;

  /// The request will be tried again by itself.
  bool get retrying => status == ContextEraseStatus.offline || status == ContextEraseStatus.rateLimited;

  factory ContextEraseOutcome.fromResult(ContextEraseResult r) => ContextEraseOutcome(ContextEraseStatus.done, eraseCountsText(r), result: r);

  factory ContextEraseOutcome.fromError(Object e) {
    if (e is CmatException) {
      switch (e.status) {
        case 429:
          return const ContextEraseOutcome(ContextEraseStatus.rateLimited,
              'The server allows 10 erase requests an hour. Try again in an hour; this one is remembered and sent again by itself.');
        case 404 || 405:
          return const ContextEraseOutcome(ContextEraseStatus.unavailable, serverCannotEraseText);
        case 401 || 403:
          return const ContextEraseOutcome(ContextEraseStatus.keyRefused,
              'The server does not recognise this driver key, so it cannot match any data to you. Nothing was erased.');
        case null:
          return const ContextEraseOutcome(
              ContextEraseStatus.offline, 'Can\'t reach the server. The erase is remembered and sent again by itself when there is signal.');
      }
    }
    return ContextEraseOutcome(ContextEraseStatus.failed, friendlyError(e, action: 'The erase'));
  }

  static const ContextEraseOutcome unavailable = ContextEraseOutcome(ContextEraseStatus.unavailable, serverCannotEraseText);
  static const ContextEraseOutcome noKey = ContextEraseOutcome(
      ContextEraseStatus.noKey, 'This phone has no driver key, so there is nothing of yours on the server to erase.');
}

/// The drive-context part of an upload's one-line result ("5 context samples", "2 context items refused by the
/// server"), honest about refusals and about a fallback to the plain drive. Empty when the sync had no context activity.
List<String> contextReportParts(SyncReport r) {
  String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
  return [
    if (r.samplesStored > 0) n(r.samplesStored, 'context sample', 'context samples'),
    if (r.contextPingsUpdated > 0) 'context added to ${n(r.contextPingsUpdated, 'ping', 'pings')}',
    if (r.samplesRejected + r.contextRejected > 0)
      '${n(r.samplesRejected + r.contextRejected, 'context item', 'context items')} refused by the server',
    if (r.contextFallbacks > 0)
      'the server refused the context of ${n(r.contextFallbacks, 'drive', 'drives')} as a whole, so only the drive went up; the context is tried again next time',
  ];
}

/// Said plainly wherever an erase is not possible; it claims nothing beyond that.
const String serverCannotEraseText = 'This server cannot erase drive context from the app. What it already holds stays '
    'there until its operator removes it.';

/// "The server erased 12 samples and the context of 40 pings on 3 drives." / "The server held none of it."
String eraseCountsText(ContextEraseResult r) {
  if (r.sessions == 0 && r.pings == 0 && r.samples == 0) return 'The server held none of it.';
  String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
  return 'The server erased ${n(r.samples, 'sample', 'samples')} and the context of ${n(r.pings, 'ping', 'pings')} '
      'on ${n(r.sessions, 'drive', 'drives')}.';
}
