// MeshTrack copy (plan sections 5-8): chip labels, the sharing status line, friend rows in metric and imperial, the
// position-mode sizes, and the vocabulary rule (no APRS / beacon / hops / flood / hash / slot / precision anywhere in the
// MeshTrack screens).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/meshtrack_service.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_copy.dart';

MtGroupView g(String name, {bool share = false, int heard = 0}) =>
    MtGroupView(config: MtGroupConfig(channelId: name.length, name: name, share: share), friends: const [], heardLast30Min: heard, sharingNow: share);

MeshTrackState st(MtShareReason r, List<String> names, {MtRate rate = MtRate.smart}) => MeshTrackState(
      reason: r,
      sharingNames: names,
      rate: rate,
      groups: [for (final n in names) g(n, share: true)],
    );

MtFriend friend({int? speed, int? path = 0, double? snr = 6.5, bool parked = false, bool stopped = false, bool jumped = false, MtSource source = MtSource.meshTrack, MtStaleness s = MtStaleness.fresh}) =>
    MtFriend(
      name: 'Sam',
      lat: 40.1262 + 0.0275,
      lon: -82.9291 + 0.0357,
      accuracyM: 2,
      lastHeard: DateTime.utc(2026, 11, 16, 12, 0),
      staleness: s,
      speedKmh: speed,
      pathLen: path,
      snr: snr,
      parked: parked,
      stopped: stopped,
      jumped: jumped,
      source: source,
    );

