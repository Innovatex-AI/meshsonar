// The in-app diagnostic log that problem reports can include: the last [Diagnostics.capacity] events, each one line
// starting with a UTC timestamp. Memory only, so it is empty after an app restart and there is no file to secure.
// Pure Dart: no Flutter imports.
import 'dart:collection';

import 'antenna_profile.dart';
import 'api.dart';

class Diagnostics {
  final int capacity;
  final DateTime Function() _clock;
  final Queue<String> _lines = Queue();

  Diagnostics({this.capacity = 1000, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Records one event (line breaks become spaces, so every event stays one line). The oldest line goes when full.
  void add(String message) {
    _lines.addLast('${_clock().toUtc().toIso8601String()} ${message.replaceAll(RegExp(r'[\r\n]+'), ' ')}');
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
  }

  /// A copy of the log, oldest line first.
  List<String> get lines => List.unmodifiable(_lines);

  void clear() => _lines.clear();
}

/// The settings that help explain a problem, as log lines. Never the driver key, and of the server URL only its host.
List<String> settingsSnapshot(Settings s, {AntennaProfile? antenna}) {
  String onOff(bool v) => v ? 'on' : 'off';
  return [
    'Settings: server ${Uri.tryParse(s.serverUrl)?.host ?? 'not a valid address'}',
    'Settings: driver key ${(s.driverKey ?? '').isEmpty ? 'none' : s.keyStatus.name}',
    'Settings: channel ${s.channel}, auto-ping every ${s.intervalSec} s, minimum distance ${s.minDistanceM} m',
    'Settings: upload at end of drive ${onOff(s.autoSync)}, during drive ${onOff(s.syncDuringDrive)}, '
        'every ${s.syncEveryMin} min',
    'Settings: antenna ${antenna?.summary ?? 'not set'}',
    'Settings: units ${s.units.name}'
        '${s.unitOverrides.isEmpty ? '' : ' (own unit: ${s.unitOverrides.toJson().entries.map((e) => '${e.key} ${e.value}').join(', ')})'}',
  ];
}
