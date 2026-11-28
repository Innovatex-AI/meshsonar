// Typed errors of the MeshSonar radio local API (meshsonar-firmware docs/APP-INTEGRATION.md section 2): the HTTP status
// plus the radio's own `error` text. Never carries a token. Pure Dart.

/// What went wrong, in the terms the screens need.
enum MsErrorKind {
  /// 400: a value was out of range; nothing changed.
  badRequest,

  /// 401: the token is missing, wrong or revoked. The token has been dropped: pair again.
  notPaired,

  /// 403: refused (bad signature, another device, missing `X-MS`).
  forbidden,

  /// 404: the radio does not have this route (older firmware).
  notFound,

  /// 409: not possible now (a probe is running, another device is waiting for approval, ...).
  conflict,

  /// 410: the pairing nonce expired or was already used.
  expired,

  /// 423: the radio is locked.
  locked,

  /// 429: too many tries (5 bad signatures or PINs).
  rateLimited,

  /// 503: the radio is busy; the client already retried once after a second.
  busy,

  /// Any other HTTP status.
  server,

  /// No answer in time.
  timeout,

  /// The radio cannot be reached (phone not on the radio's Wi-Fi, web console Off, radio off).
  notOnWifi,

  /// The radio answered with something that is not the JSON the contract describes.
  badReply,
}

class MsRadioError implements Exception {
  final MsErrorKind kind;

  /// The HTTP status, or null for timeout / notOnWifi / a reply that could not be read.
  final int? status;

  /// The radio's own `error` text when it sent one (show it as is); otherwise a plain English default.
  final String message;

  /// True when [message] is the radio's own text.
  final bool fromRadio;

  const MsRadioError(this.kind, this.message, {this.status, this.fromRadio = false});

  /// Maps an HTTP status and the radio's error text to an error.
  factory MsRadioError.fromStatus(int status, String? radioText) {
    final kind = switch (status) {
      400 => MsErrorKind.badRequest,
      401 => MsErrorKind.notPaired,
      403 => MsErrorKind.forbidden,
      404 => MsErrorKind.notFound,
      409 => MsErrorKind.conflict,
      410 => MsErrorKind.expired,
      423 => MsErrorKind.locked,
      429 => MsErrorKind.rateLimited,
      503 => MsErrorKind.busy,
      _ => MsErrorKind.server,
    };
    final t = radioText?.trim();
    if (t != null && t.isNotEmpty) return MsRadioError(kind, t.length > 200 ? t.substring(0, 200) : t, status: status, fromRadio: true);
    return MsRadioError(kind, defaultMessage(kind), status: status);
  }

  /// Plain English text for a kind when the radio did not say.
  static String defaultMessage(MsErrorKind kind) => switch (kind) {
        MsErrorKind.badRequest => 'The radio did not accept that value.',
        MsErrorKind.notPaired => 'Pair again: the radio no longer knows this app.',
        MsErrorKind.forbidden => 'The radio refused.',
        MsErrorKind.notFound => 'This radio\'s firmware does not have that.',
        MsErrorKind.conflict => 'The radio cannot do that right now.',
        MsErrorKind.expired => 'That took too long. Try again.',
        MsErrorKind.locked => 'The radio is locked.',
        MsErrorKind.rateLimited => 'Too many tries. Wait a minute and try again.',
        MsErrorKind.busy => 'The radio is busy. Try again in a moment.',
        MsErrorKind.server => 'The radio could not do that.',
        MsErrorKind.timeout => 'The radio did not answer in time.',
        MsErrorKind.notOnWifi => 'Not on Wi-Fi: the radio cannot be reached from this phone.',
        MsErrorKind.badReply => 'The radio sent an answer this app cannot read.',
      };

  /// The token is no longer good: the screens offer pairing again.
  bool get needsPairing => kind == MsErrorKind.notPaired;

  /// The radio could not be reached at all (show the "Not on Wi-Fi" state with a retry).
  bool get unreachable => kind == MsErrorKind.notOnWifi || kind == MsErrorKind.timeout;

  @override
  String toString() => 'MsRadioError(${kind.name}${status == null ? '' : ' $status'}): $message';
}
