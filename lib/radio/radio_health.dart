// Radio health (stream 7 WP1/WP2): the companion radio's own counters, read with GET_STATS (core, radio, packets) and
// GET_BATT_AND_STORAGE, turned into DriveSample rows (lib/core/drive_context.dart) by a poller that runs every 60 s
// during a drive and NEVER while a ping is in flight (noise-floor read, send, listen window).
//
// Firmware layouts and null rules: lib/radio/protocol.dart (BattAndStorageFrame, CoreStatsFrame, RadioStatsFrame,
// PacketStatsFrame). Unmeasured is null, never 0: battery 0 mV (board without battery sense), noise floor 0 (not
// calibrated), last RSSI 0 (nothing received yet; then last SNR is meaningless too), storage total 0.
//
// Scheduling is a pure-Dart primitive with an injectable clock and timer so tests run on a fake clock. The drive flow
// (AppState) creates one poller per drive with `pingBusy: () => engine.current.state == EngineState.pinging`; the
// engine is in `pinging` from before its noise-floor read until the listen window has closed, so a stats command can
// never be queued in front of a ping's own commands nor run inside its listen window.
//
// Pure Dart: no Flutter imports.
import 'dart:async';

import '../core/drive_context.dart';
import 'protocol.dart';

/// The read-only stats commands of a companion link. [MeshCoreCompanionLink] implements it; every call goes through
/// the link's single command queue. Each returns null when the radio does not report it (unsupported command or
/// sub-type: asked once per link, then never again), on timeout, error, or when disconnected.
abstract class RadioStatsSource {
  bool get isConnected;
  Future<BattAndStorageFrame?> batteryAndStorage();
  Future<CoreStatsFrame?> coreStats();
  Future<RadioStatsFrame?> radioStats();
  Future<PacketStatsFrame?> packetStats();
}

/// Builds one radio [DriveSample] from whatever replies arrived; null when nothing was measured.
DriveSample? radioSampleFrom({
  required DateTime ts,
  CoreStatsFrame? core,
  RadioStatsFrame? radio,
  PacketStatsFrame? packets,
  BattAndStorageFrame? battStorage,
  int? bleRssi,
}) {
  final rssiKnown = radio != null && radio.lastRssiDbm != 0;
  final s = DriveSample(
    ts: ts,
    src: SampleSource.radio,
    battMv: core?.batteryMv ?? battStorage?.batteryMv,
    uptimeS: core?.uptimeSecs,
    errFlags: core?.errFlags,
    queue: core?.queueLen,
    txAirS: radio?.txAirSecs,
    rxAirS: radio?.rxAirSecs,
    lastRssi: rssiKnown ? radio.lastRssiDbm : null,
    lastSnr: rssiKnown ? radio.lastSnrDb : null,
    noiseDbm: radio?.noiseFloorDbm,
    pkts: packets == null
        ? null
        : PacketCounters(
            recv: packets.recv,
            sent: packets.sent,
            floodTx: packets.floodTx,
            directTx: packets.directTx,
            floodRx: packets.floodRx,
            directRx: packets.directRx,
            recvErrors: packets.recvErrors,
          ),
    storageUsedKb: battStorage?.storageUsedKb,
    storageTotalKb: battStorage?.storageTotalKb,
    bleRssi: bleRssi,
  );
  return s.isEmpty ? null : s;
}

/// Creates a one-shot timer. Production uses [Timer.new]; tests pass a fake.
typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

/// Polls a [RadioStatsSource] every [interval] while running.
///
/// One poll = up to four commands, sent one after another (never in parallel): GET_STATS radio, core, packets, then
/// GET_BATT_AND_STORAGE only every [storageEvery] (storage changes slowly) or when core stats are unavailable (older
/// firmware: battery comes from that command instead). Before EACH command the poller checks [pingBusy]; while it is
/// true it waits, re-checking every [busyRecheck], for at most half an [interval]; past that the rest of this poll is
/// skipped (whatever was already read is still recorded with the poll's start time). Nothing is polled while the
/// radio is disconnected; a gap in samples stays a gap.
class RadioHealthPoller {
  final RadioStatsSource source;
  final bool Function() pingBusy;
  final void Function(DriveSample sample) onSample;
  final Duration interval;
  final Duration busyRecheck;
  final Duration storageEvery;

