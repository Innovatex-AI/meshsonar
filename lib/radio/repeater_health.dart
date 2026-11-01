// Health check for a repeater: reads what the admin session already has (status, telemetry, clock, settings, neighbours,
// observer uplink) and says in plain words what looks wrong, how bad it is, and what to do. NEVER changes anything: every
// fix is a suggestion the person applies on the settings screens. Thresholds are defaults picked here and recorded in
// HANDOFF (research packet D12 asks for them to be confirmed). Pure Dart.
import '../core/api.dart' show RadioPreset;
import 'repeater_settings.dart';
import 'repeater_wire.dart';

enum Severity {
  ok,
  info,
  warn,
  fail;

  bool operator >(Severity o) => index > o.index;
}

class HealthFinding {
  /// Stable id, for tests and for linking to a settings group.
  final String id;
  final Severity severity;
  final String title;

  /// What was seen, in a sentence.
  final String detail;

  /// What to do about it; null when there is nothing to do. Never applied automatically.
  final String? fix;

  /// The settings key a screen can jump to, if any.
  final String? settingKey;
  const HealthFinding(this.id, this.severity, this.title, this.detail, {this.fix, this.settingKey});
}

// ------------------------------------------------------------------ observer uplink

class ObserverSlot {
  final int number;
  final String name;

  /// The state in brackets, e.g. `ok`.
  final String state;
  const ObserverSlot(this.number, this.name, this.state);
  bool get ok => state == 'ok';
}

class ObserverStatus {
  final List<ObserverSlot> slots;
  final int queueLen;
  final int queueMax;
  final int drops;
  final int failed;
  final bool? ntpOk;
  final int disconnects;

  const ObserverStatus(this.slots, {this.queueLen = 0, this.queueMax = 50, this.drops = 0, this.failed = 0, this.ntpOk, this.disconnects = 0});

  /// Builds from the raw replies of [RepeaterAdminSession.readObserverRaw]. Measured formats:
  /// `msgs: on, 1: analyzer-us (ok), 2: meshmapper (ok), 5: custom (ok), q:1`,
  /// `Free=134020 Max=120820 q:1/50 Outbox=0 drops=0/0 | s1=963/0 ...`, `mqtt1: ok, dc:76, first_disc:148510s, no errors`.
  static ObserverStatus parse(Map<String, String> raw) {
    final slots = <ObserverSlot>[];
    final st = raw['get mqtt.status'] ?? '';
    for (final m in RegExp(r'(\d):\s*([^,()]+?)\s*\(([^)]*)\)').allMatches(st)) {
      slots.add(ObserverSlot(int.parse(m[1]!), m[2]!.trim(), m[3]!.trim()));
    }
    final stats = raw['get mqtt.stats'] ?? '';
    final q = RegExp(r'q:(\d+)/(\d+)').firstMatch(stats);
    final d = RegExp(r'drops=(\d+)/(\d+)').firstMatch(stats);
    var dc = 0;
    for (var i = 1; i <= 6; i++) {
      final m = RegExp(r'dc:(\d+)').firstMatch(raw['get mqtt$i.diag'] ?? '');
      if (m != null) dc += int.parse(m[1]!);
    }
    final ntp = raw['get mqtt.ntp.diag'];
    bool? ntpOk;
    if (ntp != null && ntp.trim().isNotEmpty) {
      final lines = ntp.split('\n').where((l) => l.trim().isNotEmpty);
      ntpOk = lines.any((l) => l.trim().endsWith(' ok'));
    }
    return ObserverStatus(slots,
        queueLen: q == null ? 0 : int.parse(q[1]!),
        queueMax: q == null ? 50 : int.parse(q[2]!),
        drops: d == null ? 0 : int.parse(d[1]!),
        failed: d == null ? 0 : int.parse(d[2]!),
        ntpOk: ntpOk,
        disconnects: dc);
  }
}

// ------------------------------------------------------------------ the check

