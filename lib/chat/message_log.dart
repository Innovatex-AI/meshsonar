// The message log (build 77, redesign round 3, defect M12): what the phone and the radio said to each other about
// delivery, so the next "it tries and fails" can be read from the phone instead of guessed.
//
//   * one line per command given to the radio and one per reply code, per timeout and per discarded stray frame
//     (from the link, lib/radio/link_log.dart);
//   * one line per delivery confirmation: its code and whether it matched a try (from the outbox);
//   * one line per step the outbox takes for a message: each try with its number, the reset path, the result.
//
// Never in a line: message text, channel secrets, passwords, PINs, private keys, names or positions. Contacts appear as
// the first 4 hex characters of their key, messages as the first 8 characters of their local id.
//
// Kept in the chat database (table message_log, newest [keepRows]); lines are buffered and written in batches so a busy
// link does not cost a database write per frame. Pure Dart.
import '../radio/link_log.dart';
import 'db/chat_database.dart';

class MessageLogLine {
  final int tsMs;

  /// `link` (a frame to or from the radio) or `chat` (a step of the outbox).
  final String source;

  /// The local id of the message the line is about, when it is about one.
  final String? messageId;
  final String text;
  const MessageLogLine(this.tsMs, this.source, this.text, {this.messageId});
}

class MessageLog {
  final ChatDatabase db;
  final int Function() nowMs;

  /// Rows kept in the database (older ones are trimmed).
  final int keepRows;

  /// Lines held in memory before they are written.
  final int batch;
  final List<MessageLogLine> _buffer = [];
  int _sinceTrim = 0;

  MessageLog(this.db, {required this.nowMs, this.keepRows = 6000, this.batch = 40});

  static String shortId(String messageId) => messageId.length <= 8 ? messageId : messageId.substring(0, 8);
  static String shortKey(String publicKeyHex) => publicKeyHex.length <= 4 ? publicKeyHex : publicKeyHex.substring(0, 4);
  static String code(int ack) => (ack & 0xffffffff).toRadixString(16).padLeft(8, '0');

  /// A frame-level line from the radio link.
  void addLink(LinkLogEntry e) => _add(MessageLogLine(e.at.millisecondsSinceEpoch, 'link', e.toString()));

  /// An outbox step. [messageId] ties it to a message so its details can show it.
  void addChat(String text, {String? messageId}) {
    _add(MessageLogLine(nowMs(), 'chat', messageId == null ? '= $text' : '= msg ${shortId(messageId)} $text', messageId: messageId));
    // A step of a message is worth having on disk at once: it is what a failure is read from.
    flush();
  }

  void _add(MessageLogLine l) {
    _buffer.add(l);
    if (_buffer.length >= batch) flush();
  }

  /// Writes the buffered lines. Safe to call often; never throws (a log must not break delivery).
  void flush() {
    if (_buffer.isEmpty || db.isClosed) return;
    final lines = List<MessageLogLine>.of(_buffer);
    _buffer.clear();
    try {
      db.transaction(() {
        final st = db.raw.prepare('INSERT INTO message_log(ts_ms, src, msg_id, line) VALUES (?,?,?,?)');
        try {
          for (final l in lines) {
            st.execute([l.tsMs, l.source, l.messageId, l.text]);
          }
        } finally {
          st.close();
        }
      });
      _sinceTrim += lines.length;
      if (_sinceTrim >= 200) {
        _sinceTrim = 0;
        db.raw.execute('DELETE FROM message_log WHERE id <= (SELECT max(id) FROM message_log) - ?', [keepRows]);
      }
    } catch (_) {
      // dropped: better a hole in the log than a failed send
    }
  }

  static MessageLogLine _row(dynamic r) => MessageLogLine(r['ts_ms'] as int, r['src'] as String, r['line'] as String, messageId: r['msg_id'] as String?);

  /// The newest [limit] lines, oldest first.
  List<MessageLogLine> recent({int limit = 500}) {
    flush();
    if (db.isClosed) return const [];
    final rows = db.raw.select('SELECT * FROM (SELECT * FROM message_log ORDER BY id DESC LIMIT ?) ORDER BY id', [limit]);
    return [for (final r in rows) _row(r)];
  }

  /// Everything logged while [messageId] was being delivered: from just before its first step to just after its last, the
  /// link's frames in between included (commands, replies, strays, confirmations). Oldest first. Empty when the message
  /// has no lines (sent before build 77, or trimmed).
  List<MessageLogLine> forMessage(String messageId, {int marginMs = 3000, int limit = 800}) {
    flush();
    if (db.isClosed) return const [];
    final span = db.raw.select('SELECT min(ts_ms) a, max(ts_ms) b FROM message_log WHERE msg_id = ?', [messageId]).first;
    final a = span['a'] as int?, b = span['b'] as int?;
    if (a == null || b == null) return const [];
    final rows = db.raw.select(
        'SELECT * FROM message_log WHERE ts_ms BETWEEN ? AND ? AND (msg_id IS NULL OR msg_id = ?) ORDER BY id LIMIT ?', [a - marginMs, b + marginMs, messageId, limit]);
    return [for (final r in rows) _row(r)];
  }

  int get count {
    flush();
    return db.isClosed ? 0 : db.raw.select('SELECT count(*) c FROM message_log').first['c'] as int;
  }

  void clear() {
    _buffer.clear();
    if (!db.isClosed) db.raw.execute('DELETE FROM message_log');
  }

  /// The log as plain text for sharing: a short header, then one line per entry with its time. [messageId] limits it to
  /// one message ([forMessage]). [formatTime] turns unix ms into the time shown; the app passes the one time formatter
  /// (local time by default), the fallback here is local time with milliseconds. [header] lines are added as given (app
  /// build, radio firmware): the caller must not put a secret in them.
  String exportText({String? messageId, int limit = 2000, String Function(int ms)? formatTime, List<String> header = const []}) {
    final fmt = formatTime ?? _localTime;
    final lines = messageId == null ? recent(limit: limit) : forMessage(messageId, limit: limit);
    final b = StringBuffer()
      ..writeln('MeshSonar message log')
      ..writeln(messageId == null ? 'Newest ${lines.length} lines' : 'Message ${shortId(messageId)}: ${lines.length} lines');
    for (final h in header) {
      b.writeln(h);
    }
    b
      ..writeln('Key: > command to the radio, < its reply, ! no reply, ~ stray frame discarded, * push from the radio, # note, = message step')
      ..writeln('No message text, keys or passwords are in this log.')
      ..writeln();
    for (final l in lines) {
      b.writeln('${fmt(l.tsMs)}  ${l.text}');
    }
    return b.toString();
  }

  static String _localTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}.${d.millisecond.toString().padLeft(3, '0')}';
  }
}
