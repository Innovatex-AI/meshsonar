// The Channels reads of the Network tab (build 71), on the `/v1` base client (v1_client.dart). Website twin:
// `/channels` (src/lib/analyzer/channels-client.ts, contract 8.5):
//   GET  /v1/channels                        the channels heard in the scope, with 24 h counts (not paged)
//   GET  /v1/channels/{id}/messages          one channel, newest first; `page.next` = older, `page.prev` = newer (poll)
//   GET  /v1/messages/search?q=              decoded text only, never hidden messages; `q` is 2 to 100 characters
//   POST /v1/messages/{id}/report            anyone, 10 an hour per connection; answers 202 with a receipt
// The scope is the host: a region host reads its region, the hub reads every region (rows then carry `regions`).
// Only public channel text the API already serves is read; nothing is sent but the search words and a report's
// reason and note. A report is sent ONCE: it is never retried by this client.
// Offline: the channel list and the first page of a channel are stored by the shared ETag client (etag_client.dart),
// so both come back with their "as of" time when the network fails; older pages, polls and search are not stored.
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import '../region_overview_api.dart' show RegionDataState, RegionDataStatus;
import 'v1_client.dart';

export 'v1_client.dart';

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _i(Object? v) => v is num && v.isFinite ? v.toInt() : null;
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

/// Rows asked per page of a channel, and the row count at which a reader stops loading older pages.
const int channelPageSize = 50;
const int channelReaderCap = 500;

/// Rows asked per page of a search, and the length the server accepts for `q`.
const int messageSearchPageSize = 30;
const int messageSearchMinChars = 2;
const int messageSearchMaxChars = 100;

/// The longest note a report carries.
const int reportNoteMaxChars = 500;

/// One row of `GET /v1/channels`.
class ChannelRow {
  /// `public`, `tag:<name>` or `enc:<hh>`.
  final String id;
  final String? name;

  /// `public`, `hashtag` or `unknown` (a channel whose key the server does not hold).
  final String kind;

  /// Two hex characters.
  final String hashByte;
  final bool decodable;
  final int messages24h;
  final int? senders24h;
  final DateTime? lastMessageAt;

  /// The name written inside the last message: a claim, not verified.
  final String? lastSender;

  /// Hub and group scope: the regions it was heard in (slugs).
  final List<String> regions;
  const ChannelRow({
    required this.id,
    this.name,
    required this.kind,
    required this.hashByte,
    required this.decodable,
    this.messages24h = 0,
    this.senders24h,
    this.lastMessageAt,
    this.lastSender,
    this.regions = const [],
  });

  /// True when the text cannot be read here (no key on the server).
  bool get private => !decodable || kind == 'unknown' || id.startsWith('enc:');

  String get label => name ?? (private ? 'Private channel $hashByte' : id);

  static ChannelRow? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']);
    if (id == null) return null;
    return ChannelRow(
      id: id,
      name: _s(j['name']),
      kind: _s(j['kind']) ?? 'unknown',
      hashByte: _s(j['hashByte']) ?? (id.startsWith('enc:') ? id.substring(4) : ''),
      decodable: j['decodable'] == true,
      messages24h: _i(j['messages24h']) ?? 0,
      senders24h: _i(j['senders24h']),
      lastMessageAt: v1Time(j['lastMessageAt']),
      lastSender: _s(j['lastSender']),
      regions: [if (j['regions'] is List) for (final r in j['regions'] as List) if (r is String) r],
    );
  }
}

/// A message of a channel, or a search hit ([highlight] is then set).
class ChannelMessage {
  final String id, packetHash;
  final String channelId;
  final String? channelName;

  /// The name written inside the message. NOT verified: anyone holding the channel key can write any name.
  final String? sender;

  /// Null on a hidden message and on a channel whose key the server does not hold.
  final String? text;

  /// True when a moderator hid it: the row stays, the text is gone.
  final bool hidden;
  final DateTime? senderTime;
  final DateTime firstSeen;
  final int heardBy, hops;
  final double? bestSnr;

  /// Search hits: `[start, end)` ranges of [text] that matched.
  final List<(int, int)> highlight;
  const ChannelMessage({
    required this.id,
    required this.packetHash,
    required this.channelId,
    this.channelName,
    this.sender,
    this.text,
    this.hidden = false,
    this.senderTime,
    required this.firstSeen,
    this.heardBy = 0,
    this.hops = 0,
    this.bestSnr,
    this.highlight = const [],
  });

