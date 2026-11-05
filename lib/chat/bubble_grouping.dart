// Grouping of a conversation into runs of bubbles (chat plan 4.2). Pure Dart.
//
// A run is consecutive messages from the same sender (all your own messages count as one sender) at most [runGap] apart on
// the same day. Inside a run the bubbles join (outer radius 18, inner 6); the time line sits under the LAST bubble of a run.
// A centred time separator opens a group when more than [separatorGap] passed since the previous message, or the day changed.
import 'models.dart';

const Duration runGap = Duration(minutes: 3);
const Duration separatorGap = Duration(hours: 1);

class BubbleSlot {
  final ChatMessage message;

  /// Same sender as the next OLDER message within [runGap] (so this bubble continues a run upward).
  final bool joinsOlder;

  /// Same sender as the next NEWER message within [runGap] (so a newer bubble continues this run downward).
  final bool joinsNewer;

  /// A time separator is drawn above this bubble.
  final bool separatorAbove;

  /// Sender name above the first bubble of a run (incoming, channels and rooms only).
  final bool showSender;

  const BubbleSlot({required this.message, required this.joinsOlder, required this.joinsNewer, required this.separatorAbove, required this.showSender});

  bool get firstOfRun => !joinsOlder;
  bool get lastOfRun => !joinsNewer;
}

bool _sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

bool _sameSender(ChatMessage a, ChatMessage b) {
  if (a.isOutgoing != b.isOutgoing) return false;
  if (a.isOutgoing) return true;
  return a.senderName == b.senderName && a.senderPrefix == b.senderPrefix;
}

bool _joins(ChatMessage older, ChatMessage newer) {
  if (!_sameSender(older, newer)) return false;
  if (!_sameDay(older.tsLocalMs, newer.tsLocalMs)) return false;
  return newer.tsLocalMs - older.tsLocalMs <= runGap.inMilliseconds;
}

/// [newestFirst] is the conversation as stored (index 0 = newest). The result has the same order.
List<BubbleSlot> groupMessages(List<ChatMessage> newestFirst, {required bool showSenders}) {
  final out = <BubbleSlot>[];
  for (var i = 0; i < newestFirst.length; i++) {
    final m = newestFirst[i];
    final older = i + 1 < newestFirst.length ? newestFirst[i + 1] : null;
    final newer = i > 0 ? newestFirst[i - 1] : null;
    final joinsOlder = older != null && _joins(older, m);
    final joinsNewer = newer != null && _joins(m, newer);
    final separator = older == null ||
        !_sameDay(older.tsLocalMs, m.tsLocalMs) ||
        m.tsLocalMs - older.tsLocalMs > separatorGap.inMilliseconds;
    out.add(BubbleSlot(
      message: m,
      joinsOlder: joinsOlder,
      joinsNewer: joinsNewer,
      separatorAbove: separator,
      showSender: showSenders && !m.isOutgoing && !joinsOlder && m.senderName != null,
    ));
  }
  return out;
}
