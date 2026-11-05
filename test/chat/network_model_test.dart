// The pure parts of the Network segment: grouping and order, the battery chip states and the 60 second poll.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/network_model.dart';
import 'package:meshsonar/radio/protocol.dart' show BattAndStorageFrame;

Contact node(int i, ContactType type, {String? name, bool fav = false, int? heard, bool blocked = false}) => Contact(
      radioId: 'r',
      publicKey: '${i.toRadixString(16).padLeft(2, '0')}${'ab' * 31}',
      type: type,
      name: name ?? 'Node $i',
      favourite: fav,
      lastHeardMs: heard,
      blocked: blocked,
    );

void main() {
  group('grouping', () {
    test('splits by type, drops companions and blocked nodes, favourites then most recent then name', () {
      final g = groupNetwork([
        node(1, ContactType.repeater, name: 'Zed', heard: 100),
        node(2, ContactType.repeater, name: 'Amy', heard: 100),
        node(3, ContactType.repeater, name: 'Old fav', fav: true, heard: 1),
        node(4, ContactType.repeater, name: 'Fresh', heard: 900),
        node(5, ContactType.repeater, name: 'Hidden', blocked: true),
        node(6, ContactType.room, name: 'Lounge'),
        node(7, ContactType.sensor, name: 'Garage'),
        node(8, ContactType.companion, name: 'Bob'),
      ]);
      expect([for (final c in g[ContactType.repeater]!) c.name], ['Old fav', 'Fresh', 'Amy', 'Zed']);
      expect([for (final c in g[ContactType.room]!) c.name], ['Lounge']);
      expect([for (final c in g[ContactType.sensor]!) c.name], ['Garage']);
      expect(g.containsKey(ContactType.companion), isFalse);
    });

    test('the query filters by name or key start, case-insensitive', () {
      final all = [node(1, ContactType.repeater, name: 'North Ridge'), node(2, ContactType.repeater, name: 'Hill Top')];
      expect(groupNetwork(all, query: 'ridge')[ContactType.repeater]!.single.name, 'North Ridge');
      expect(groupNetwork(all, query: '02ab')[ContactType.repeater]!.single.name, 'Hill Top');
      expect(groupNetwork(all, query: 'zzz')[ContactType.repeater], isEmpty);
    });
  });

  group('battery chip', () {
    BatteryChipState at(int mv) => BatteryChipState.fromFrame(BattAndStorageFrame(batteryMv: mv));

    test('ok shows an estimated percentage, low at or under 20 percent', () {
      final ok = at(4000);
      expect(ok.kind, BatteryChipKind.ok);
      expect(ok.label, '82%');
      expect(ok.spoken, 'Battery about 82 percent');
      final low = at(3500);
      expect(low.kind, BatteryChipKind.low);
      expect(low.percent, 5);
      expect(low.spoken, startsWith('Battery low'));
      expect(at(4200).label, '100%');
    });

    test('none is hidden, loading and unavailable say so without a number', () {
      expect(BatteryChipState.none.visible, isFalse);
      expect(BatteryChipState.loading.label, '…');
      expect(BatteryChipState.unavailable.label, '–');
      expect(BatteryChipState.unavailable.spoken, contains('not available'));
    });
  });

  group('battery poller', () {
    test('asks at once, then every 60 s, and nothing after stop', () {
      fakeAsync((async) {
        var calls = 0;
        final seen = <BatteryChipState>[];
        final p = BatteryPoller(fetch: () async { calls++; return BattAndStorageFrame(batteryMv: 3900); }, onState: seen.add);
        p.start();
        expect(seen.first, BatteryChipState.loading);
        async.flushMicrotasks();
        expect(calls, 1);
        expect(seen.last.kind, BatteryChipKind.ok);
        async.elapse(const Duration(seconds: 59));
        expect(calls, 1);
        async.elapse(const Duration(seconds: 2));
        expect(calls, 2);
        async.elapse(const Duration(minutes: 3));
        expect(calls, 5);
        p.stop();
        async.elapse(const Duration(minutes: 5));
        expect(calls, 5, reason: 'a stopped poller (background, other segment) asks nothing');
        p.dispose();
      });
    });

    test('a missing reading or an error becomes unavailable; a slow reply is not stacked', () {
      fakeAsync((async) {
        var n = 0;
        final seen = <BatteryChipState>[];
        final p = BatteryPoller(
          interval: const Duration(seconds: 1),
          fetch: () async {
            n++;
            if (n == 1) return null;
            if (n == 2) throw StateError('link down');
            await Future<void>.delayed(const Duration(seconds: 5));
            return BattAndStorageFrame(batteryMv: 3800);
          },
          onState: seen.add,
        );
        p.start();
        async.flushMicrotasks();
        expect(seen.last, BatteryChipState.unavailable);
        async.elapse(const Duration(seconds: 1));
        expect(seen.last, BatteryChipState.unavailable);
        async.elapse(const Duration(seconds: 1)); // third poll starts and takes 5 s
        async.elapse(const Duration(seconds: 3));
        expect(n, 3, reason: 'polls during a pending one are dropped');
        async.elapse(const Duration(seconds: 3));
        expect(seen.last.kind, BatteryChipKind.ok);
        p.dispose();
      });
    });
  });
}