  static ChannelMessage? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']);
    final seen = v1Time(j['firstSeen']);
    if (id == null || seen == null) return null;
    final ch = j['channel'] is Map ? j['channel'] as Map : const {};
    final hl = <(int, int)>[];
    if (j['highlight'] is List) {
      for (final h in j['highlight'] as List) {
        if (h is List && h.length == 2 && h[0] is num && h[1] is num) hl.add(((h[0] as num).toInt(), (h[1] as num).toInt()));
      }
    }
    return ChannelMessage(
      id: id,
      packetHash: _s(j['packetHash']) ?? id,
      channelId: _s(ch['id']) ?? '',
      channelName: _s(ch['name']),
      sender: _s(j['sender']),
      text: j['text'] is String ? j['text'] as String : null,
      hidden: j['hidden'] == true,
      senderTime: v1Time(j['senderTime']),
      firstSeen: seen,
      heardBy: _i(j['heardBy']) ?? 0,
      hops: _i(j['hops']) ?? 0,
      bestSnr: _d(j['bestSnr']),
      highlight: hl,
    );
  }
}

/// The answer of `GET /v1/channels`.
class ChannelListPage {
  final List<ChannelRow> rows;
  final DateTime? offlineAsOf;
  final RegionDataStatus status;

  /// `meta.status.code`, e.g. `channel_store_off`.
  final String? statusCode;

  /// `meta.region.name`: the scope the server used.
  final String? scopeName;
  const ChannelListPage({required this.rows, this.offlineAsOf, required this.status, this.statusCode, this.scopeName});
}

/// One page of messages or search hits. Rows are newest first, as the server sends them.
class MessagePage {
  final List<ChannelMessage> rows;

  /// Cursor of the next (older) page; null at the end.
  final String? next;

  /// Cursor for "anything newer than the newest row I hold" (first page and polls only).
  final String? prev;
  final DateTime? offlineAsOf;
  final RegionDataStatus status;
  const MessagePage({required this.rows, this.next, this.prev, this.offlineAsOf, required this.status});
}

/// The reasons a report can give, in the site's order, with the site's labels.
const Map<String, String> reportReasons = {
  'spam': 'Spam',
  'harassment': 'Harassment',
  'personal_info': 'Personal information',
  'illegal': 'Illegal content',
  'other': 'Something else',
};

/// The site's own sentence about what a report does (message-row.tsx REPORT_EXPLAINER).
const String reportExplainer =
    "A report sends this message's id, the reason and your note to MeshSonar's moderators. They read it and can hide the "
    'message on this site; the radio packet itself stays in the packet record. Reports are not shown to anyone else, and '
    'you do not need an account. One connection can send 10 reports an hour.';

/// What `POST /v1/messages/{id}/report` answers.
class ReportReceipt {
  final String id, messageId;
  const ReportReceipt({required this.id, required this.messageId});
}

/// Whether the scope has a packet feed at all (`GET /v1/packets?limit=1`, `meta.status.code == no_packet_feed`).
class PacketFeedProbe {
  final bool hasFeed;

  /// The server's own sentence when there is none.
  final String? reason;
  final String? scopeName;
  const PacketFeedProbe({required this.hasFeed, this.reason, this.scopeName});
  static const PacketFeedProbe unknown = PacketFeedProbe(hasFeed: true);
}

/// True when [status] (with its `code` when known) says the scope has no packet feed. The typed status has no code,
/// so the server's sentence ("No packet feed covers ...") is the fallback.
bool isNoPacketFeed(RegionDataStatus? status, {String? code}) {
  if (code == 'no_packet_feed') return true;
  if (status == null || status.state != RegionDataState.unavailable) return false;
  return (status.reason ?? '').toLowerCase().contains('no packet feed');
}

/// The probe's answer per host, kept for the session (a region does not gain a feed while the app is open often
/// enough to ask every time). Cleared by [resetPacketFeedProbes].
final Map<String, PacketFeedProbe> _feedProbes = {};

/// For tests, and pull-to-refresh on a "no packet feed" card.
void resetPacketFeedProbes([String? baseUrl]) => baseUrl == null ? _feedProbes.clear() : _feedProbes.remove(Uri.parse(baseUrl).host);

class ChannelsApi {
  final String baseUrl;
  final V1Client v1;
  ChannelsApi(this.baseUrl, {http.Client? client, DateTime Function()? clock}) : v1 = V1Client(baseUrl, client: client, clock: clock);

  /// `GET /v1/channels`. Throws [V1Error] or [V1NotLive].
  Future<ChannelListPage> list() async {
    final env = await v1.getPage('channels', ChannelRow.tryParse);
    final st = env.meta.raw['status'];
    return ChannelListPage(
      rows: env.data,
      offlineAsOf: env.offlineAsOf,
      status: env.meta.status,
      statusCode: st is Map ? _s(st['code']) : null,
      scopeName: env.meta.region?.name,
    );
  }

