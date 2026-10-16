// Settings persisted as one JSON file, written atomically (temp file + rename). Missing or corrupt → defaults.
// Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:io';

import 'api.dart';

class FileSettingsStore implements SettingsStore {
  final File file;
  Future<void> _last = Future<void>.value();

  FileSettingsStore(this.file);

  @override
  Future<Settings> load() async {
    try {
      if (!await file.exists()) return const Settings();
      final j = jsonDecode(await file.readAsString());
      if (j is! Map) return const Settings();
      return Settings.fromJson(j.cast<String, dynamic>());
    } catch (_) {
      return const Settings();
    }
  }

  @override
  Future<void> save(Settings settings) {
    // Serialize saves so two quick saves can't race on the temp file.
    final next = _last.then((_) async {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
      await tmp.rename(file.path);
    });
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