void main() {
  test('chip: MeshTrack when off, Sharing: names with truncation, and the paused states', () {
    expect(mtChip(const MeshTrackState()).label, 'MeshTrack');
    expect(mtChip(const MeshTrackState()).tone, MtChipTone.idle);
    expect(mtChip(st(MtShareReason.sharing, ['Family', 'Club'])).label, 'Sharing: Family, Club');
    expect(mtChip(st(MtShareReason.sharing, ['Family', 'Club'])).tone, MtChipTone.sharing);
    expect(mtChip(st(MtShareReason.sharing, ['Family', 'Saturday drive club'])).label, 'Sharing: Family +1');
    expect(mtChip(st(MtShareReason.sharing, ['Family', 'Club', 'Hamfest'])).label, 'Sharing: Family +2');
    expect(mtChip(st(MtShareReason.airtimeLimit, ['Family'])).label, 'Sharing: Family');
    expect(mtChip(st(MtShareReason.privacyZone, ['Family'])).label, 'Sharing paused: privacy zone');
    expect(mtChip(st(MtShareReason.privacyZone, ['Family'])).tone, MtChipTone.paused);
    expect(mtChip(st(MtShareReason.waitingForGps, ['Family'])).label, 'Waiting for GPS');
    expect(mtChip(st(MtShareReason.radioDisconnected, ['Family'])).label, 'Sharing paused: no radio');
    expect(mtChip(st(MtShareReason.waitingForDrive, ['Family'])).label, 'Sharing starts with your drive');
    expect(mtChipSemantics(st(MtShareReason.sharing, ['Family', 'Saturday drive club'])), 'Sharing: Family +1. Groups: Family, Saturday drive club. Opens your groups');
  });

  test('status line: one group, two groups (the plan sentence), low traffic, airtime limit', () {
    expect(mtStatusLine(const MeshTrackState()), isNull);
    expect(mtStatusLine(st(MtShareReason.sharing, ['Family'])), 'Sharing with Family: updates about every minute at highway speed.');
    expect(mtStatusLine(st(MtShareReason.sharing, ['Family', 'Club'])), 'Sharing with 2 groups: updates about every 2 min at highway speed.');
    expect(mtStatusLine(st(MtShareReason.sharing, ['Family', 'Club'], rate: MtRate.lowTraffic)), 'Sharing with 2 groups: updates about every 4 min at highway speed.');
    expect(mtStatusLine(st(MtShareReason.airtimeLimit, ['Family'])), 'Sharing slower: airtime limit');
  });

  test('friend rows: last heard, distance and compass point, route and SNR, speed: metric and imperial', () {
    final now = DateTime.utc(2026, 11, 16, 12, 2);
    const me = (lat: 40.1262, lon: -82.9291);
    final m = mtFriendLines(friend(speed: 54), me: me, units: Units.metric, now: now);
    expect(m.line1, '2 min ago · 4.3 km NE');
    expect(m.line2, 'direct · SNR 6.5 dB · 54 km/h');
    final i = mtFriendLines(friend(speed: 54, path: 2), me: me, units: Units.imperial, now: now);
    expect(i.line1, '2 min ago · 2.7 mi NE');
    expect(i.line2, 'via 2 repeaters · SNR 6.5 dB · 34 mph');
    expect(mtFriendLines(friend(path: 1, snr: null), me: me, units: Units.metric, now: now).line2, 'via 1 repeater');
    expect(mtFriendLines(friend(), me: null, units: Units.metric, now: now).line1, '2 min ago');
    expect(mtFriendLines(friend(speed: 3), me: me, units: Units.metric, now: now).line2, 'direct · SNR 6.5 dB', reason: 'no speed below 5 km/h');
    expect(mtFriendLines(friend(parked: true, speed: 0), me: me, units: Units.metric, now: now).line2, contains('Parked'));
    expect(mtFriendLines(friend(stopped: true), me: me, units: Units.metric, now: now).line2, contains('Stopped sharing'));
    expect(mtFriendLines(friend(jumped: true), me: me, units: Units.metric, now: now).line2, contains('Position jumped'));
    expect(mtFriendLines(friend(source: MtSource.typed), me: me, units: Units.metric, now: now).line2, contains('Typed position'));
    expect(mtFriendLines(friend(s: MtStaleness.listOnly), me: me, units: Units.metric, now: now).line2, contains('Not on the map'));
    expect(m.semantics, 'Sam, last heard 2 min ago, 4.3 km NE, direct · SNR 6.5 dB · 54 km/h');
    expect(mtAgo(now, now), 'just now');
    expect(mtAgo(now.subtract(const Duration(hours: 3)), now), '3 h ago');
  });

  test('mtKeepTogether: no break inside a part ("25 mph", "0.7 mi W"), only between parts', () {
    expect(mtKeepTogether('just now · 0.7 mi W'), 'just\u00A0now · 0.7\u00A0mi\u00A0W');
    expect(mtKeepTogether('via 1 repeater · 25 mph'), 'via\u00A01\u00A0repeater · 25\u00A0mph');
    expect(mtKeepTogether('just now'), 'just\u00A0now');
  });

  test('position friends see: Exact about 3 m / Approximate about 280 m, imperial through Units', () {
    expect(mtPositionModeLabel(MtPositionMode.exact, Units.metric), 'Exact (about 3 m)');
    expect(mtPositionModeLabel(MtPositionMode.approximate, Units.metric), 'Approximate (about 280 m)');
    expect(mtPositionModeLabel(MtPositionMode.exact, Units.imperial), 'Exact (about 10 ft)');
    expect(mtPositionModeLabel(MtPositionMode.approximate, Units.imperial), 'Approximate (about 0.2 mi)');
  });

  test('default group name: "<name>\'s crew", kept to the 31-byte channel limit', () {
    expect(mtDefaultGroupName('Andy'), "Andy's crew");
    expect(mtDefaultGroupName(null), 'My crew');
    expect(mtDefaultGroupName('  '), 'My crew');
    final long = mtDefaultGroupName('KE4BFI Mobile Unit Number Seven');
    expect(long.endsWith("'s crew"), isTrue);
    expect(long.length, lessThanOrEqualTo(31));
  });

  test('the joined banner, the asked toast and the stop toast say exactly the plan words', () {
    expect(mtJoinedBanner('Saturday crew'), 'Joined Saturday crew. They show on your map when they share.');
    expect(mtAskedToast('Sam'), 'Sam asked where you are');
    expect(mtStoppedSharingWith('Club'), 'Stopped sharing with Club');
    expect(mtUpToThree, 'Up to 3 groups');
    expect(mtNotOnRadio, 'Not on this radio: it has no room for another channel');
    expect(mtRadioDisconnectedStop, 'Stopped sharing: radio disconnected');
    expect(mtAirtimeSlower, 'Sharing slower: airtime limit');
  });

  test('vocabulary: no MeshTrack screen string says APRS, beacon, hops, flood, hash, slot or precision', () {
    final banned = RegExp(r'\b(aprs|beacons?|hops?|flood(s|ed|ing)?|hash(es)?|slots?|precision)\b', caseSensitive: false);
    final literal = RegExp(r"'((?:[^'\\\n]|\\.)*)'|" r'"((?:[^"\\\n]|\\.)*)"');
    final files = [
      ...Directory('lib/ui/meshtrack').listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
      File('lib/ui/settings/meshtrack_section.dart'),
    ];
    final hits = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trimLeft();
        if (t.startsWith('//') || t.startsWith('import ') || t.startsWith('export ') || lines[i].contains('Key(')) continue;
        for (final m in literal.allMatches(lines[i])) {
          final s = m.group(1) ?? m.group(2) ?? '';
          if (!s.contains(' ') && s.toLowerCase() == s) continue; // identifiers, keys
          if (banned.hasMatch(s)) hits.add('${f.path}:${i + 1}: $s');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
