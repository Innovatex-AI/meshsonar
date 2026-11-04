// Pure parts of the Network segment (chat plan 4.12): which contacts go in which section and in what order, the battery chip
// of the "Your radio" card and the 60 second foreground poll behind it. No Flutter widgets in here.
import 'dart:async';

import '../radio/protocol.dart' show BattAndStorageFrame;
import '../radio/tools/device_settings.dart' show estimateBatteryPercent;
import 'models.dart';

/// Rows each section shows before "Show all N".
const int kNetworkSectionRows = 5;

/// The three node kinds the Network segment lists, in on-screen order.
const List<ContactType> kNetworkTypes = [ContactType.repeater, ContactType.room, ContactType.sensor];

/// Favourites first, then the most recently heard, then by name.
int compareNetworkRows(Contact a, Contact b) {
  if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
  final ta = a.lastHeardMs ?? 0, tb = b.lastHeardMs ?? 0;
  if (ta != tb) return tb.compareTo(ta);
  return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
}

/// [contacts] split into Repeaters / Rooms / Sensors, blocked ones left out, filtered by [query] (name or key start),
/// each list in [compareNetworkRows] order.
Map<ContactType, List<Contact>> groupNetwork(Iterable<Contact> contacts, {String query = ''}) {
  final q = query.trim().toLowerCase();
  final out = {for (final t in kNetworkTypes) t: <Contact>[]};
  for (final c in contacts) {
    final list = out[c.type];
    if (list == null || c.blocked) continue;
    if (q.isNotEmpty && !c.displayName.toLowerCase().contains(q) && !c.publicKey.toLowerCase().startsWith(q)) continue;
    list.add(c);
  }
  for (final l in out.values) {
    l.sort(compareNetworkRows);
  }
  return out;
}

/// What the battery chip on the radio card says.
enum BatteryChipKind {
  /// No radio, so no chip.
  none,

  /// Asked, no answer yet.
  loading,
  ok,

  /// At or under [kBatteryLowPercent].
  low,

  /// The radio did not give a reading (old firmware, busy link): the chip says so rather than showing a stale number.
  unavailable,
}

const int kBatteryLowPercent = 20;

class BatteryChipState {
  final BatteryChipKind kind;
  final int? percent;
  final int? millivolts;
  const BatteryChipState(this.kind, {this.percent, this.millivolts});

  static const none = BatteryChipState(BatteryChipKind.none);
  static const loading = BatteryChipState(BatteryChipKind.loading);
  static const unavailable = BatteryChipState(BatteryChipKind.unavailable);

  /// A reading from CMD 20. The percentage is an estimate from the cell voltage.
  factory BatteryChipState.fromFrame(BattAndStorageFrame f) {
    final p = estimateBatteryPercent(f.batteryMv);
    return BatteryChipState(p <= kBatteryLowPercent ? BatteryChipKind.low : BatteryChipKind.ok, percent: p, millivolts: f.batteryMv);
  }

  bool get visible => kind != BatteryChipKind.none;

  String get label => switch (kind) {
        BatteryChipKind.none => '',
        BatteryChipKind.loading => '…',
        BatteryChipKind.unavailable => '–',
        _ => '$percent%',
      };

  String get spoken => switch (kind) {
        BatteryChipKind.none => '',
        BatteryChipKind.loading => 'Battery, reading',
        BatteryChipKind.unavailable => 'Battery level not available',
        BatteryChipKind.low => 'Battery low, about $percent percent',
        BatteryChipKind.ok => 'Battery about $percent percent',
      };

  @override
  bool operator ==(Object other) => other is BatteryChipState && other.kind == kind && other.percent == percent && other.millivolts == millivolts;
  @override
  int get hashCode => Object.hash(kind, percent, millivolts);
}

/// Reads the radio's battery (CMD 20) now and then every [interval]. The widget starts it while the Network segment is on
/// screen and the app is in the foreground, and stops it otherwise, so a hidden or backgrounded app asks nothing.
class BatteryPoller {
  final Future<BattAndStorageFrame?> Function() fetch;
  final Duration interval;
  final void Function(BatteryChipState) onState;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;
  int polls = 0;

  BatteryPoller({required this.fetch, required this.onState, this.interval = const Duration(seconds: 60)});

  bool get running => _timer != null;

  void start() {
    if (_disposed || _timer != null) return;
    onState(BatteryChipState.loading);
    unawaited(poll());
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> poll() async {
    if (_busy || _disposed) return;
    _busy = true;
    polls++;
    BatteryChipState s;
    try {
      final f = await fetch();
      s = f == null ? BatteryChipState.unavailable : BatteryChipState.fromFrame(f);
    } catch (_) {
      s = BatteryChipState.unavailable;
    }
    _busy = false;
    if (!_disposed && running) onState(s);
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
