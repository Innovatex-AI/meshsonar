// The tile matrix of the contact profile (chat plan 4.6): contact type x radio connected x firmware x chatRedesign flag.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/ui/contacts/profile_tiles.dart';
import 'package:meshsonar/ui/contacts/profile_widgets.dart';

import '../../chat/contact_support.dart';

const _noDiscovery = RadioCaps(fwCode: 8, pathDiscovery: PathDiscoverySupport.no);
const _modern = RadioCaps(fwCode: 10, pathDiscovery: PathDiscoverySupport.yes);

List<ProfileTile> tiles(ContactType t,
        {bool connected = true, RadioCaps caps = _modern, bool msg = true, bool admin = true, bool redesign = true}) =>
    profileTiles(radioContact(1, type: t), connected: connected, caps: caps, canMessage: msg, canAdmin: admin, redesign: redesign);

List<ProfileTileId> ids(List<ProfileTile> l) => [for (final t in l) t.id];

void main() {
  group('order and count per type (flag on)', () {
    test('person: Message, Ping, Route, Stats', () {
      expect(ids(tiles(ContactType.companion)), [ProfileTileId.message, ProfileTileId.ping, ProfileTileId.route, ProfileTileId.stats]);
    });
    test('repeater: Dashboard, Ping, Route', () {
      expect(ids(tiles(ContactType.repeater)), [ProfileTileId.dashboard, ProfileTileId.ping, ProfileTileId.route]);
    });
    test('room: Open room, Ping, Route', () {
      expect(ids(tiles(ContactType.room)), [ProfileTileId.openRoom, ProfileTileId.ping, ProfileTileId.route]);
    });
    test('sensor: Telemetry, Ping, Route', () {
      expect(ids(tiles(ContactType.sensor)), [ProfileTileId.telemetry, ProfileTileId.ping, ProfileTileId.route]);
    });
  });

  group('flag off: only tiles that work today, never a dead button', () {
    test('person: Message and Route', () => expect(ids(tiles(ContactType.companion, redesign: false)), [ProfileTileId.message, ProfileTileId.route]));
    test('repeater: Dashboard and Route', () => expect(ids(tiles(ContactType.repeater, redesign: false)), [ProfileTileId.dashboard, ProfileTileId.route]));
    test('room: Open room and Route', () => expect(ids(tiles(ContactType.room, redesign: false)), [ProfileTileId.openRoom, ProfileTileId.route]));
    test('sensor: Route only', () => expect(ids(tiles(ContactType.sensor, redesign: false)), [ProfileTileId.route]));
    test('nothing flagged "coming soon" is shown', () {
      for (final t in ContactType.values) {
        expect(tiles(t, redesign: false).where((x) => x.comingSoon), isEmpty, reason: t.name);
      }
    });
  });

  group('host wiring', () {
    test('no conversation hook: no Message / Open room tile', () {
      expect(ids(tiles(ContactType.companion, msg: false)), isNot(contains(ProfileTileId.message)));
      expect(ids(tiles(ContactType.room, msg: false)), isNot(contains(ProfileTileId.openRoom)));
    });
    test('no admin hook: no Dashboard tile', () => expect(ids(tiles(ContactType.repeater, admin: false)), [ProfileTileId.ping, ProfileTileId.route]));
  });

  group('connected x firmware', () {
    test('connected, modern: everything enabled', () {
      for (final t in ContactType.values) {
        expect(tiles(t).every((x) => x.enabled), isTrue, reason: t.name);
      }
    });
    test('disconnected: radio tiles dim with a reason; Message and Route stay usable', () {
      final p = tiles(ContactType.companion, connected: false);
      expect(p.firstWhere((t) => t.id == ProfileTileId.message).enabled, isTrue);
      expect(p.firstWhere((t) => t.id == ProfileTileId.route).enabled, isTrue);
      for (final id in [ProfileTileId.ping, ProfileTileId.stats]) {
        final t = p.firstWhere((x) => x.id == id);
        expect(t.enabled, isFalse);
        expect(t.reason, contains('Connect your radio'));
      }
      expect(tiles(ContactType.repeater, connected: false).first.reason, contains('log in'));
      expect(tiles(ContactType.sensor, connected: false).first.enabled, isFalse);
    });
    test('firmware without path discovery: Ping on a person is dimmed with the firmware reason, other types are not', () {
      final person = tiles(ContactType.companion, caps: _noDiscovery).firstWhere((t) => t.id == ProfileTileId.ping);
      expect(person.enabled, isFalse);
      expect(person.reason, contains('firmware'));
      for (final t in [ContactType.repeater, ContactType.room, ContactType.sensor]) {
        expect(tiles(t, caps: _noDiscovery).firstWhere((x) => x.id == ProfileTileId.ping).enabled, isTrue, reason: t.name);
      }
    });
    test('baseline caps (unknown radio) still allow Ping: the radio decides', () {
      expect(tiles(ContactType.companion, caps: RadioCaps.baseline).firstWhere((t) => t.id == ProfileTileId.ping).enabled, isTrue);
    });
  });

  group('grid columns', () {
    test('four tiles fit 375 pt (343 usable) in one row', () => expect(ProfileTileGrid.columnsFor(343, 4, 1.0), 4));
    test('four tiles on iPad width stay one row', () => expect(ProfileTileGrid.columnsFor(600, 4, 1.0), 4));
    test('three tiles, one row', () => expect(ProfileTileGrid.columnsFor(361, 3, 1.0), 3));
    test('at 1.5x text and above they wrap into two columns', () {
      expect(ProfileTileGrid.columnsFor(361, 4, 1.5), 2);
      expect(ProfileTileGrid.columnsFor(361, 4, 2.35), 2);
      expect(ProfileTileGrid.columnsFor(361, 1, 2.35), 1);
    });
    test('never narrower than 72 pt', () {
      expect(ProfileTileGrid.columnsFor(250, 4, 1.0), 3); // (250-16)/3 = 78
      expect(ProfileTileGrid.columnsFor(150, 4, 1.0), 1);
    });
  });

  test('middleEllipsis keeps both ends of a key', () {
    final k = keyN(0xa1);
    expect(middleEllipsis(k), 'a1a1a1a1…a1a1a1a1');
    expect(middleEllipsis('abc'), 'abc');
  });
}
