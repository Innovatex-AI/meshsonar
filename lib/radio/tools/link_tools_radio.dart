// ToolsRadio over a MeshCoreCompanionLink and the session's contact/event calls.
import 'dart:async';
import 'dart:typed_data';

import '../companion_link.dart';
import '../inbound.dart';
import '../protocol.dart';
import '../radio_api.dart';
import '../session.dart';
import 'tools_radio.dart';

class LinkToolsRadio implements ToolsRadio {
  final MeshCoreCompanionLink link;
  final RadioSession session;
  LinkToolsRadio(this.link, this.session);

  @override
  bool get isConnected => link.isConnected;
  @override
  int? get firmwareVerCode => link.firmwareVerCode;
  @override
  DeviceLimits? get limits => session.limits;
  @override
  Stream<RxPacket> get rxPackets => link.rxPackets;
  @override
  Stream<ControlPacket> get controlPackets => link.controlPackets;
  @override
  Stream<Uint8List> get pushes => link.rawPushes;
  @override
  Stream<RadioEvent> get events => session.events;

  @override
  Future<Frame> send(Uint8List frame, {required int priority}) => link.sendToolCommand(frame, priority: priority);
  @override
  Future<SelfInfoFrame?> readSelfInfo() => link.readSelfInfoFrame();
  @override
  Future<RadioStatsFrame?> radioStats({required int priority}) => link.radioStatsAt(priority);
  @override
  Future<CoreStatsFrame?> coreStats({required int priority}) => link.coreStatsAt(priority);
  @override
  Future<PacketStatsFrame?> packetStats({required int priority}) => link.packetStatsAt(priority);
  @override
  Future<Uint8List?> selfTelemetryFrame() => link.selfTelemetryFrame();
  @override
  Future<List<RadioContact>> contacts() async => (await session.getContacts()).contacts;
  @override
  Future<void> addContact(RadioContact contact) => session.addOrUpdateContact(contact);
  @override
  Future<List<RadioChannel>> channels() => session.listChannels();
}
