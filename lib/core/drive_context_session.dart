// One drive's context collection (stream 7 WP2/WP3): starts and stops every collector with the drive and keeps each
// one running only while its category is on. It owns:
//   - the DriveContextRecorder (lib/core/drive_context_recorder.dart), which strips switched-off categories at every
//     write,
//   - the RadioHealthPoller (lib/radio/radio_health.dart) for `radio_health`, never polling while a ping is in flight,
//   - the phone barometer subscription for `barometer` (1 Hz; the readings around each ping give that ping's median),
//   - a phone sample every [phoneEvery] (barometer median of the last interval + battery) and on every charging
//     change, for `barometer` / `phone_battery`,
//   - the session snapshot (phone/app details for `device`, radio identity for `radio_config`).
//
// [refresh] re-reads the switches: a category turned off is stopped at once (its stream subscription cancelled, the
// poller stopped), one turned on starts from that moment. Nothing is collected while [DriveContextRecorder.isOn] says
// no, which is also how "nothing before the disclosure has been seen" is enforced (AppState's isOn checks it).
//
// Everything is local: the recorder writes beside the drive (ctx.jsonl, samples.jsonl, context.json) and nothing here
// talks to a server. Samples carry no coordinates.
//
// Pure Dart: no Flutter imports.
import 'dart:async';

import '../radio/radio_api.dart';
import '../radio/radio_health.dart';
import 'data_categories.dart';
import 'drive_context.dart';
import 'drive_context_recorder.dart';
import 'model.dart';
import 'phone_sensors.dart';

typedef PeriodicTimerFactory = Timer Function(Duration period, void Function(Timer timer) tick);

class DriveContextSession {
  final DriveContextRecorder recorder;

  /// The connected radio's stats commands; null when the link does not offer them (then no radio health).
  final RadioStatsSource? radio;

  /// True while a ping is in flight (noise-floor read, send, listen window): the poller waits.
  final bool Function() pingBusy;
  final BarometerSource? barometer;
  final PhoneBatterySource? battery;
  final Future<DeviceDetails?> Function()? deviceDetails;

  /// The radio's identity beyond Drive Format v1, read when the drive starts.
  final CompanionDetails? Function()? companion;
  final Duration phoneEvery;
  final Duration radioEvery;

  /// Barometer readings this close to a ping's time give that ping's pressure.
  final Duration pingPressureWindow;

  /// Called when [barometerStatus] changes.
  final void Function()? onStatus;
  final DateTime Function() _clock;
  final PeriodicTimerFactory _periodic;
  /// Timer for the radio poller (tests pass a fake clock's).
  final TimerFactory? radioTimer;

  RadioHealthPoller? _poller;
  StreamSubscription<double>? _baroSub;
  StreamSubscription<PhoneBatteryState>? _battSub;
  Timer? _phoneTimer;
  final List<(DateTime, double)> _pressure = [];
  SensorStatus _baroStatus;
  bool _running = false;
  bool _deviceDone = false;
  bool _companionDone = false;
  Future<void> _phoneChain = Future.value();

  DriveContextSession({
    required this.recorder,
    required this.pingBusy,
    this.radio,
    this.barometer,
    this.battery,
    this.deviceDetails,
    this.companion,
    this.phoneEvery = const Duration(seconds: 60),
    this.radioEvery = const Duration(seconds: 60),
    this.pingPressureWindow = const Duration(seconds: 15),
    this.onStatus,
    DateTime Function()? clock,
    PeriodicTimerFactory? periodic,
    this.radioTimer,
  })  : _clock = clock ?? DateTime.now,
        _periodic = periodic ?? Timer.periodic,
        _baroStatus = barometer == null ? SensorStatus.unsupported : SensorStatus.notStarted;

  bool get running => _running;
  SensorStatus get barometerStatus => _baroStatus;

  /// The radio health poller while `radio_health` is on (tests and diagnostics).
  RadioHealthPoller? get poller => _poller;

  bool _on(String id) => recorder.isOn(id);

  /// Starts the collectors whose category is on: the session snapshot, then [refresh].
  Future<void> start() async {
    if (_running) return;
    _running = true;
    refresh();
    await _snapshot();
    await _phoneSampleQueued();
  }

  /// Stops everything; nothing is written after this.
  void stop() {
    _running = false;
    _poller?.stop();
    _poller = null;
    unawaited(_baroSub?.cancel());
    _baroSub = null;
    unawaited(_battSub?.cancel());
    _battSub = null;
    _phoneTimer?.cancel();
    _phoneTimer = null;
    _pressure.clear();
    recorder.close();
  }

