// RadioQueueWatch: warns when the radio's small offline message queue was close to full.
//
// Facts (firmware 81dbae5, MyMesh.cpp 224-244, design doc B section 3): every DM and channel message is appended to a RAM
// queue that holds 16 by default (256 on some builds) and is NOT readable from the radio. When it is full the oldest
// channel message is evicted, or a new DM is dropped. The phone empties it by draining; while the phone is away (app
// suspended or closed, Bluetooth off) it only fills.
//
// What we can know: how many frames the next drain took out ([MessageSync.onDrained]). If that is near the queue size the
// radio was nearly full, or full, and anything beyond may be gone. We cannot know how many were already dropped, so
// the wording says "may". This is an after-the-fact estimate; there is no live depth.
import 'package:flutter/foundation.dart';

enum QueueRisk { ok, nearFull, overflowLikely }

class RadioQueueWatch extends ChangeNotifier {
  /// Frames the radio holds at most, as far as we know.
  final int capacity;

  /// Warn from this share of the capacity (0.75 of 16 = 12).
  final double warnFraction;
  final DateTime Function() _clock;

  QueueRisk _risk = QueueRisk.ok;
  int _frames = 0;
  DateTime? _at;

  RadioQueueWatch({this.capacity = 16, this.warnFraction = 0.75, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  QueueRisk get risk => _risk;
  int get frames => _frames;
  DateTime? get at => _at;

  int get warnAt => (capacity * warnFraction).ceil();

  /// A drain took [n] frames out of the radio.
  void onDrained(int n) {
    final next = n >= capacity ? QueueRisk.overflowLikely : (n >= warnAt ? QueueRisk.nearFull : QueueRisk.ok);
    if (next == QueueRisk.ok) return; // a normal drain never clears an earlier warning: the person dismisses it
    if (_risk == QueueRisk.overflowLikely && next == QueueRisk.nearFull) return;
    _risk = next;
    _frames = n;
    _at = _clock();
    notifyListeners();
  }

  void dismiss() {
    if (_risk == QueueRisk.ok) return;
    _risk = QueueRisk.ok;
    notifyListeners();
  }

  /// Plain words for the Chat tab. Null when there is nothing to say.
  String? get message => switch (_risk) {
        QueueRisk.ok => null,
        QueueRisk.nearFull =>
          'Your radio was holding $_frames waiting messages and keeps only about $capacity. '
              'If you stay away longer, the oldest can be lost. Keep MeshSonar connected.',
        QueueRisk.overflowLikely =>
          'Your radio\'s waiting-message queue was full ($_frames). Some messages sent while you were away may have been '
              'dropped by the radio before they reached this phone.',
      };
}