  /// Optional phone<->radio BLE RSSI read (dBm); null result = unknown.
  final Future<int?> Function()? bleRssi;
  final DateTime Function() _clock;
  final TimerFactory _timer;

  bool _running = false;
  bool _polling = false;
  Timer? _next;
  DateTime? _storageAt;
  DriveSample? _last;

  RadioHealthPoller({
    required this.source,
    required this.pingBusy,
    required this.onSample,
    this.interval = const Duration(seconds: 60),
    this.busyRecheck = const Duration(seconds: 1),
    this.storageEvery = const Duration(minutes: 15),
    this.bleRssi,
    DateTime Function()? clock,
    TimerFactory? timer,
  })  : _clock = clock ?? DateTime.now,
        _timer = timer ?? Timer.new;

  bool get isRunning => _running;

  /// The most recent sample this poller produced (for the per-ping radio battery), or null.
  DriveSample? get lastSample => _last;

  /// Starts polling: the first poll right away, then every [interval]. Does nothing if already running.
  void start() {
    if (_running) return;
    _running = true;
    _schedule(Duration.zero);
  }

  /// Stops polling. A command already sent completes, but nothing further is sent and no sample is emitted after this.
  void stop() {
    _running = false;
    _next?.cancel();
    _next = null;
  }

  void _schedule(Duration delay) {
    _next?.cancel();
    _next = _timer(delay, () {
      _next = null;
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (!_running) return;
    final started = _clock();
    await pollOnce();
    if (!_running) return;
    final elapsed = _clock().difference(started);
    _schedule(elapsed >= interval ? Duration.zero : interval - elapsed);
  }

  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    _timer(d, c.complete);
    return c.future;
  }

  /// Waits until no ping is in flight. False when [deadline] passed, the poller stopped, or the radio disconnected.
  Future<bool> _idle(DateTime deadline) async {
    while (true) {
      if (!_running || !source.isConnected) return false;
      if (!pingBusy()) return true;
      if (!_clock().isBefore(deadline)) return false;
      await _sleep(busyRecheck);
    }
  }

  /// One poll now (also used by [start]'s schedule). Returns the sample written, or null when nothing was measured
  /// or a poll is already in progress.
  Future<DriveSample?> pollOnce() async {
    if (_polling || !_running || !source.isConnected) return null;
    _polling = true;
    try {
      final ts = _clock();
      final deadline = ts.add(interval ~/ 2);
      RadioStatsFrame? radio;
      CoreStatsFrame? core;
      PacketStatsFrame? packets;
      BattAndStorageFrame? battStorage;
      int? ble;
      Future<T?> step<T>(Future<T?> Function() read) async {
        if (!await _idle(deadline)) return null;
        try {
          return await read();
        } catch (_) {
          return null;
        }
      }

      var cut = false;
      radio = await step(source.radioStats);
      cut = !_running || !source.isConnected || !_clock().isBefore(deadline);
      if (!cut) {
        core = await step(source.coreStats);
        packets = await step(source.packetStats);
        final storageDue = _storageAt == null || !_clock().isBefore(_storageAt!.add(storageEvery));
        if (core == null || storageDue) {
          battStorage = await step(source.batteryAndStorage);
          if (battStorage != null) _storageAt = ts;
        }
      }
      final b = bleRssi;
      if (b != null && _running && source.isConnected) {
        try {
          ble = await b();
        } catch (_) {
          ble = null;
        }
      }
      if (!_running) return null;
      final s = radioSampleFrom(ts: ts, core: core, radio: radio, packets: packets, battStorage: battStorage, bleRssi: ble);
      if (s != null) {
        _last = s;
        onSample(s);
      }
      return s;
    } finally {
      _polling = false;
    }
  }
}
