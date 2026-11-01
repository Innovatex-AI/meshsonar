// MessageSync: drains the radio's offline message queue, persist-first.
//
// Why it is careful (design doc B section 3, firmware 81dbae5):
//  - Every DM and channel message the radio receives is appended to a RAM queue (addToOfflineQueue, MyMesh.cpp 224) and
//    announced with PUSH_MSG_WAITING (0x83), a one-byte push that goes through the same lossy BLE queue as everything else
//    (4 frames deep on ESP32, a full queue DROPS frames: SerialBLEInterface). So PUSH_MSG_WAITING can be lost: besides
//    draining on the push, on connect and after a timeout, [startPolling] asks every few seconds.
//  - SYNC_NEXT_MESSAGE (10) is destructive: it pops the head and sends it. If the frame is lost on the way or the app dies
//    with it in memory, the message is gone. So every frame is handed to the persister and that is AWAITED before the next
//    SYNC_NEXT_MESSAGE goes out.
//  - The queue holds 16 frames by default (256 on many builds). When full, the oldest CHANNEL message is evicted, or the new
//    frame is dropped if there is none (MyMesh.cpp 224-244). Draining early and often is the only defence.
//  - The same queue carries CHANNEL_DATA_RECV (27) datagrams (isChannelMsg, MyMesh.cpp 219-222): the drain steps over them
//    instead of stopping.
//
// Idempotent: a message with the same conversation, sender timestamp and text as one seen before is dropped (a retried DM
// arrives again as a new frame; replaying a frame list twice yields each message once). Pure Dart.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'inbound.dart';
import 'protocol.dart';

/// The one thing MessageSync needs from the link.
abstract class MessageSource {
  bool get isConnected;

  /// Sends SYNC_NEXT_MESSAGE and returns the radio's answer.
  Future<Frame> syncNextMessage();
}

class MessageSync {
  final MessageSource source;
  final DateTime Function() _clock;

  /// Frames taken per drain at most. The queue holds up to 256.
  final int maxPerDrain;

  /// How often the safety poll asks while there are listeners.
  final Duration pollInterval;

  /// Called for EVERY contact text frame including CLI replies (txt_type 1), for the claim flows.
  void Function(ContactTextFrame frame)? onContactText;

  /// Persist-first hook: awaited for every message before the next is requested.
  Future<void> Function(InboundMessage message)? persist;

  /// Called when persisting a message failed after the retries (it is still emitted; the radio no longer has it).
  void Function(InboundMessage message, Object error)? onPersistError;

  /// Called when a drain finishes (the radio said "no more", or the link went) with how many message frames it took out
  /// of the radio's queue. A drain that finds many frames waiting means the app was away or slow while the radio's small
  /// queue (16 by default) filled, so the oldest may already be gone: the alerts layer warns on it (RadioQueueWatch).
  void Function(int frames)? onDrained;

  final _out = StreamController<InboundMessage>.broadcast();
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  static const int _seenMax = 512;
  Timer? _poll;
  bool _again = false;
  bool _disposed = false;

  /// Counters for the debug screen.
  int drained = 0;
  int duplicates = 0;
  int persistFailures = 0;
  int drains = 0;

  MessageSync(this.source, {DateTime Function()? clock, this.maxPerDrain = 512, this.pollInterval = const Duration(seconds: 5)})
      : _clock = clock ?? DateTime.now {
    _out
      ..onListen = _maybePoll
      ..onCancel = _maybePoll;
  }

  /// Messages, after they were persisted. Broadcast. Listening starts the safety poll.
  Stream<InboundMessage> get messages => _out.stream;

  bool get draining => _run != null;

