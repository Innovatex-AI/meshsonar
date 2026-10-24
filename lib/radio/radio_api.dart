// Contracts for the radio side: talking to a MeshCore companion radio and running a wardrive.
// Pure Dart. Bluetooth (flutter_blue_plus) and GPS (geolocator) implementations wrap these;
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
    this.listenWindow = const Duration(seconds: 7),
    this.txPowerW,
    this.txDbm,
    this.listenOnly = false,
  });
}

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
  const EngineStatus(this.state, {this.message, this.lastFix, this.nextPingAt, this.waitingFor, this.metresToGo});
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
}
