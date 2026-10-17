// The one problem report saved on the phone when it couldn't be sent (MeshSonar 0.4.0). Plain text in, plain text
// out: the app decides what the draft holds. Written atomically (temp file + rename), like FileSettingsStore.
// Pure Dart: no Flutter imports.
import 'dart:io';

abstract class ReportDraftStore {
  /// The saved draft, or null when there is none.
  Future<String?> load();

  /// Replaces the saved draft.
  Future<void> save(String draft);
  Future<void> clear();
}

class FileReportDraftStore implements ReportDraftStore {
  final File file;
  Future<void> _last = Future<void>.value();

  FileReportDraftStore(this.file);

  @override
  Future<String?> load() async {
    await _last;
    try {
      return await file.exists() ? await file.readAsString() : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> save(String draft) => _serialized(() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(draft, flush: true);
    await tmp.rename(file.path);
  });

  @override
  Future<void> clear() => _serialized(() async {
    if (await file.exists()) await file.delete();
  });

  /// Runs file changes one at a time so two quick saves can't race on the temp file.
  Future<void> _serialized(Future<void> Function() op) {
    final next = _last.then((_) => op());
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
