// Diagnostic log (spec m1-app-0.4.0 §3): in-memory ring of timestamped UTC lines, last 1,000, plus a settings
// snapshot that never holds the driver key or the server URL's path.
//
// API under test (lib/core/diagnostics.dart; names chosen by Q):
//   Diagnostics({int capacity = 1000, DateTime Function()? clock}); void add(String message); List<String> get lines
//     (oldest first, each "<UTC ISO-8601 ending in Z> <message>"); void clear()
//   List<String> settingsSnapshot(Settings s, {AntennaProfile? antenna})
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/diagnostics.dart';

final _isoLine = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ');

void main() {
  test('keeps the last 1,000 lines by default, oldest dropped first', () {
    final d = Diagnostics(clock: () => DateTime.utc(2026, 10, 17, 14, 2, 11));
    for (var i = 0; i < 1005; i++) {
      d.add('event $i');
    }
    expect(d.lines, hasLength(1000));
    expect(d.lines.first, endsWith(' event 5'));
    expect(d.lines.last, endsWith(' event 1004'));
  });

  test('each line starts with a UTC ISO timestamp, also when the clock is local time', () {
    final utc = DateTime.utc(2026, 10, 17, 14, 2, 11);
    final d = Diagnostics(clock: () => utc.toLocal());
    d.add('Drive started');
    final line = d.lines.single;
    expect(_isoLine.hasMatch(line), isTrue, reason: line);
    expect(line, startsWith('2026-10-17T14:02:11'));
    expect(line, endsWith(' Drive started'));
  });

  test('clear empties it; lines is a snapshot, not a live view', () {
    final d = Diagnostics(capacity: 3);
    d.add('a');
    final snap = d.lines;
    d.add('b');
    expect(snap, hasLength(1));
    d.clear();
    expect(d.lines, isEmpty);
  });

  test('settings snapshot: host, key status, channel, interval, distance, upload settings, antenna — never key or path', () {
    const key = 'ms_Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Q7k';
    const s = Settings(
      serverUrl: 'https://cmat.example.org/private/path?token=1',
      driverKey: key,
      keyStatus: DriverKeyStatus.approved,
      channel: '#testing',
      intervalSec: 45,
      minDistanceM: 150,
      autoSync: true,
      syncDuringDrive: false,
      syncEveryMin: 7,
    );
    final antenna = AntennaProfile(
        mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.utc(2026, 10, 17));
    final text = settingsSnapshot(s, antenna: antenna).join('\n');
    expect(text, contains('cmat.example.org'));
    expect(text, contains('approved'));
    expect(text, contains('#testing'));
    expect(text, contains('45'));
    expect(text, contains('150'));
    expect(text, contains('5.8'));
    expect(text, contains('1.8'));
    expect(text, isNot(contains(key)));
    expect(text, isNot(contains('ms_')));
    expect(text, isNot(contains('/private')));
    expect(text, isNot(contains('token=1')));
    expect(text, isNot(contains('https://cmat.example.org/')));
  });
}
