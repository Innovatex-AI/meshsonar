// The Dart twin of the website's packet-analytics maths. GOLDEN values are the ones pinned in meshcore-insights
// src/lib/region/packet-analytics.test.ts; change one side, change both.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/airtime_share.dart';
import 'package:meshsonar/core/region_packet_analytics_api.dart';

const rows = [
  MixRow(5, false, 0, 1, 30),
  MixRow(5, false, 3, 2, 20),
  MixRow(4, false, 2, 1, 40),
  MixRow(0, true, 1, 3, 10),
  MixRow(3, false, 5, 1, 7),
];

void main() {
  test('GOLDEN: frame bytes', () {
    int f(int t, int h, int ps, bool tr) => frameBytes(t, h, ps, tr, defaultPayloadAssumptions);
    expect([f(5, 0, 1, false), f(5, 3, 2, false), f(4, 2, 1, false), f(0, 1, 3, true), f(3, 5, 1, false)], [37, 43, 125, 29, 11]);
  });

  test('GOLDEN: US preset seconds and shares', () {
    final m = modelAirtime(rows, LoraRadio.meshcoreUs);
    expect(m.transmissions, 107);
    expect(m.airtimeS, 32.409);
    expect([for (final b in m.byType) (b.type, b.transmissions, b.airtimeS, b.txShare, b.airtimeShare)], [
      (4, 40, 18.78, 0.3738, 0.5795),
      (5, 50, 10.88, 0.4673, 0.3357),
      (0, 10, 1.828, 0.0935, 0.0564),
      (3, 7, 0.921, 0.0654, 0.0284),
    ]);
    expect([m.groupTextTxShare, m.groupTextAirtimeShare, m.groupTextAirtimeS], [0.4673, 0.3357, 10.88]);
  });

  test('GOLDEN: SF10 / 250 kHz moves airtime shares, not count shares', () {
    final m = modelAirtime(rows, const LoraRadio(10, 250, 5));
    expect([m.airtimeS, m.groupTextAirtimeShare, m.groupTextTxShare], [43.941, 0.3274, 0.4673]);
  });

  test('an empty mix gives nulls and zero, ignoring non-positive rows', () {
    final m = modelAirtime(const [MixRow(5, false, 0, 1, 0)], LoraRadio.meshcoreUs);
    expect([m.groupTextTxShare, m.groupTextAirtimeShare, m.transmissions], [null, null, 0]);
  });

  test('parsers: hop bins fill 0..16, unknown fields tolerated, nothing invented', () {
    final h = HopRoute.parse({
      'status': {'state': 'ready'},
      'windowHours': 6,
      'observations': 12,
      'packets': 9,
      'observers': 2,
      'newest': '2026-11-01T12:00:00Z',
      'all': [
        {'hops': 0, 'flood': 4, 'direct': 1, 'other': 0},
        {'hops': 3, 'flood': 6, 'direct': 0, 'other': 0},
        {'hops': 99, 'flood': 5}
      ],
      'group': [],
    });
    expect(h.all.length, 17);
    expect(HopRoute.totalOf(h.all), 11); // the out-of-range bin is dropped
    expect(HopRoute.peakOf(h.all)!.hops, 3);
    expect(HopRoute.meanOf(h.all), closeTo((0 * 5 + 3 * 6) / 11, 1e-9));
    expect(HopRoute.meanOf(h.group), isNull);
    expect(h.sample.windowHours, 6);
    expect(h.sample.newest, DateTime.utc(2026, 11, 1, 12));
    final empty = HopRoute.parse({});
    expect(empty.sample.observations, isNull);
    expect(empty.status.state.name, 'unavailable');
  });

  test('silent repeater search matches name, key start and code, case-insensitively', () {
    const r = SilentRepeater(key: 'abcd1234', hashPrefix: 'ab12', hintCode: 'x', hintText: '', checks: [], name: 'North Hill');
    expect([r.matches('north'), r.matches('AB1'), r.matches('cd'), r.matches('')], [true, true, false, true]);
  });
}
