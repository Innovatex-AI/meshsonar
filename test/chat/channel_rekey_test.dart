// ChannelAdmin.rekeyPrivate / undoRekey: the MeshTrack "Start fresh" seam (meshtrack plan 5.5).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_admin.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/store.dart';

import '../app/meshtrack_rig.dart' show FakeRadioSlots;
import 'support.dart';

void main() {
  late ChatStore store;
  late FakeRadioSlots radio;
  late ChannelAdmin admin;
  var changes = 0;
  setUp(() {
    store = ChatStore.inMemory();
    radio = FakeRadioSlots(2);
    changes = 0;
    admin = ChannelAdmin(store: store, radio: () => radio, wardriveChannelName: () => '#wardriving', onChanged: () => changes++);
  });

  test('a new key in the same place, even on a full radio; the old row keeps its history off the radio', () async {
    final old = (await admin.createPrivate(radioA, 'Family')).channel;
    expect(radio.used, 2, reason: 'the radio is now full');
    final oldKey = (await store.channels.secretOf(old))!;
    final fresh = (await admin.rekeyPrivate(old)).channel;
    expect(fresh.id, isNot(old.id));
    expect(fresh.name, 'Family');
    expect(fresh.slot, old.slot);
    final newKey = (await store.channels.secretOf(fresh))!;
    expect(newKey, isNot(oldKey));
    expect(radio.slotList[old.slot!].secret, newKey);
    final retired = store.channels.getById(old.id!)!;
    expect(retired.slot, isNull);
    expect(retired.name, 'Family (old)');
    expect(await store.channels.secretOf(retired), oldKey);
    expect(changes, 2);

    final back = await admin.undoRekey(retired, fresh);
    expect(back.id, old.id);
    expect(back.name, 'Family');
    expect(back.slot, old.slot);
    expect(radio.slotList[old.slot!].secret, oldKey);
    expect(store.channels.getById(fresh.id!), isNull);
  });

  test('only private channels on the radio', () async {
    final pub = (await admin.joinPublic(radioA)).channel;
    await expectLater(admin.rekeyPrivate(pub), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.notAllowed)));
    final off = await store.channels.save(Channel(radioId: radioA, name: 'Gone', kind: ChannelKind.private), secret: Uint8List(16)..[0] = 9);
    await expectLater(admin.rekeyPrivate(off), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.notOnRadio)));
  });

  test('retiredName stays within the radio name length', () {
    expect(ChannelAdmin.retiredName('Club'), 'Club (old)');
    final long = 'x' * 31;
    final r = ChannelAdmin.retiredName(long);
    expect(utf8.encode(r).length, lessThanOrEqualTo(ChannelAdmin.maxNameBytes));
    expect(r, endsWith(' (old)'));
  });
}
