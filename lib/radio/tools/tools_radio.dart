// What the Tools need from a radio, as a small interface so every tool is tested against a scripted fake and the real
// MeshCoreCompanionLink alike. Every call goes through the link's one command queue at the priority the caller names
// (command_queue.dart CommandPriority), so a tool can never jump ahead of a user message.
import 'dart:async';
import 'dart:typed_data';

import '../companion_link.dart';
import '../inbound.dart';
import '../protocol.dart';
import '../radio_api.dart';

abstract class ToolsRadio {
  bool get isConnected;

  /// FIRMWARE_VER_CODE from DEVICE_INFO, null when unknown.
  int? get firmwareVerCode;

  /// DEVICE_INFO limits (contacts, channels).
  DeviceLimits? get limits;

  /// Every packet the radio hears (PUSH_LOG_RX_DATA).
  Stream<RxPacket> get rxPackets;

  /// Zero-hop control packets heard (node discovery answers).
  Stream<ControlPacket> get controlPackets;

  /// Every other push frame, raw (trace data, telemetry, binary replies, adverts).
  Stream<Uint8List> get pushes;

  /// DM confirmations, path updates, adverts of known/new contacts.
  Stream<RadioEvent> get events;

  /// One command; the radio's reply. Throws TimeoutException when it does not answer, StateError when disconnected.
  Future<Frame> send(Uint8List frame, {required int priority});

  /// SELF_INFO read again (the read-back).
  Future<SelfInfoFrame?> readSelfInfo();

  Future<RadioStatsFrame?> radioStats({required int priority});
  Future<CoreStatsFrame?> coreStats({required int priority});
  Future<PacketStatsFrame?> packetStats({required int priority});

  /// Raw frame of the radio's own telemetry answer; null when the board does not report any.
  Future<Uint8List?> selfTelemetryFrame();

  /// The radio's contact table.
  Future<List<RadioContact>> contacts();
  Future<void> addContact(RadioContact contact);

  /// The channels on the radio (name and secret), for labelling group packets.
  Future<List<RadioChannel>> channels();
}
