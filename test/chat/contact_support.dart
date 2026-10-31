import 'dart:typed_data';

import 'package:meshsonar/chat/contact_port.dart';
import 'package:meshsonar/chat/models.dart';

import 'support.dart';

String keyN(int n) => n.toRadixString(16).padLeft(2, '0') * 32; // 64 hex chars

/// An in-memory radio contact table behind [ContactRadioPort]: capacity, lastmod stamping, incremental reads, failures on
/// demand. It follows the firmware rules that matter here (MyMesh.cpp 1238-1258 GET_CONTACTS since filter is `lastmod > since`;
/// 1328-1348 ADD_UPDATE restamps lastmod and answers TABLE_FULL; 1349 REMOVE).
class FakeRadioPort implements ContactRadioPort {
  @override
  String? radioId = radioA;
  @override
  bool isConnected = true;
  @override
  int? capacity;
  final table = <String, Contact>{};
  final lastMod = <String, int>{};
  int _mod = 1000;
  final downloads = <int>[];
  final uploads = <String>[];
  final removes = <String>[];
  final resets = <String>[];
  final imports = <Uint8List>[];
  int? dropAfter; // the next download throws after this many contacts
  int dropCount = 0;
  Set<String> hasAdvert = {};
  ContactPolicy policy = const ContactPolicy(askBeforeAdding: false);
  Object? failUpload;

  FakeRadioPort({this.capacity = 100});

  void radioAdd(Contact c) {
    table[c.publicKey] = c.copyWith(onRadio: true);
    lastMod[c.publicKey] = ++_mod;
  }

  void radioTouch(String key) => lastMod[key] = ++_mod;

  @override
  Future<ContactDownload> download({required int since, required void Function(Contact contact, int received, int total) onContact}) async {
    if (!isConnected) throw const RadioUnavailable('not connected');
    downloads.add(since);
    final total = table.length;
    var i = 0, most = 0;
    for (final e in table.entries.toList()) {
      final lm = lastMod[e.key]!;
      if (lm <= since) continue;
      if (dropAfter != null && i >= dropAfter!) {
        dropAfter = null;
        dropCount++;
        throw const RadioUnavailable('timeout: radio stopped sending contacts');
      }
      onContact(e.value.copyWith(lastMod: lm), ++i, total);
      if (lm > most) most = lm;
    }
    return ContactDownload(totalOnRadio: total, cursor: most);
  }

  @override
  Future<Contact?> fetch(String publicKey) async {
    if (!isConnected) throw const RadioUnavailable('not connected');
    final c = table[publicKey];
    return c?.copyWith(lastMod: lastMod[publicKey]);
  }

  @override
  Future<void> upload(Contact contact) async {
    if (!isConnected) throw const RadioUnavailable('not connected');
    if (failUpload != null) throw failUpload!;
    uploads.add(contact.publicKey);
    final exists = table.containsKey(contact.publicKey);
    if (!exists && capacity != null && table.length >= capacity!) throw const ContactTableFull();
    table[contact.publicKey] = contact.copyWith(onRadio: true);
    lastMod[contact.publicKey] = ++_mod;
  }

  @override
  Future<bool> remove(String publicKey) async {
    if (!isConnected) throw const RadioUnavailable('not connected');
    removes.add(publicKey);
    lastMod.remove(publicKey);
    return table.remove(publicKey) != null;
  }

  @override
  Future<bool> resetPath(String publicKey) async {
    resets.add(publicKey);
    final c = table[publicKey];
    if (c == null) return false;
    table[publicKey] = c.copyWith(outPath: null, outPathLen: -1);
    return true;
  }

  @override
  Future<Uint8List?> exportAdvert(String publicKey) async => hasAdvert.contains(publicKey) ? Uint8List(120) : null;

  @override
  Future<void> importAdvert(Uint8List packet) async => imports.add(packet);

  @override
  Future<bool> shareZeroHop(String publicKey) async => hasAdvert.contains(publicKey);

  @override
  Future<ContactPolicy> getPolicy() async => policy;

  @override
  Future<void> setPolicy(ContactPolicy p) async => policy = p;
}

Contact radioContact(int n, {ContactType type = ContactType.companion, String? name, bool path = false, int radioFlags = 0}) => Contact(
      radioId: radioA,
      publicKey: keyN(n),
      type: type,
      name: name ?? 'Node $n',
      lat: 39.0 + n / 1000,
      lon: -84.0,
      lastAdvertTs: 1760000000 + n,
      outPath: path ? Uint8List.fromList([n & 0xff]) : null,
      outPathLen: path ? 1 : -1,
      radioFlags: radioFlags,
    );
