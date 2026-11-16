// TEMPORARY: the MeshTrack group-operations contract (meshsonar/.scratch/meshtrack-app-contract.md) until the wiring
// branch (`b67/mt-wiring`, file lib/app/meshtrack_wiring.dart) is merged into this one. Same names and shapes, so the
// merge deletes this file and points meshtrack_binding.dart at the real one; no UI file changes.
import 'package:flutter/foundation.dart';

import '../../chat/models.dart';
import '../../core/meshtrack/meshtrack_service.dart';

enum MtGroupOpStatus { ok, radioFull, notConnected, invalidLink, notEligible, nameInvalid, failed }

class MtGroupOpResult {
  final MtGroupOpStatus status;
  final int? channelId;

  /// Plain user copy for a non-ok result.
  final String? message;
  const MtGroupOpResult(this.status, {this.channelId, this.message});
  bool get ok => status == MtGroupOpStatus.ok;
}

abstract class MeshTrackGroupOps extends ChangeNotifier {
  Future<MtGroupOpResult> createGroup(String name);
  Future<MtGroupOpResult> joinFromLink(String link);
  Future<MtGroupOpResult> useExistingChannel(int channelId);
  Future<MtGroupConfig?> stopUsingChannel(int channelId);
  Future<void> undoStopUsing(MtGroupConfig config);
  Future<MtGroupOpResult> startFresh(int channelId);
  Future<void> undoStartFresh(int newChannelId);
  String inviteLink(int channelId);
  List<Channel> eligibleChannels();
  bool notOnRadio(int channelId);
  bool get introSeen;
  Future<void> setIntroSeen();
  MtPositionMode get positionMode;
  Future<void> setPositionMode(MtPositionMode m);
  MtRate get rate;
  Future<void> setRate(MtRate r);
  bool get answerRequests;
  Future<void> setAnswerRequests(bool on);
  bool showPositionMessages(int channelId);
  Future<void> setShowPositionMessages(int channelId, bool on);
  bool isGroup(int channelId);
}
