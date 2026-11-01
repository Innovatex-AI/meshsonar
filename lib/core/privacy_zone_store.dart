// Where the privacy zones are kept on the phone, so the editor works with no signal and with no driver key yet: one small
// JSON file written atomically (temp file + rename), like FileSettingsStore. A missing or damaged file is "no zones".
// Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:io';

import 'privacy_zones.dart';

abstract class PrivacyZoneStore {
  Future<PrivacyZoneState> load();
  Future<void> save(PrivacyZoneState state);
}

class FilePrivacyZoneStore implements PrivacyZoneStore {
  final File file;
  Future<void> _last = Future<void>.value();
  FilePrivacyZoneStore(this.file);

  @override
  Future<PrivacyZoneState> load() async {
    try {
      if (!await file.exists()) return const PrivacyZoneState();
      return PrivacyZoneState.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return const PrivacyZoneState();
    }
  }

  @override
  Future<void> save(PrivacyZoneState state) {
    final next = _last.then((_) async {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
      await tmp.rename(file.path);
    });
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}

class MemoryPrivacyZoneStore implements PrivacyZoneStore {
  PrivacyZoneState state;
  int saves = 0;
  MemoryPrivacyZoneStore([this.state = const PrivacyZoneState()]);
  @override
  Future<PrivacyZoneState> load() async => state;
  @override
  Future<void> save(PrivacyZoneState s) async {
    state = s;
    saves++;
  }
}
