// Test rig: the REAL MeshCoreCompanionLink + LinkRadioSession over the simulated radio, with the session's Tools. Also a
// scripted ToolsRadio for controller tests that need exact frames and silences.
import 'dart:async';
import 'dart:typed_data';

import 'package:meshsonar/core/heard.dart' show haversineM;
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/tools/tools_radio.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

class ToolsRig {
  final SimulatedTransport radio;
  final MeshCoreCompanionLink link;
  final LinkRadioSession session;

  ToolsRig._(this.radio, this.link, this.session);

  RadioTools get tools => session.tools!;

  /// The simulated repeater nearest to where the simulated phone is parked.
  SimulatedRepeater get nearest {
    final me = radio.location.positionAt(DateTime.now());
    final list = [...radio.repeaters]..sort((a, b) => haversineM(me.lat, me.lon, a.lat, a.lon).compareTo(haversineM(me.lat, me.lon, b.lat, b.lon)));
    return list.first;
  }

  static Future<ToolsRig> start({int? noiseFloorDbm = -112, bool ambient = false, double timeScale = 50}) async {
    final radio = SimulatedTransport(
      seed: 4,
      timeScale: timeScale,
      noiseFloorDbm: noiseFloorDbm,
      location: SimulatedLocationSource(speedMps: 0),
      ambientTraffic: ambient,
    );
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), messagePollInterval: const Duration(minutes: 5));
    final info = await link.start();
    final session = LinkRadioSession(link, info: info);
    return ToolsRig._(radio, link, session);
  }

  Future<void> close() => session.close();
}

/// A ToolsRadio that plays scripted answers. [onSend] sees every command and returns the reply frame (or throws).
class FakeToolsRadio implements ToolsRadio {
  bool connected = true;
  final sent = <({Uint8List frame, int priority})>[];
  final _push = StreamController<Uint8List>.broadcast();
  final _control = StreamController<ControlPacket>.broadcast();
  final _rx = StreamController<RxPacket>.broadcast();
  final _events = StreamController<RadioEvent>.broadcast();
  Frame Function(Uint8List frame)? onSend;
  SelfInfoFrame? selfInfo;
  RadioStatsFrame? Function()? stats;
  CoreStatsFrame? core;
  PacketStatsFrame? packets;
  Uint8List? selfTelemetry;
  final added = <RadioContact>[];
  List<RadioContact> contactList = [];
  List<RadioChannel> channelList = [];

  /// When true, writes are acknowledged but SELF_INFO never changes (a radio that lies).
  bool ignoreWrites = false;

  void push(Uint8List f) => _push.add(f);
  void control(ControlPacket p) => _control.add(p);
  void rx(RxPacket p) => _rx.add(p);
  void event(RadioEvent e) => _events.add(e);

  @override
  bool get isConnected => connected;
  @override
  int? get firmwareVerCode => 13;
  @override
  DeviceLimits? get limits => const DeviceLimits(maxContacts: 350, maxChannels: 40, firmwareVerCode: 13);
  @override
  Stream<RxPacket> get rxPackets => _rx.stream;
  @override
  Stream<ControlPacket> get controlPackets => _control.stream;
  @override
  Stream<Uint8List> get pushes => _push.stream;
  @override
  Stream<RadioEvent> get events => _events.stream;

  @override
  Future<Frame> send(Uint8List frame, {required int priority}) async {
    if (!connected) throw StateError('radio not connected');
    sent.add((frame: frame, priority: priority));
    final h = onSend;
    if (h == null) return const OkFrame();
    return h(frame);
  }

  @override
  Future<SelfInfoFrame?> readSelfInfo() async => selfInfo;
  @override
  Future<RadioStatsFrame?> radioStats({required int priority}) async => stats?.call();
  @override
  Future<CoreStatsFrame?> coreStats({required int priority}) async => core;
  @override
  Future<PacketStatsFrame?> packetStats({required int priority}) async => packets;
  @override
  Future<Uint8List?> selfTelemetryFrame() async => selfTelemetry;
  @override
  Future<List<RadioContact>> contacts() async => contactList;
  @override
  Future<void> addContact(RadioContact contact) async => added.add(contact);
  @override
  Future<List<RadioChannel>> channels() async => channelList;
}

TxArbiter testArbiter({DateTime Function()? clock}) => TxArbiter(clock: clock, airParams: () => const RadioAirParams(7, 62.5, 5));
