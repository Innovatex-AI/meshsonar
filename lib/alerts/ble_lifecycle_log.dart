// BleLifecycleLog: the evidence trail for spike S1 (does the link survive backgrounding, jetsam and relaunch?).
//
// Differences from the in-memory diagnostic log (lib/core/diagnostics.dart):
//  * It is written to a file line by line, so it SURVIVES the app being killed. After a suspend/kill/relaunch test the
//    lines from before the kill are still there.
//  * Every line has a wall-clock time with seconds and the app's lifecycle state (fg/bg) at that moment.
//  * It holds no message text, no keys, no positions: event names, counts and the radio's display name only.
//
// Entry kinds are fixed words so results can be compared between runs: launch, lifecycle, link, connect, reconnect,
// inbound, drain, notify, keeper, note.
import 'dart:io';

import 'package:flutter/foundation.dart';

class BleLogEntry {
  final DateTime at;
  final String kind;
  final String detail;
  final bool foreground;
  const BleLogEntry(this.at, this.kind, this.detail, this.foreground);

  static String two(int v) => v.toString().padLeft(2, '0');

  String get line =>
      '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}:${two(at.second)} ${foreground ? 'fg' : 'bg'} $kind $detail';
}

class BleLifecycleLog extends ChangeNotifier {
  final File? file;
  final DateTime Function() _clock;
  final int maxLines;
  final List<BleLogEntry> _entries = [];
  bool _foreground = true;

  BleLifecycleLog({this.file, DateTime Function()? clock, this.maxLines = 1500}) : _clock = clock ?? DateTime.now;

  List<BleLogEntry> get entries => List.unmodifiable(_entries);
  bool get foreground => _foreground;

  /// Reads the file written by earlier runs. Those lines come first, then a `launch` line for this run.
  Future<void> load() async {
    final f = file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final lines = await f.readAsLines();
      for (final l in lines.skip(lines.length > maxLines ? lines.length - maxLines : 0)) {
        final m = RegExp(r'^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) (fg|bg) (\S+) ?(.*)$').firstMatch(l);
        if (m == null) continue;
        _entries.add(BleLogEntry(
          DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!)),
          m[8]!,
          m[9]!,
          m[7] == 'fg',
        ));
      }
      notifyListeners();
    } catch (_) {}
  }

  void setForeground(bool fg) => _foreground = fg;

  void add(String kind, [String detail = '']) {
    final e = BleLogEntry(_clock(), kind, detail.replaceAll('\n', ' '), _foreground);
    _entries.add(e);
    if (_entries.length > maxLines) _entries.removeRange(0, _entries.length - maxLines);
    final f = file;
    if (f != null) {
      try {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('${e.line}\n', mode: FileMode.append, flush: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Rewrites the file from memory when it grew past twice the cap.
  Future<void> compact() async {
    final f = file;
    if (f == null) return;
    try {
      await f.writeAsString(_entries.map((e) => '${e.line}\n').join(), flush: true);
    } catch (_) {}
  }

  Future<void> clear() async {
    _entries.clear();
    try {
      await file?.writeAsString('');
    } catch (_) {}
    notifyListeners();
  }

  /// Text for pasting back to the lead: header with what to know, then every line.
  String export({required String header}) => [header, ..._entries.map((e) => e.line)].join('\n');
}
