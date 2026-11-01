import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/dead_area.dart';
import 'package:meshsonar/core/model.dart';

DrivePing tx(int i, {bool heard = false}) => DrivePing(
    id: 'p$i',
    ts: DateTime.utc(2026, 11, 1, 0, i),
    lat: 40,
    lon: -83,
    echoes: heard ? [Echo(repeater: '11', hops: 1)] : const []);

DrivePing rx(int i) =>
    DrivePing(id: 'r$i', ts: DateTime.utc(2026, 11, 1, 1, i), lat: 40, lon: -83, kind: PingKind.rx, echoes: [Echo(repeater: '22', hops: 1)]);

void main() {
  test('counts the silent tx pings at the end of the drive', () {
    expect(silentPingStreak(const []), 0);
    expect(silentPingStreak([for (var i = 0; i < 4; i++) tx(i)]), 4);
    expect(silentPingStreak([for (var i = 0; i < 5; i++) tx(i)]), deadAreaPings);
    expect(deadAreaPings, 5);
  });

  test('a heard ping clears the run; earlier silence does not count', () {
    final pings = [for (var i = 0; i < 6; i++) tx(i), tx(6, heard: true)];
    expect(silentPingStreak(pings), 0);
    expect(silentPingStreak([...pings, tx(7), tx(8)]), 2);
  });

  test('passive rx pings neither extend nor break the run', () {
    expect(silentPingStreak([tx(0), tx(1), rx(0), tx(2)]), 3);
    expect(silentPingStreak([tx(0, heard: true), tx(1), rx(0)]), 1);
  });
}