  /// Re-reads the switches: stops what was turned off, starts what was turned on.
  void refresh() {
    if (!_running) return;
    // Radio health.
    final r = radio;
    if (_on(CategoryId.radioHealth) && r != null) {
      _poller ??= RadioHealthPoller(
        source: r,
        pingBusy: pingBusy,
        onSample: (s) => unawaited(recorder.recordSample(s)),
        interval: radioEvery,
        clock: _clock,
        timer: radioTimer,
      )..start();
    } else {
      _poller?.stop();
      _poller = null;
    }
    // Barometer.
    final b = barometer;
    if (_on(CategoryId.barometer) && b != null && _baroStatus != SensorStatus.unavailable) {
      if (_baroSub == null) {
        try {
          _baroSub = b.readings().listen(_onPressure, onError: (Object _) => _baroFailed(), cancelOnError: true);
        } catch (_) {
          _baroFailed();
        }
      }
    } else {
      unawaited(_baroSub?.cancel());
      _baroSub = null;
      _pressure.clear();
    }
    // Battery state changes.
    final bat = battery;
    if (_on(CategoryId.phoneBattery) && bat != null) {
      try {
        _battSub ??= bat.stateChanges.listen((_) => unawaited(_phoneSampleQueued()), onError: (Object _) {});
      } catch (_) {}
    } else {
      unawaited(_battSub?.cancel());
      _battSub = null;
    }
    // The once-a-minute phone sample.
    final wantPhone =
        (_on(CategoryId.barometer) && b != null && _baroStatus != SensorStatus.unavailable) ||
            (_on(CategoryId.phoneBattery) && bat != null);
    if (wantPhone) {
      _phoneTimer ??= _periodic(phoneEvery, (_) => unawaited(_phoneSampleQueued()));
    } else {
      _phoneTimer?.cancel();
      _phoneTimer = null;
    }
    // A snapshot category turned on mid-drive is recorded from now.
    if ((!_deviceDone && _on(CategoryId.device)) || (!_companionDone && _on(CategoryId.radioConfig))) {
      unawaited(_snapshot());
    }
  }

  void _onPressure(double hpa) {
    if (!_running || !_on(CategoryId.barometer)) return;
    final now = _clock();
    if (_baroStatus != SensorStatus.reading) {
      _baroStatus = SensorStatus.reading;
      onStatus?.call();
    }
    _pressure.add((now, hpa));
    final keep = now.subtract(phoneEvery * 2);
    while (_pressure.isNotEmpty && _pressure.first.$1.isBefore(keep)) {
      _pressure.removeAt(0);
    }
  }

  void _baroFailed() {
    _baroSub = null;
    _pressure.clear();
    if (_baroStatus != SensorStatus.unavailable) {
      _baroStatus = SensorStatus.unavailable;
      onStatus?.call();
    }
    if (_running) refresh(); // drops the phone timer if only the barometer wanted it
  }

  double? _pressureAround(DateTime at, Duration window) =>
      medianOf([for (final (t, v) in _pressure) if (t.difference(at).abs() <= window) v]);

  Future<void> _snapshot() async {
    if (!_running) return;
    DeviceDetails? d;
    CompanionDetails? c;
    if (!_deviceDone && _on(CategoryId.device)) {
      try {
        d = await deviceDetails?.call();
      } catch (_) {
        d = null;
      }
    }
    if (!_companionDone && _on(CategoryId.radioConfig)) {
      try {
        c = companion?.call();
      } catch (_) {
        c = null;
      }
    }
    if (d == null && c == null) return;
    final written = await recorder.recordSession(device: d, companion: c);
    if (written?.device != null) _deviceDone = true;
    if (written?.companionExt != null) _companionDone = true;
  }

  Future<void> _phoneSampleQueued() => _phoneChain = _phoneChain.then((_) => _phoneSample());

  Future<void> _phoneSample() async {
    if (!_running) return;
    final now = _clock();
    final pressure = _on(CategoryId.barometer) ? _pressureAround(now, phoneEvery) : null;
    PhoneBatteryReading? b;
    if (_on(CategoryId.phoneBattery)) {
      try {
        b = await battery?.read();
      } catch (_) {
        b = null;
      }
    }
    if (!_running) return;
    await recorder.recordSample(DriveSample(
      ts: now,
      src: SampleSource.phone,
      pressureHpa: pressure,
      battPct: b?.levelPct,
      battState: b?.state,
      lowPower: b?.lowPower,
    ));
  }

  /// A GPS fix of the drive (altitude, course and accuracies for the `motion` category).
  void onFix(GeoFix fix) {
    if (_running) recorder.onFix(fix);
  }

  /// A ping that is saved on the phone: records its context (never before the ping itself is on disk).
  Future<PingContext?> onPingSaved(DrivePing ping) async {
    if (!_running) return null;
    final p = _on(CategoryId.barometer) ? _pressureAround(ping.ts, pingPressureWindow) : null;
    return recorder.recordPing(ping, pressureHpa: p);
  }
}