/// Everything the check may look at; any part can be missing and its check is then skipped, never guessed.
class HealthInput {
  final RepeaterStats? stats;
  final RepeaterTelemetry? telemetry;
  final int? clockSkewSecs;
  final Map<String, String> settings;
  final RadioPreset? regionPreset;
  final int? neighbourCount;
  final ObserverStatus? observer;
  final bool isObserverBuild;
  final BoardLimits boardLimits;

  /// Uptime of the previous check of this repeater, to see a restart in between.
  final int? previousUptimeSecs;
  const HealthInput({
    this.stats,
    this.telemetry,
    this.clockSkewSecs,
    this.settings = const {},
    this.regionPreset,
    this.neighbourCount,
    this.observer,
    this.isObserverBuild = false,
    this.boardLimits = const BoardLimits(22),
    this.previousUptimeSecs,
  });
}

List<HealthFinding> evaluateHealth(HealthInput i) {
  final out = <HealthFinding>[];
  final s = i.settings;

  // ---- clock
  final skew = i.clockSkewSecs;
  if (skew != null) {
    final a = skew.abs();
    if (a > 600) {
      out.add(HealthFinding('clock', Severity.fail, 'Clock is wrong',
          'The repeater\'s clock is ${_dur(a)} ${skew > 0 ? 'ahead of' : 'behind'} your phone. Observers and the server reject adverts and reports with a clock that far off.',
          fix: skew < 0
              ? 'Tap "Sync clock". It sets the clock forward to your radio\'s time.'
              : 'A repeater never sets its clock backwards. It needs its clock reset on site, then "Sync clock".'));
    } else if (a > 60) {
      out.add(HealthFinding('clock', Severity.warn, 'Clock is off', 'The repeater\'s clock is ${_dur(a)} ${skew > 0 ? 'ahead of' : 'behind'} your phone.',
          fix: skew < 0 ? 'Tap "Sync clock".' : 'It cannot be set back from here; it is small enough to leave.'));
    } else {
      out.add(HealthFinding('clock', Severity.ok, 'Clock is right', 'Within ${a <= 2 ? 'a couple of seconds' : '$a seconds'} of your phone.'));
    }
  }

  // ---- radio vs region preset
  final radio = s['radio'] == null ? null : parseRadioParams(s['radio']!);
  final p = i.regionPreset;
  if (radio != null && p != null) {
    final diffs = <String>[];
    var freqOff = false;
    if ((radio.freqMhz - p.freqMhz).abs() > 0.0011) {
      diffs.add('frequency ${_f(radio.freqMhz)} MHz (region ${_f(p.freqMhz)})');
      freqOff = true;
    }
    if ((radio.bwKhz - p.bwKhz).abs() > 0.051) diffs.add('bandwidth ${_f(radio.bwKhz)} kHz (region ${_f(p.bwKhz)})');
    if (radio.sf != p.sf) diffs.add('SF${radio.sf} (region SF${p.sf})');
    if (radio.cr != p.cr) diffs.add('CR${radio.cr} (region CR${p.cr})');
    if (diffs.isEmpty) {
      out.add(HealthFinding('radio-preset', Severity.ok, 'Radio matches the region', '${p.name}: $radio.'));
    } else {
      out.add(HealthFinding('radio-preset', freqOff ? Severity.fail : Severity.warn, 'Radio differs from the region preset',
          'This repeater uses ${diffs.join(', ')}. Radios on the region preset will not hear it properly.',
          fix: 'If this is a mistake, set the radio parameters to the region preset in Settings > Radio. If this repeater is meant to be on its own settings, leave it.',
          settingKey: 'radio'));
    }
  }

  // ---- tx power
  final tx = int.tryParse(s['tx'] ?? '');
  if (tx != null) {
    if (tx > i.boardLimits.maxTxDbm) {
      out.add(HealthFinding('tx', Severity.fail, 'Transmit power is above this board\'s limit',
          'TX is $tx dBm; this board is documented up to ${i.boardLimits.maxTxDbm} dBm.',
          fix: 'Lower it in Settings > Radio, and check your local rules.', settingKey: 'tx'));
    } else if (tx > 22) {
      out.add(HealthFinding('tx', Severity.info, 'High transmit power', 'TX is $tx dBm. Fine for a board with a power amplifier, but check your local limit and antenna.',
          settingKey: 'tx'));
    } else if (tx < 5) {
      out.add(HealthFinding('tx', Severity.warn, 'Very low transmit power', 'TX is $tx dBm, so few radios will hear this repeater.',
          fix: 'Raise it in Settings > Radio if that is not on purpose.', settingKey: 'tx'));
    } else {
      out.add(HealthFinding('tx', Severity.ok, 'Transmit power is sensible', '$tx dBm.'));
    }
  }

  // ---- adverts
  final flood = int.tryParse(s['flood.advert.interval'] ?? '');
  if (flood != null) {
    if (flood == 0) {
      out.add(HealthFinding('advert', Severity.warn, 'Never announces itself',
          'The flood advert interval is off, so the mesh only learns this repeater exists when someone sends an advert by hand.',
          fix: 'Set it to 12 or 24 hours in Settings > Identity.', settingKey: 'flood.advert.interval'));
    } else if (flood < 6) {
      out.add(HealthFinding('advert', Severity.info, 'Frequent adverts', 'A flood advert every $flood hours uses airtime on every repeater that passes it on.',
          fix: 'Most repeaters use 12 to 24 hours.', settingKey: 'flood.advert.interval'));
    } else {
      out.add(HealthFinding('advert', Severity.ok, 'Advert interval is sensible', 'A flood advert every $flood hours.'));
    }
  }

  // ---- repeating and flood limit
  if (s['repeat'] == 'off') {
    out.add(const HealthFinding('repeat', Severity.warn, 'This node is not repeating', 'Repeat is off, so it does not forward other radios\' packets.',
        fix: 'Turn it on in Settings > Routing unless this is a room server or an observer on purpose.', settingKey: 'repeat'));
  }
  final fm = int.tryParse(s['flood.max'] ?? '');
  if (fm != null && fm < 3) {
    out.add(HealthFinding('flood-max', Severity.warn, 'Flood hop limit is very low',
        'It only passes on floods that have travelled fewer than $fm hops, so almost nothing from farther away.',
        fix: 'The usual value is 64. Change it in Settings > Routing.', settingKey: 'flood.max'));
  }

  // ---- neighbours
  final nb = i.neighbourCount;
  if (nb != null) {
    if (nb == 0) {
      out.add(const HealthFinding('neighbours', Severity.warn, 'Hears no neighbours',
          'Its neighbour list is empty. Either it is alone, its radio settings or antenna are wrong, or it was restarted a moment ago.',
          fix: 'Check the antenna and the radio settings, then use "Look for neighbours" and read the list again in a minute.'));
    } else if (nb == 1) {
      out.add(const HealthFinding('neighbours', Severity.info, 'One neighbour', 'It hears one other repeater, so one failure cuts it off.'));
    } else {
      out.add(HealthFinding('neighbours', Severity.ok, 'Hears $nb neighbours', 'Its neighbour list has $nb entries.'));
    }
  }

  // ---- battery
  final st = i.stats;
  final volts = i.telemetry?.voltageV ?? st?.batteryV;
  if (volts != null && volts > 0) {
    if (volts < 3.4) {
      out.add(HealthFinding('battery', Severity.fail, 'Battery is nearly flat', '${volts.toStringAsFixed(2)} V. It may shut down any time.',
          fix: 'Check the solar panel or power supply.'));
    } else if (volts < 3.6) {
      out.add(HealthFinding('battery', Severity.warn, 'Battery is low', '${volts.toStringAsFixed(2)} V.', fix: 'Check the solar panel or power supply.'));
    } else {
      out.add(HealthFinding('battery', Severity.ok, 'Battery is fine', '${volts.toStringAsFixed(2)} V.'));
    }
  }

  // ---- uptime, noise, errors
  if (st != null) {
    final prev = i.previousUptimeSecs;
    if (prev != null && st.upTimeSecs < prev) {
      out.add(HealthFinding('restart', Severity.warn, 'It restarted since the last check',
          'Uptime is ${_dur(st.upTimeSecs)}, shorter than at the last check. A power loss or crash is likely.',
          fix: 'If this keeps happening, check the power supply and battery.'));
    } else if (st.upTimeSecs < 600) {
      out.add(HealthFinding('restart', Severity.info, 'Just restarted', 'Uptime is ${_dur(st.upTimeSecs)}. Neighbour lists fill again over a few minutes.'));
    }
    if (st.noiseFloorDbm > -80) {
      out.add(HealthFinding('noise', Severity.fail, 'Very high noise floor', '${st.noiseFloorDbm} dBm. Something nearby is jamming the band.',
          fix: 'Move the antenna away from electronics, or check for interference sources.'));
    } else if (st.noiseFloorDbm > -95) {
      out.add(HealthFinding('noise', Severity.warn, 'High noise floor', '${st.noiseFloorDbm} dBm (a quiet site is about -110 to -100).',
          fix: 'Check for interference near the antenna.'));
    }
    // INNO-OB-2 measured 193 errors in 1165 packets (17%) and works fine: noise makes CRC failures routine, so only warn above 40%.
    if (st.packetsRecv > 100 && st.recvErrors * 5 > st.packetsRecv * 2) {
      out.add(HealthFinding('rx-errors', Severity.warn, 'Many receive errors', '${st.recvErrors} of ${st.packetsRecv} received packets had errors.',
          fix: 'This usually means interference or a damaged antenna connector.'));
    }
  }

  // ---- observer uplink
  final ob = i.observer;
  if (i.isObserverBuild && ob != null) {
    if (ob.slots.isEmpty) {
      out.add(const HealthFinding('uplink', Severity.warn, 'No uplink slot reported', 'The observer did not list any MQTT slot.',
          fix: 'Check the observer\'s own status page or its WiFi.'));
    } else {
      final bad = ob.slots.where((x) => !x.ok).toList();
      if (bad.isNotEmpty) {
        out.add(HealthFinding('uplink', Severity.fail, 'An uplink is not connected', bad.map((x) => 'slot ${x.number} ${x.name}: ${x.state}').join('; '),
            fix: 'Check the observer\'s WiFi, then the broker settings of that slot.'));
      } else {
        out.add(HealthFinding('uplink', Severity.ok, 'Uplinks are connected', '${ob.slots.length} slot(s): ${ob.slots.map((x) => x.name).join(', ')}.'));
      }
      if (ob.drops > 0 || ob.failed > 0) {
        out.add(HealthFinding('uplink-drops', Severity.warn, 'Some packets were not sent', '${ob.drops} dropped, ${ob.failed} failed to publish since it started.',
            fix: 'Occasional drops after a WiFi blip are normal. If the count keeps growing, check the connection.'));
      }
      if (ob.queueLen > 30) {
        out.add(HealthFinding('uplink-queue', Severity.warn, 'Uplink queue is backing up', '${ob.queueLen} of ${ob.queueMax} packets are waiting.',
            fix: 'The broker or WiFi is slow. Check them.'));
      }
    }
    if (ob.ntpOk == false) {
      out.add(const HealthFinding('uplink-ntp', Severity.warn, 'Its network time check failed',
          'No time server answered. Brokers can reject packets with a wrong time.', fix: 'Check the observer\'s WiFi and internet.'));
    }
  }

  out.sort((a, b) => b.severity.index.compareTo(a.severity.index));
  return out;
}

/// The worst severity in [findings] (ok when empty).
Severity worst(List<HealthFinding> f) => f.fold(Severity.ok, (w, x) => x.severity > w ? x.severity : w);

String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(1) : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

String _dur(int secs) {
  if (secs < 120) return '${secs}s';
  if (secs < 7200) return '${secs ~/ 60} min';
  if (secs < 172800) return '${secs ~/ 3600} h';
  return '${secs ~/ 86400} days';
}
