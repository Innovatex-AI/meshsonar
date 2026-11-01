// The radio to bring back after the app was closed by the system. Written when a Bluetooth radio connects, erased when
// the person disconnects or hands the radio to another app on purpose (never auto-reconnect over that choice: design
// doc 4.1 "Single connection handover"). A dropped link or a system kill leaves it in place, which is the point.
import 'dart:convert';
import 'dart:io';

import '../radio/radio_api.dart';

class LastRadio {
  final String id;
  final String name;

  /// The radio's public key when known, so a different radio at the same address is not adopted.
  final String? publicKeyHex;
  const LastRadio(this.id, this.name, {this.publicKeyHex});

  RadioDevice get device => RadioDevice(id: id, name: name);
}

abstract class LastRadioStore {
  Future<LastRadio?> load();
  Future<void> save(LastRadio radio);
  Future<void> clear();
}

class FileLastRadioStore implements LastRadioStore {
  final File file;
  FileLastRadioStore(this.file);

  @override
  Future<LastRadio?> load() async {
    try {
      if (!await file.exists()) return null;
      final j = jsonDecode(await file.readAsString());
      if (j is! Map || j['id'] is! String || (j['id'] as String).isEmpty) return null;
      return LastRadio(j['id'] as String, (j['name'] as String?) ?? 'your radio', publicKeyHex: j['key'] as String?);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(LastRadio r) async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({'id': r.id, 'name': r.name, if (r.publicKeyHex != null) 'key': r.publicKeyHex}), flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class MemoryLastRadioStore implements LastRadioStore {
  LastRadio? value;
  MemoryLastRadioStore([this.value]);
  @override
  Future<LastRadio?> load() async => value;
  @override
  Future<void> save(LastRadio radio) async => value = radio;
  @override
  Future<void> clear() async => value = null;
}