  static const Map<String, String?> _order = {'order': 'newest_first'};

  /// One page of a channel, newest first. [cursor] is a `next` (older) or a `prev` (newer) cursor of an earlier page.
  Future<MessagePage> messages(String channelId, {String? cursor, int limit = channelPageSize}) async {
    final env = await v1.getPage('channels/${Uri.encodeComponent(channelId)}/messages', ChannelMessage.tryParse, query: _order, cursor: cursor, limit: limit);
    return MessagePage(rows: env.data, next: env.page?.next, prev: env.page?.prev, offlineAsOf: env.offlineAsOf, status: env.meta.status);
  }

  /// `GET /v1/messages/search`. [q] must be [messageSearchMinChars] to [messageSearchMaxChars] characters (the caller
  /// checks; the server answers 400 `bad_param` otherwise). [channelId] narrows it to one channel.
  Future<MessagePage> search(String q, {String? channelId, String? cursor, int limit = messageSearchPageSize}) async {
    final env = await v1.getPage('messages/search', ChannelMessage.tryParse, query: {'q': q, 'channel': channelId}, cursor: cursor, limit: limit);
    return MessagePage(rows: env.data, next: env.page?.next, offlineAsOf: env.offlineAsOf, status: env.meta.status);
  }

  /// Sends one report, once ([V1Client.post] never retries). [reason] is a key of [reportReasons]. The body is exactly
  /// `{reason, note?}`: the server rejects any other field. Throws [V1Error] (429 `rate_limited` carries `retryAfter`;
  /// a network failure has `offline`) or [V1NotLive] (reports are not switched on).
  Future<ReportReceipt> report(String messageId, {required String reason, String? note}) async {
    final n = note?.trim() ?? '';
    final body = <String, String>{'reason': reason, if (n.isNotEmpty) 'note': n.length > reportNoteMaxChars ? n.substring(0, reportNoteMaxChars) : n};
    final env = await v1.post<ReportReceipt>('messages/${Uri.encodeComponent(messageId)}/report', body, (d) {
      final id = d is Map ? _s(d['id']) : null;
      if (id == null) throw const FormatException('no receipt id');
      return ReportReceipt(id: id, messageId: _s((d as Map)['messageId']) ?? messageId);
    });
    return env.data;
  }

  /// Whether this host's scope has a packet feed. Asked once per host per session; a failure answers
  /// [PacketFeedProbe.unknown] (and is not remembered), so a network error never reads as "no feed".
  Future<PacketFeedProbe> packetFeed() async {
    final host = Uri.parse(baseUrl).host;
    final hit = _feedProbes[host];
    if (hit != null) return hit;
    try {
      final env = await v1.get<Object?>('packets', (d) => d, query: const {'limit': '1'});
      if (env.offline) return PacketFeedProbe.unknown;
      final st = env.meta.raw['status'];
      final none = isNoPacketFeed(env.meta.status, code: st is Map ? _s(st['code']) : null);
      return _feedProbes[host] = PacketFeedProbe(hasFeed: !none, reason: none ? env.meta.status.reason : null, scopeName: env.meta.region?.name);
    } catch (_) {
      return PacketFeedProbe.unknown;
    }
  }

  void close() => v1.close();
}

/// Tests replace this to inject a fake HTTP client; the Channels screens build their API through it.
ChannelsApi Function(String baseUrl) channelsApiFactory = (b) => ChannelsApi(b);

/// Merges a poll's rows ([newer], any order) into [held] (oldest first), dropping ids already held, keeping oldest
/// first and at most [cap] rows (the oldest go first). Returns the new list and how many rows were really new.
(List<ChannelMessage>, int) mergeNewer(List<ChannelMessage> held, List<ChannelMessage> newer, {int cap = channelReaderCap}) {
  final have = {for (final m in held) m.id};
  final add = [for (final m in newer) if (!have.contains(m.id)) m]..sort(_oldestFirst);
  if (add.isEmpty) return (held, 0);
  final all = [...held, ...add];
  return (all.length > cap ? all.sublist(all.length - cap) : all, add.length);
}

/// Puts an older page ([older], newest first from the server) in front of [held] (oldest first), dropping ids already
/// held. The caller stops asking for older pages at [channelReaderCap].
List<ChannelMessage> mergeOlder(List<ChannelMessage> held, List<ChannelMessage> older) {
  final have = {for (final m in held) m.id};
  return [...[for (final m in older) if (!have.contains(m.id)) m]..sort(_oldestFirst), ...held];
}

int _oldestFirst(ChannelMessage a, ChannelMessage b) {
  final c = a.firstSeen.compareTo(b.firstSeen);
  return c != 0 ? c : a.id.compareTo(b.id);
}
