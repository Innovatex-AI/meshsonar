// Contracts for the radio side: talking to a MeshCore companion radio and running a wardrive.
// Pure Dart. Bluetooth (flutter_reactive_ble) and GPS (geolocator) implementations wrap these;
// the simulator implements them too, so the app and tests run with no hardware.
import 'dart:async';
import 'dart:typed_data';

import '../core/model.dart';

/// One MeshCore companion-protocol frame per message (over BLE: one write / one notification).
abstract class ByteTransport {
  Stream<Uint8List> get incoming;
  Future<void> send(Uint8List frame);
  Future<void> disconnect();
  bool get isConnected;
}

/// A radio found by scanning.
class RadioDevice {
  final String id; // platform device id
  final String name;
  final int? rssi;
  const RadioDevice({required this.id, required this.name, this.rssi});
}

abstract class RadioScanner {
  /// Companion radios advertising the MeshCore service. Completes after [timeout].
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)});
  Future<ByteTransport> connect(RadioDevice device);
}

/// A scanner that finds nothing: stands in for the Simulator in builds that leave it out.
class NoRadioScanner implements RadioScanner {
  const NoRadioScanner();
  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) => const Stream.empty();
  @override
  Future<ByteTransport> connect(RadioDevice device) => throw StateError('No such radio');
}

/// What the radio says about itself after app start.
class SelfInfo {
  final String publicKey; // hex, lower case
  final String name;
  final Radio radio;
  final String? firmware;
  const SelfInfo({required this.publicKey, required this.name, required this.radio, this.firmware});
}

/// A packet the radio heard (companion RX log), with what we know about how it arrived.
class RxPacket {
  final DateTime at;
  final double? snrDb;
  final double? rssiDbm;
  final Uint8List raw; // raw over-the-air packet bytes as reported
  const RxPacket({required this.at, required this.raw, this.snrDb, this.rssiDbm});
}

/// High-level session with a companion radio.
abstract class CompanionLink {
  /// App start + device query + set clock. Throws if the radio doesn't answer.
  Future<SelfInfo> start();

  /// Index of the named channel (e.g. "#wardriving"), joining it if the radio doesn't have it yet.
  Future<int> ensureChannel(String name);

  /// Sends text on a channel. Completes when the radio accepts it (not when it's heard).
  Future<void> sendChannelText(int channelIndex, String text);

  /// Every packet the radio hears.
  Stream<RxPacket> get rxPackets;

  /// Current noise floor in dBm, if the firmware reports it; null otherwise.
  Future<double?> noiseFloor();
  Future<void> close();
  bool get isConnected;
}

/// One GPS fix.
class GeoFix {
  final double lat;
  final double lon;
  final double? accuracyM;
  final double? speedMps;
  final DateTime at;

  /// Drive context (stream 7, category `motion`): never part of the drive upload. Null = the platform did not
  /// measure it (accuracy 0 or negative means unknown).
  final double? altitudeM;
  final double? altitudeAccuracyM;

  /// Course over ground (direction of travel), degrees; not the compass heading.
  final double? courseDeg;
  final double? courseAccuracyDeg;
  final double? speedAccuracyMps;
  const GeoFix({
    required this.lat,
    required this.lon,
    required this.at,
    this.accuracyM,
    this.speedMps,
    this.altitudeM,
    this.altitudeAccuracyM,
    this.courseDeg,
    this.courseAccuracyDeg,
    this.speedAccuracyMps,
  });
}

abstract class LocationSource {
  Stream<GeoFix> get fixes;
  Future<GeoFix?> current();

  /// Asks for permission if needed. False = no location; the app can't wardrive.
  Future<bool> ensurePermission();
}

class WardriveConfig {
  final String channel;
  final int intervalSec; // 0 = manual only; otherwise clamped by the engine to 10–120 s
  final int minDistanceM; // clamped by the engine to 15–500 m
  final Duration listenWindow; // how long to collect echoes after each ping
  final double? txPowerW; // shown in the ping text when known
  final double? txDbm; // the radio's TX power, recorded on each ping (Drive Format v1.1 tx_dbm) when known

  /// Discovery / listen-only mode: the engine transmits nothing at all — not even the privacy-hardened `MS:<tag>`
  /// ping — and only records what it overhears from other mesh traffic (rx-kind pings). Immutable mid-drive, the
  /// same as [channel]: see DefaultWardriveEngine's passive RX pipeline.
  final bool listenOnly;
  const WardriveConfig({
    this.channel = '#wardriving',
    this.intervalSec = 30,
    this.minDistanceM = 100,
    this.listenWindow = const Duration(seconds: 10),
    this.txPowerW,
    this.txDbm,
    this.listenOnly = false,
  });
}

/// A phone clock this far from GPS time is reported ([EngineStatus.clockSkew]).
const Duration clockSkewWarnAfter = Duration(minutes: 5);

enum EngineState { idle, starting, driving, pinging, stopping, error }

/// What the next auto-ping is waiting for (both the interval AND the distance must be met).
enum PingWait {
  /// The interval since the last ping hasn't passed yet (see [EngineStatus.nextPingAt]).
  time,

  /// The interval has passed but we haven't moved far enough (see [EngineStatus.metresToGo]).
  distance,

  /// No GPS fix right now.
  gps,
}

class EngineStatus {
  final EngineState state;
  final String? message;
  final GeoFix? lastFix;

  /// Earliest time the next auto-ping may go out (last ping + interval). Null when not auto-pinging.
  /// May be in the past while the engine is waiting for distance.
  final DateTime? nextPingAt;

  /// What the next auto-ping is waiting for; null when not auto-pinging or a ping is due/going out now.
  final PingWait? waitingFor;

  /// Metres still to move before the distance rule is met (0 when met); null when unknown or not auto-pinging.
  final double? metresToGo;

  /// How far the phone's clock is from GPS time (GPS minus phone), when it has been off by more than
  /// [clockSkewWarnAfter] on several fixes in a row; null while the clocks agree. Pings are stamped with the phone
  /// clock, and the server refuses a ping stamped more than a day ahead.
  final Duration? clockSkew;

  /// While a ping's window is open: how many different repeaters have repeated it so far (shown at once, not at the end of
  /// the window). Null outside a window.
  final int? heardSoFar;
  const EngineStatus(this.state,
      {this.message, this.lastFix, this.nextPingAt, this.waitingFor, this.metresToGo, this.clockSkew, this.heardSoFar});
}

/// Runs a drive: pings on the channel on a timer/distance schedule, collects echoes for each ping,
/// and emits one finished DrivePing per ping (after the listen window closes).
abstract class WardriveEngine {
  Stream<DrivePing> get pings;
  Stream<EngineStatus> get status;
  EngineStatus get current;
  Future<void> start(WardriveConfig config);

  /// Changes the auto-ping interval/distance (and listen window / power label) of a running drive. The channel
  /// can't change mid-drive and is ignored. Takes effect immediately; does nothing when not driving.
  void updateConfig(WardriveConfig config);

  /// Pings immediately (also allowed while auto-pinging). Completes with the finished ping.
  Future<DrivePing> pingNow();
  Future<void> stop();

  /// The radio dropped mid-drive (status `error`, "Radio disconnected") and the app has reconnected it as [link]:
  /// rejoin the channel on it and carry on in the SAME drive, with the ping cadence unchanged. Throws if the channel
  /// can't be rejoined (the engine then stays in `error` and the caller may try again) or the drive is stopping.
  Future<void> resumeOnLink(CompanionLink link);
}
