// MeshTrack wiring (MT-5, MT-14; meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md sections 5, 6, 8): the tap and
// the arbiter door, sends, drive start/stop, fix routing (drive and phone), the ping window, radio disconnect, channel
// removed, Keychain restore to a new radio without asking, radio full, Start fresh and Leave with Undo, Delete my data,
// settings across a restart (Share forced off).
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/meshtrack_wiring.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/events.dart';
import 'package:meshsonar/chat/backup.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/api.dart' show MeshTrackSettings, MtPanelTag;
import 'package:meshsonar/core/meshtrack/plus_code.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

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

    test('"Show position messages" on: MT1 text is still never chat (not stored, notified, unread, searched or backed up); '
        'the display-only list has it', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.ops.setShowPositionMessages(id, true);
        r.settle();
        expect(r.ops.showPositionMessages(id), isTrue);
        final events = <ChatEvent>[];
        r.h.service.events.listen(events.add);
        r.inbound(r.channel(id).slot!, 'Sam: MT1 @${PlusCode.encode(40.2, -82.8)} s50 c90');
        r.settle();
        expect(r.svc.state.group(id)!.friends, hasLength(1));
        expect(r.h.service.page(r.channel(id).convKey).messages, isEmpty, reason: 'not stored as chat');
        expect(events.whereType<ChatEvent>().where((e) => e.kind == ChatEventKind.messageAdded), isEmpty, reason: 'not notified');
        expect(r.h.service.unreadMessages(), 0, reason: 'no unread');
        expect(r.h.service.search('MT1'), isEmpty, reason: 'not in search');
        Map<String, dynamic>? backup;
        ChatBackup(r.h.store, newId: () => 'x').exportMap(const BackupOptions()).then((m) => backup = m);
        r.settle();
        expect(jsonEncode(backup), isNot(contains('MT1')), reason: 'not in a backup or export');
        // Visible in the display-only list (channel detail > Position messages).
        final list = r.svc.positionMessages(id);
        expect(list.single.name, 'Sam');
        expect(list.single.body, startsWith('MT1 @'));
        // Off: nothing ever went into the chat, so nothing stays behind.
        r.ops.setShowPositionMessages(id, false);
        r.settle();
        expect(r.h.service.page(r.channel(id).convKey).messages, isEmpty);
      });
    });

    test('Leave clears the channel\'s "Show position messages" setting (Undo puts it back); deleting the channel clears it', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.ops.setShowPositionMessages(id, true);
        r.settle();
        MtGroupConfig? saved;
        r.ops.stopUsingChannel(id).then((v) => saved = v);
        r.settle();
        expect(r.settings.showPositions, isEmpty);
        r.ops.undoStopUsing(saved!);
        r.settle();
        expect(r.settings.showPositions, {id});
        r.admin.delete(r.channel(id));
        r.settle();
        r.changes.pulse();
        r.settle();
        expect(r.svc.state.group(id), isNull);
        expect(r.settings.showPositions, isEmpty);
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

  group('budget pre-check and the ping window', () {
    test('an airtime refusal is counted once per attempt and retried only after the floor', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.arbiter.policy = const TxPolicy(trackBudgetFraction: 0);
        r.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        for (var i = 0; i < 10; i++) {
          r.svc.onFix(MeshTrackWiring.mtFixOf(r.fix()));
          r.settle(const Duration(milliseconds: 160));
        }
        expect(r.sent, isEmpty);
        expect(r.arbiter.snapshot().trackSkipped[TrackSkipReason.budget], 1, reason: 'one refusal for one attempt, not one per fix');
        expect(r.logs.where((l) => l == 'meshtrack: skipped: airtime limit'), hasLength(1));
        expect(r.svc.state.reason, MtShareReason.airtimeLimit);
      });
    });

    test('a drive that failed to start (window left open, never driving) closes the ping window', () {
      fakeAsync((a) {
        final r = MtRig(a);
        final id = r.groupSync('Family');
        r.w.onEngineStatus(const EngineStatus(EngineState.pinging));
        r.svc.onFix(MeshTrackWiring.mtFixOf(r.fix()));
        expect(r.svc.sendMyPosition(id), MtResult.ok);
        r.settle(const Duration(seconds: 1));
        expect(r.sent, isEmpty, reason: 'held while the window is open');
        r.w.driveStopped(); // AppState's failed-start path: the wiring was never driving
        r.settle(const Duration(seconds: 1));
        expect(r.sent, hasLength(1));
        r.w.onEngineStatus(const EngineStatus(EngineState.pinging));
        expect(r.svc.sendMyPosition(id), MtResult.ok);
        r.w.engineStopped(); // engine teardown
        r.settle(const Duration(seconds: 2));
        expect(r.sent, hasLength(2));
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

  group('Keychain registry read failures (never wipe the stored groups)', () {
    for (final mode in ['throws', 'answers nothing']) {
      test('a read that $mode while settings list groups: no write or delete, settings kept; the next good read brings them back', () {
        fakeAsync((a) {
          final r = MtRig(a);
          final id = r.groupSync('Family');
          final settings = r.settings;
          expect(settings.groups, hasLength(1));
          r.w.dispose();
          r.settle();
          final k = FlakyKeychain(r.keychain);
          if (mode == 'throws') {
            k.failReads = true;
          } else {
            k.nullReads = true;
          }
          final r2 = MtRig(a, harness: r.h, keychain: k, settings: settings, lastKnown: r.lastKnown, radios: r.radios, start: false);
          r2.w.setForeground(false); // a background launch: the Keychain may stay locked for a while
          r2.boot();
          expect(r2.w.debugRegistryUnreadable, isTrue);
          expect(r2.svc.state.groups, isEmpty);
          // Any write path while unreadable: a new group.
          r2.groupSync('Club');
          r2.settle();
          expect(k.writes, 0, reason: 'the registry is never written over while it cannot be read');
          expect(k.deletes, 0);
          expect(r2.settings.groups.where((g) => g['name'] == 'Family'), hasLength(1), reason: 'the stored group is kept');
          // The Keychain unlocks: the next write reads first and merges.
          k.failReads = false;
          k.nullReads = false;
          r2.svc.setShareEveryDrive(r2.svc.state.groups.single.channelId, true);
          r2.settle();
          expect(r2.w.debugRegistryUnreadable, isFalse);
          expect(r2.registry().map((e) => e['name']).toSet(), {'Family', 'Club'});
          expect(r2.svc.state.groups.map((g) => g.name).toSet(), {'Family', 'Club'});
          expect(r2.svc.state.group(id), isNotNull);
          expect(r2.settings.groups.map((g) => g['name']).toSet(), {'Family', 'Club'});
        });
      });
    }

    test('a fresh install (no registry, no stored groups) is not "unreadable": the first group is saved', () {
      fakeAsync((a) {
        final k = FlakyKeychain(InMemorySecretStore());
        final r = MtRig(a, keychain: k);
        expect(r.w.debugRegistryUnreadable, isFalse);
        r.groupSync('Family');
        expect(r.registry(), hasLength(1));
        expect(r.settings.groups, hasLength(1));
      });
    });

    test('in front, "nothing" twice in a row is believed (the settings ghost stays, new groups save)', () {
      fakeAsync((a) {
        final r = MtRig(a);
        r.groupSync('Family');
        final settings = r.settings;
        r.w.dispose();
        r.settle();
        final k = FlakyKeychain(InMemorySecretStore()); // a restored phone: settings came back, the Keychain did not
        final r2 = MtRig(a, harness: Harness(), keychain: k, settings: settings, radios: {radioA: FakeRadioSlots(4)}, start: false);
        r2.w.setForeground(false);
        r2.boot();
        expect(r2.w.debugRegistryUnreadable, isTrue, reason: 'behind: "nothing" is not believed');
        r2.w.setForeground(true);
        r2.groupSync('Club');
        expect(r2.w.debugRegistryUnreadable, isFalse);
        expect(r2.registry().map((e) => e['name']), ['Club']);
        expect(r2.settings.groups.map((g) => g['name']).toSet(), {'Family', 'Club'}, reason: 'stored entries not in the registry are kept');
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

    test('Drive panel "New" tag: nothing before the first drive, armed by it, gone for good once MeshTrack is opened', () {
      fakeAsync((a) {
        final r = MtRig(a);
        var notes = 0;
        r.ops.addListener(() => notes++);
        expect(r.ops.panelNew, isFalse);
        r.ops.markPanelSeen(); // opened before any drive: the tag still shows once on the first drive
        r.settle();
        expect(r.settings.panelTag, MtPanelTag.notYet);
        r.w.driveStarted();
        r.settle();
        expect(r.ops.panelNew, isTrue);
        expect(notes, greaterThan(0), reason: 'the panel row rebuilds when the tag arms');
        expect(MeshTrackSettings.fromJson(jsonDecode(jsonEncode(r.settings.toJson()))).panelTag, MtPanelTag.show, reason: 'kept across a restart');
        r.ops.markPanelSeen();
        r.settle();
        expect(r.ops.panelNew, isFalse);
        r.w.driveStopped();
        r.w.driveStarted();
        r.settle();
        expect(r.ops.panelNew, isFalse, reason: 'once per install');
        expect(r.settings.toJson()['panel_new'], 'seen');
        r.w.driveStopped();
        r.settle(const Duration(seconds: 2));
      });
    });

    test('default settings write nothing under meshtrack', () {
      expect(const MeshTrackSettings().isDefault, isTrue);
      expect(const MeshTrackSettings().toJson(), isEmpty);
      expect(MeshTrackSettings.fromJson('junk').isDefault, isTrue);
      expect(MeshTrackSettings.fromJson({'groups': 'x', 'show_positions': [1, 'a']}).showPositions, {1});
      expect(MeshTrackSettings.fromJson({'panel_new': 'notYet'}).panelTag, MtPanelTag.notYet);
      expect(MeshTrackSettings.fromJson({'panel_new': 7}).panelTag, MtPanelTag.notYet);
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

/// A Keychain whose reads can fail (a locked Keychain): [failReads] throws, [nullReads] answers nothing.
class FlakyKeychain implements SecretStore {
  final SecretStore inner;
  bool failReads = false;
  bool nullReads = false;
  int writes = 0, deletes = 0;
  FlakyKeychain(this.inner);
  @override
  Future<Uint8List?> read(String ref) async {
    if (failReads) throw StateError('locked');
    if (nullReads) return null;
    return inner.read(ref);
  }

  @override
  Future<void> write(String ref, Uint8List secret) async {
    writes++;
    await inner.write(ref, secret);
  }

  @override
  Future<void> delete(String ref) async {
    deletes++;
    await inner.delete(ref);
  }
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
