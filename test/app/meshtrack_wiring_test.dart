// MeshTrack wiring (MT-5, MT-14; meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md sections 5, 6, 8): the tap and
// the arbiter door, sends, drive start/stop, fix routing (drive and phone), the ping window, radio disconnect, channel
// removed, Keychain restore to a new radio without asking, radio full, Start fresh and Leave with Undo, Delete my data,
// settings across a restart (Share forced off).
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/meshtrack_wiring.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/api.dart' show MeshTrackSettings;
import 'package:meshsonar/core/meshtrack/plus_code.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../chat/support.dart';
import 'meshtrack_rig.dart';

void main() {
  group('chat seams', () {
    test('the inbound tap is registered: MT1 text from a friend is not chat and puts a pin on the map', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        final slot = r.channel(id).slot!;
        r.inbound(slot, 'Sam: MT1 @${PlusCode.encode(40.2, -82.8)} s40 c90');
        r.inbound(slot, 'Sam: running late');
        r.settle();
        final f = r.svc.state.group(id)!.friends.single;
        expect(f.name, 'Sam');
        expect(f.lat, closeTo(40.2, 0.001));
        final msgs = r.h.service.page(r.channel(id).convKey).messages;
        expect(msgs.map((m) => m.text), ['running late'], reason: 'position text consumed, normal text stays chat');
      });
    });

    test('"Show position messages" on keeps MT1 text as chat in that channel, and still updates the map', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.ops.setShowPositionMessages(id, true);
        r.settle();
        expect(r.ops.showPositionMessages(id), isTrue);
        r.inbound(r.channel(id).slot!, 'Sam: MT1 @${PlusCode.encode(40.2, -82.8)}');
        r.settle();
        expect(r.svc.state.group(id)!.friends, hasLength(1));
        expect(r.h.service.page(r.channel(id).convKey).messages, hasLength(1));
      });
    });

    test('the track gate is the arbiter while chat is bound, and is removed with the binding', () {
      fakeAsync((a) {
        final r = MtRig(a);
        expect(identical(r.h.service.trackGate, r.arbiter), isTrue);
        r.w.bindChat(null);
        expect(r.h.service.trackGate, isNull);
        r.w.bindChat(r.binding());
        expect(identical(r.h.service.trackGate, r.arbiter), isTrue);
      });
    });

    test('sends go silently through the arbiter as track (no chat bubble), with the radio name prefix rules', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        expect(r.svc.setShare(id, true, duration: MtShareDuration.untilStopped), MtResult.ok);
        r.svc.onFix(MeshTrackWiring.mtFixOf(r.fix()));
        r.settle();
        expect(r.sent, hasLength(1));
        expect(r.sent.single.slot, r.channel(id).slot);
        expect(r.sent.single.text, startsWith('MT1 @'));
        expect(r.h.service.page(r.channel(id).convKey).messages, isEmpty, reason: 'no bubble');
        expect(r.logs.join('\n'), isNot(contains('@')), reason: 'no code in any log line');
        expect(r.logs.join('\n'), isNot(contains('40.1')));
      });
    });
  });

  group('drive, fixes and the ping window', () {
    test('This drive: nothing before the drive; drive fixes send; the drive stop ends sharing with MT1 x', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.svc.setShare(id, true);
        r.w.onDriveFix(r.fix());
        r.settle();
        expect(r.sent, isEmpty);
        expect(r.svc.state.reason, MtShareReason.waitingForDrive);
        r.w.driveStarted();
        r.w.onDriveFix(r.fix());
        r.settle();
        expect(r.sent, hasLength(1));
        r.w.driveStopped();
        r.settle(const Duration(seconds: 2));
        expect(r.sent.last.text, 'MT1 x');
        expect(r.svc.state.group(id)!.config.share, isFalse);
      });
    });

    test('ping window: EngineStatus maps to listening / nextPingAt, and no send goes inside the window', () {
      fakeAsync((a) {
        final next = DateTime.utc(2026, 11, 16, 12, 5);
        expect(MeshTrackWiring.pingWindowOf(const EngineStatus(EngineState.pinging)).listening, isTrue);
        expect(MeshTrackWiring.pingWindowOf(const EngineStatus(EngineState.driving, heardSoFar: 0)).listening, isTrue);
        final idle = MeshTrackWiring.pingWindowOf(EngineStatus(EngineState.driving, nextPingAt: next));
        expect(idle.listening, isFalse);
        expect(idle.nextPingAt, next);

        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.svc.setShare(id, true);
        r.w.driveStarted();
        r.w.onEngineStatus(const EngineStatus(EngineState.pinging));
        r.w.onDriveFix(r.fix());
        r.settle(const Duration(seconds: 1));
        expect(r.sent, isEmpty, reason: 'held while the ping listens');
        r.w.onEngineStatus(EngineStatus(EngineState.driving, nextPingAt: r.now().add(const Duration(seconds: 30))));
        r.settle(const Duration(milliseconds: 500));
        expect(r.sent, hasLength(1), reason: 'goes about 1 s after the window closes');
      });
    });

    test('sharing without a drive (1 hour / Until I stop) uses the phone location while the app is in front', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        expect(r.w.phoneFixesActive, isFalse);
        r.svc.setShare(id, true, duration: MtShareDuration.oneHour);
        r.settle();
        expect(r.w.phoneFixesActive, isTrue);
        r.phone.add(r.fix());
        r.settle();
        expect(r.sent, hasLength(1));
        r.w.setForeground(false);
        expect(r.w.phoneFixesActive, isFalse, reason: 'foreground only: no background location');
        r.w.setForeground(true);
        expect(r.w.phoneFixesActive, isTrue);
        r.w.driveStarted();
        expect(r.w.phoneFixesActive, isFalse, reason: 'the drive stream takes over');
        r.w.driveStopped();
        expect(r.w.phoneFixesActive, isTrue);
        r.svc.setShare(id, false);
        r.settle();
        expect(r.w.phoneFixesActive, isFalse);
        expect(r.phone.listening, isFalse);
        // "This drive" never opens the phone location.
        r.svc.setShare(id, true);
        r.settle();
        expect(r.w.phoneFixesActive, isFalse);
      });
    });
  });

  group('failure modes', () {
    test('radio disconnect: sends pause; after 5 min sharing turns off (radioDisconnected event)', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        r.disconnect();
        expect(r.svc.state.reason, MtShareReason.radioDisconnected);
        a.elapse(const Duration(minutes: 4));
        expect(r.svc.state.group(id)!.config.share, isTrue);
        a.elapse(const Duration(minutes: 1, seconds: 1));
        expect(r.svc.state.group(id)!.config.share, isFalse);
        expect(r.events.whereType<MtSharingStopped>().map((e) => e.cause), contains(MtStopCause.radioDisconnected));
      });
    });

    test('channel removed from the radio by another app on a full radio: See/Share off, Not on this radio', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        final slot = r.channel(id).slot!;
        // Another app removes it and fills every free place.
        r.radio.clearSlot(slot);
        for (var i = 1; i < 4; i++) {
          if (r.radio.slotList[i].isEmpty) r.radio.put(i, 'Other$i', List.filled(16, 0x40 + i));
        }
        r.syncFromRadio();
        expect(r.ops.notOnRadio(id), isTrue);
        final g = r.svc.state.group(id)!;
        expect(g.config.see, isFalse);
        expect(g.config.share, isFalse);
        expect(r.svc.setShare(id, true), MtResult.notOnRadio);
        // Make room: the person removes a channel; the group goes back by itself.
        r.radio.clearSlot(3);
        r.syncFromRadio();
        expect(r.ops.notOnRadio(id), isFalse);
        expect(r.svc.state.group(id)!.config.see, isTrue, reason: 'the See choice came back');
        expect(r.radio.withSecret(r.keyOf(id)), isNotNull);
      });
    });

    test('the person deletes the channel (the channel delete flow): the group goes with it', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.admin.delete(r.channel(id));
        r.settle();
        expect(r.ops.isGroup(id), isFalse);
        expect(r.svc.state.groups, isEmpty);
        expect(r.settings.groups, isEmpty);
        r.disconnect();
        r.connect(radioA);
        expect(r.svc.state.groups, isEmpty, reason: 'never written back after a delete');
      });
    });
  });

  group('groups: create, join, radio full', () {
    test('New group: private channel on the radio, See on, Share off, key in the Keychain registry', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync("Andy's crew");
        final g = r.svc.state.group(id)!;
        expect(g.config.see, isTrue);
        expect(g.config.share, isFalse);
        expect(r.channel(id).kind, ChannelKind.private);
        expect(r.ops.isGroup(id), isTrue);
        expect(r.registry(), hasLength(1));
        expect(r.settings.groups.single['uid'], isA<String>());
        final link = r.ops.inviteLink(id);
        final p = MeshLinks.parse(link) as ChannelLink;
        expect(p.name, "Andy's crew");
        expect(p.secret, r.keyOf(id));
      });
    });

    test('radio full: New group answers radioFull with plain copy (never "slot")', () {
      fakeAsync((a) {
        final r = MtRig(a);
        for (var i = 1; i < 4; i++) {
          r.radio.put(i, 'Other$i', List.filled(16, 0x40 + i));
        }
        r.syncFromRadio();
        MtGroupOpResult? res;
        r.ops.createGroup('Family').then((v) => res = v);
        r.settle();
        expect(res!.status, MtGroupOpStatus.radioFull);
        expect(res!.message, isNot(contains('slot')));
        expect(r.svc.state.groups, isEmpty);
      });
    });

    test('Join from a link: private joins; Public and # are refused; not connected is said plainly', () {
      fakeAsync((a) {
        final r = MtRig(a);
        MtGroupOpResult? res;
        final secret = List<int>.generate(16, (i) => 0x90 + i);
        r.ops.joinFromLink(MeshLinks.encodeChannel(name: 'Club', secret: secret)).then((v) => res = v);
        r.settle();
        expect(res!.ok, isTrue);
        expect(r.svc.state.group(res!.channelId!)!.name, 'Club');
        r.ops.joinFromLink(MeshLinks.encodeChannel(name: '#hamradio', secret: hashtagSecret16('#hamradio'))).then((v) => res = v);
        r.settle();
        expect(res!.status, MtGroupOpStatus.notEligible);
        r.ops.joinFromLink(MeshLinks.encodeChannel(name: 'Public', secret: publicChannelSecret16)).then((v) => res = v);
        r.settle();
        expect(res!.status, MtGroupOpStatus.notEligible);
        r.ops.joinFromLink('hello').then((v) => res = v);
        r.settle();
        expect(res!.status, MtGroupOpStatus.invalidLink);
        r.disconnect();
        r.ops.joinFromLink(MeshLinks.encodeChannel(name: 'Club2', secret: List.filled(16, 7))).then((v) => res = v);
        r.settle();
        expect(res!.status, MtGroupOpStatus.notConnected);
      });
    });

    test('Use with MeshTrack on an existing private channel; eligibleChannels lists only private ones', () {
      fakeAsync((a) {
        final r = MtRig(a);
        r.radio.put(1, 'Hunt', List.filled(16, 0x33));
        r.radio.put(2, '#hamradio', hashtagSecret16('#hamradio'));
        r.syncFromRadio();
        final names = r.ops.eligibleChannels().map((c) => c.name).toList();
        expect(names, ['Hunt']);
        MtGroupOpResult? res;
        r.ops.useExistingChannel(r.ops.eligibleChannels().single.id!).then((v) => res = v);
        r.settle();
        expect(res!.ok, isTrue);
        expect(r.ops.eligibleChannels(), isEmpty);
      });
    });
  });

  group('Keychain restore (U7)', () {
    test('a new radio: the group is written to a free place on connect without asking', () {
      fakeAsync((a) {
        final r = MtRig(a, radios: {radioA: FakeRadioSlots(4), radioB: FakeRadioSlots(8)});
        final id = r.groupSync('Family');
        final key = r.keyOf(id);
        r.disconnect();
        r.connect(radioB);
        expect(r.radios[radioB]!.withSecret(key), isNotNull, reason: 'written back without asking');
        final g = r.svc.state.groups.single;
        expect(g.name, 'Family');
        expect(g.config.onRadio, isTrue);
        expect(r.channel(g.channelId).radioId, radioB);
        // Back to the first radio: the first row again, nothing written twice.
        final writes = r.radios[radioA]!.writes;
        r.disconnect();
        r.connect(radioA);
        expect(r.svc.state.groups.single.channelId, id);
        expect(r.radios[radioA]!.writes, writes);
      });
    });

    test('a reinstall (no chat database, no settings; the Keychain stays): groups come back on connect', () {
      fakeAsync((a) {
        final keychain = r0Keychain(a);
        final r = MtRig(a, keychain: keychain, radios: {radioA: FakeRadioSlots(4)});
        expect(r.svc.state.groups.single.name, 'Family');
        expect(r.radio.used, 2);
      });
    });

    test('a new radio that is full: the group shows Not on this radio until room is made', () {
      fakeAsync((a) {
        final full = FakeRadioSlots(2)..put(1, 'Other', List.filled(16, 0x55));
        final r = MtRig(a, radios: {radioA: FakeRadioSlots(4), radioB: full});
        final id = r.groupSync('Family');
        r.disconnect();
        r.connect(radioB);
        final g = r.svc.state.groups.single;
        expect(g.channelId, isNot(id));
        expect(r.ops.notOnRadio(g.channelId), isTrue);
        expect(r.channel(g.channelId).slot, isNull);
        full.clearSlot(1);
        r.syncFromRadio();
        expect(r.ops.notOnRadio(r.svc.state.groups.single.channelId), isFalse);
        expect(full.withSecret(r.keyOf(id)), isNotNull);
      });
    });
  });

  group('Start fresh, Leave, Undo', () {
    test('Start fresh: new key, same name, same place on the radio, old group retired; Undo puts it all back', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        final oldKey = r.keyOf(id);
        final slot = r.channel(id).slot!;
        r.inbound(slot, 'Sam: MT1 @${PlusCode.encode(40.2, -82.8)}');
        MtGroupOpResult? res;
        r.ops.startFresh(id).then((v) => res = v);
        r.settle();
        expect(res!.ok, isTrue);
        final nid = res!.channelId!;
        expect(nid, isNot(id));
        expect(r.channel(nid).name, 'Family');
        expect(r.channel(nid).slot, slot);
        expect(r.channel(id).slot, isNull, reason: 'old channel off the radio, history kept on the phone');
        expect(r.keyOf(nid), isNot(oldKey));
        expect(r.radio.withSecret(oldKey), isNull);
        expect(r.ops.isGroup(id), isFalse);
        expect(r.svc.state.group(nid)!.friends, isEmpty);
        expect((MeshLinks.parse(r.ops.inviteLink(nid)) as ChannelLink).secret, r.keyOf(nid));
        r.ops.undoStartFresh(nid);
        r.settle();
        expect(r.ops.isGroup(id), isTrue);
        expect(r.ops.isGroup(nid), isFalse);
        expect(r.h.store.channels.getById(nid), isNull);
        expect(r.channel(id).slot, slot);
        expect(r.radio.withSecret(oldKey)!.index, slot);
        expect(r.registry().single['secret'], toHex(oldKey));
      });
    });

    test('Leave: See/Share off, friends and last-known forgotten, channel kept; Undo brings the group back', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        r.inbound(r.channel(id).slot!, 'Sam: MT1 @${PlusCode.encode(40.2, -82.8)}');
        r.settle(const Duration(seconds: 2));
        expect(r.lastKnown.data, contains('Sam'));
        MtGroupConfig? cfg;
        r.ops.stopUsingChannel(id).then((v) => cfg = v);
        r.settle(const Duration(seconds: 2));
        expect(cfg, isNotNull);
        expect(r.ops.isGroup(id), isFalse);
        expect(r.registry(), isEmpty);
        expect(r.settings.groups, isEmpty);
        expect(r.h.store.channels.getById(id), isNotNull, reason: 'channel and chat kept');
        expect(r.lastKnown.data ?? '', isNot(contains('Sam')));
        r.ops.undoStopUsing(cfg!);
        r.settle();
        expect(r.ops.isGroup(id), isTrue);
        expect(r.svc.state.group(id)!.config.share, isFalse, reason: 'Undo never turns Share back on');
        expect(r.registry(), hasLength(1));
      });
    });

    test('Leave called on the service directly (the UI path) also updates the Keychain and settings', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        final cfg = r.svc.leaveGroup(id)!;
        r.settle();
        expect(r.registry(), isEmpty);
        r.svc.restoreGroup(cfg);
        r.settle();
        expect(r.registry(), hasLength(1));
        expect(r.settings.groups, hasLength(1));
      });
    });
  });

  group('storage', () {
    test('Delete my data clears last-known, the group list and the Keychain registry (channels stay)', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.inbound(r.channel(id).slot!, 'Sam: MT1 @${PlusCode.encode(40.2, -82.8)}');
        r.settle(const Duration(seconds: 2));
        int? n;
        r.w.clearLocal().then((v) => n = v);
        r.settle();
        expect(n, 1);
        expect(r.lastKnown.clears, greaterThanOrEqualTo(1));
        expect(r.lastKnown.data, isNull);
        expect(r.svc.state.groups, isEmpty);
        expect(r.settings.groups, isEmpty);
        expect(r.registry(), isEmpty);
        expect(r.h.store.channels.getById(id), isNotNull);
      });
    });

    test('settings persist across a restart and Share is forced off at start', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        r.svc.setShareEveryDrive(id, true);
        r.ops.setPositionMode(MtPositionMode.approximate);
        r.ops.setRate(MtRate.lowTraffic);
        r.ops.setAnswerRequests(false);
        r.ops.setIntroSeen();
        r.settle();
        expect(r.settings.groups.single['share'], isTrue);
        // settings.json round trip.
        final saved = MeshTrackSettings.fromJson(jsonDecode(jsonEncode(r.settings.toJson())));
        r.w.dispose();
        r.settle();
        final r2 = MtRig(a, harness: r.h, keychain: r.keychain, settings: saved, lastKnown: r.lastKnown, radios: r.radios);
        final g = r2.svc.state.group(id)!;
        expect(g.config.share, isFalse, reason: 'sharing never resumes by itself');
        expect(g.config.shareEveryDrive, isTrue);
        expect(r2.svc.state.positionMode, MtPositionMode.approximate);
        expect(r2.svc.state.rate, MtRate.lowTraffic);
        expect(r2.svc.state.answerRequests, isFalse);
        expect(r2.ops.introSeen, isTrue);
        expect(r2.settings.groups.single['share'], isFalse);
      });
    });

    test('default settings write nothing under meshtrack', () {
      expect(const MeshTrackSettings().isDefault, isTrue);
      expect(const MeshTrackSettings().toJson(), isEmpty);
      expect(MeshTrackSettings.fromJson('junk').isDefault, isTrue);
      expect(MeshTrackSettings.fromJson({'groups': 'x', 'show_positions': [1, 'a']}).showPositions, {1});
    });

    test('the privacy zones gate the wiring sends too (zones not loaded = nothing)', () {
      fakeAsync((a) {
        final r = MtRig(a);
        r.zones = PrivacyZones.notLoaded;
        final id = r.groupSync('Family');
        r.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        r.phone.add(r.fix());
        r.settle();
        expect(r.sent, isEmpty);
        expect(r.svc.state.reason, MtShareReason.zonesNotLoaded);
      });
    });
  });
}

/// A Keychain that already holds one group "Family" (made on another install).
SecretStore r0Keychain(FakeAsync a) {
  final r = MtRig(a);
  r.groupSync('Family');
  r.w.dispose();
  r.settle();
  return r.keychain;
}

extension on MtRig {
  List<int> keyOf(int channelId) {
    List<int>? k;
    h.store.channels.secretOf(channel(channelId)).then((v) => k = v);
    a.flushMicrotasks();
    return k!;
  }

  List<Map<String, Object?>> registry() {
    List<int>? raw;
    keychain.read(MeshTrackWiring.registryRef).then((v) => raw = v);
    a.flushMicrotasks();
    if (raw == null) return const [];
    return [for (final e in jsonDecode(utf8.decode(raw!)) as List) (e as Map).cast<String, Object?>()];
  }
}
