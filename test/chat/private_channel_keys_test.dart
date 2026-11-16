// The private channel key cache behind the observer's third gate (MeshTrack plan section 15): keys by on-air hash, the
// cheap path (no key for other hashes), fail closed while a key is read, channel changes seen at once.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/private_channel_keys.dart';
import 'package:meshsonar/chat/secret_store.dart';

/// [ks] holds [k] (by value; a null answer, fail closed, holds nothing).
bool _has(List<Uint8List>? ks, List<int> k) => ks != null && ks.any((x) => x.toString() == k.toString());

void main() {
  final crew = Uint8List.fromList(List<int>.generate(16, (i) => 0x51 + i));
  final family = Uint8List.fromList(List<int>.generate(16, (i) => 0x90 ^ i));
  late InMemorySecretStore secrets;
  late List<Channel> list;
  late PrivateChannelKeys keys;
  var reads = 0;

  Channel ch(int slot, String name, ChannelKind kind, Uint8List? key) =>
      Channel(radioId: 'r', slot: slot, name: name, kind: kind, secretRef: key == null ? null : 'ref-$slot', hashByte: key == null ? null : channelHashByte(key));

  setUp(() async {
    secrets = InMemorySecretStore();
    reads = 0;
    await secrets.write('ref-0', publicChannelSecret16);
    await secrets.write('ref-1', hashtagSecret16('#ohio'));
    await secrets.write('ref-2', crew);
    await secrets.write('ref-3', family);
    list = [
      ch(0, 'Public', ChannelKind.public, publicChannelSecret16),
      ch(1, '#ohio', ChannelKind.hashtag, hashtagSecret16('#ohio')),
      ch(2, 'Saturday crew', ChannelKind.private, crew),
      ch(3, 'Family', ChannelKind.private, family),
    ];
    keys = PrivateChannelKeys(
      channels: () => list,
      secretOf: (c) {
        reads++;
        return secrets.read(c.secretRef!);
      },
    );
  });

  test('before the keys are read, a private hash fails closed (null); other hashes are empty at once', () async {
    expect(keys.keysFor(channelHashByte(crew)), isNull);
    final other = List<int>.generate(256, (i) => i).firstWhere(
        (h) => h != channelHashByte(crew) && h != channelHashByte(family));
    expect(keys.keysFor(other), isEmpty, reason: 'no private channel with that hash: no key, no MAC');
    await keys.refresh();
    expect(_has(keys.keysFor(channelHashByte(crew)), crew), isTrue);
    expect(_has(keys.keysFor(channelHashByte(family)), family), isTrue);
  });

  test('Public and # channel keys are never in the private set', () async {
    await keys.refresh();
    expect(_has(keys.keysFor(channelHashByte(publicChannelSecret16)), publicChannelSecret16), isFalse);
    expect(_has(keys.keysFor(channelHashByte(hashtagSecret16('#ohio'))), hashtagSecret16('#ohio')), isFalse);
  });

  test('a system channel with a private key counts; a # system channel does not', () async {
    final drive = Uint8List.fromList(List<int>.filled(16, 0x33));
    await secrets.write('ref-4', drive);
    await secrets.write('ref-5', hashtagSecret16('#wardriving'));
    list = [...list, ch(4, 'Drive', ChannelKind.system, drive), ch(5, '#wardriving', ChannelKind.system, hashtagSecret16('#wardriving'))];
    await keys.refresh();
    expect(_has(keys.keysFor(channelHashByte(drive)), drive), isTrue);
    expect(_has(keys.keysFor(channelHashByte(hashtagSecret16('#wardriving'))), hashtagSecret16('#wardriving')), isFalse);
  });

  test('a channel added later fails closed until read, then is known; a removed one is gone at once', () async {
    await keys.refresh();
    final club = Uint8List.fromList(List<int>.generate(16, (i) => 0x20 + 3 * i));
    await secrets.write('ref-6', club);
    list = [...list, ch(6, 'Club', ChannelKind.private, club)];
    expect(keys.keysFor(channelHashByte(club)), isNull);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(_has(keys.keysFor(channelHashByte(club)), club), isTrue);
    list = list.where((c) => c.name != 'Saturday crew').toList();
    expect(_has(keys.keysFor(channelHashByte(crew)), crew), isFalse);
  });

  test('a re-keyed channel (same reference, new hash) is read again', () async {
    await keys.refresh();
    final fresh = Uint8List.fromList(List<int>.generate(16, (i) => 0xc0 + i));
    await secrets.write('ref-2', fresh);
    list = [for (final c in list) c.slot == 2 ? c.copyWith(hashByte: channelHashByte(fresh)) : c];
    expect(keys.keysFor(channelHashByte(fresh)), isNull, reason: 'stale key: fail closed while it is read again');
    await keys.refresh();
    expect(_has(keys.keysFor(channelHashByte(fresh)), fresh), isTrue);
  });

  test('each key is read once while it stays cached', () async {
    await keys.refresh();
    final n = reads;
    for (var i = 0; i < 100; i++) {
      keys.keysFor(channelHashByte(crew));
    }
    expect(reads, n);
  });

  test('a secret the store does not have is skipped, not failed closed forever', () async {
    await secrets.delete('ref-3');
    await keys.refresh();
    expect(keys.keysFor(channelHashByte(family)), isEmpty);
  });
}