  void _maybePoll() {
    if (_disposed) return;
    if (_out.hasListener) {
      _poll ??= Timer.periodic(pollInterval, (_) {
        if (source.isConnected && _run == null) unawaited(drain());
      });
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Asks for a drain without waiting (PUSH_MSG_WAITING). Coalesces with one that is running.
  void requestDrain() {
    if (_disposed) return;
    unawaited(drain());
  }

  /// Drains until the radio says there are no more messages. A call while a drain runs makes it go round once more and
  /// completes when that is done.
  Future<void> drain() {
    if (_disposed) return Future.value();
    final running = _run;
    if (running != null) {
      _again = true; // a message was queued while we were finishing: go round once more
      return running;
    }
    drains++;
    return _run = () async {
      _runFrames = 0;
      try {
        do {
          _again = false;
          await _drainOnce();
        } while (_again && source.isConnected && !_disposed);
      } finally {
        _run = null;
        lastDrainFrames = _runFrames;
        if (_runFrames > 0) onDrained?.call(_runFrames);
      }
    }();
  }

  Future<void>? _run;
  int _runFrames = 0;

  /// Message frames taken by the most recent drain (0 when the queue was empty).
  int lastDrainFrames = 0;

  Future<void> _drainOnce() async {
    try {
      for (var n = 0; n < maxPerDrain && source.isConnected && !_disposed; n++) {
        final f = await source.syncNextMessage();
        if (f is ChannelMsgFrame || f is ContactTextFrame || f is ContactMsgFrame || f is ChannelDataFrame) _runFrames++;
        if (f is ChannelMsgFrame) {
          await _deliver(_fromChannel(f));
          continue;
        }
        if (f is ContactTextFrame) {
          onContactText?.call(f);
          if (f.txtType != txtTypeCliData && f.txtType != txtTypeCliCommand) await _deliver(_fromContact(f));
          continue;
        }
        if (f is ContactMsgFrame || f is ChannelDataFrame) continue; // undecodable or binary: step over it
        break; // NO_MORE_MESSAGES, an error, or anything else
      }
    } catch (_) {
      // best effort: the next push or poll tries again
    }
  }

  Future<void> _deliver(InboundMessage m) async {
    if (!_seen.add(m.contentKey)) {
      duplicates++;
      return;
    }
    if (_seen.length > _seenMax) _seen.remove(_seen.first);
    drained++;
    final p = persist;
    if (p != null) {
      Object? error;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await p(m);
          error = null;
          break;
        } catch (e) {
          error = e;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      if (error != null) {
        persistFailures++;
        onPersistError?.call(m, error);
      }
    }
    if (!_out.isClosed) _out.add(m);
  }

  InboundMessage _fromChannel(ChannelMsgFrame f) {
    final split = splitSenderPrefix(f.text);
    return InboundMessage(
      kind: InboundKind.channel,
      channelIndex: f.channelIndex,
      senderName: split.$1,
      text: split.$2,
      fullText: f.text,
      txtType: f.txtType,
      senderTimestamp: f.timestamp,
      receivedAt: _clock(),
      snrDb: f.snrDb,
      pathLen: f.pathLen,
      raw: f.raw ?? Uint8List(0),
    );
  }

  InboundMessage _fromContact(ContactTextFrame f) => InboundMessage(
        kind: InboundKind.contact,
        senderPrefixHex: f.prefixHex,
        signerPrefixHex: f.signerPrefixHex,
        text: f.text,
        fullText: f.text,
        txtType: f.txtType,
        senderTimestamp: f.timestamp,
        receivedAt: _clock(),
        snrDb: f.snrDb,
        pathLen: f.pathLen,
        raw: f.data,
      );

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _poll = null;
    unawaited(_out.close());
  }
}

/// A channel message's text is "sender name: body" (BaseChatMesh.cpp ~523). Returns (name, body); name is null when the
/// text has no such prefix. The name ends at the FIRST ": ".
(String?, String) splitSenderPrefix(String text) {
  final i = text.indexOf(': ');
  if (i <= 0 || i > 32) return (null, text);
  return (text.substring(0, i), text.substring(i + 2));
}
