// Saved packet filters, on the device only (contract 13.26): one small JSON file next to the app's other preferences,
// written atomically. Memory only when there is no file (tests). Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:io';

import 'packet_filter.dart';

class SavedPacketFilterStore {
  final File? file;
  List<SavedPacketFilter> _items = const [];
  bool _loaded = false;
  Future<void> _last = Future<void>.value();

  /// At most this many saved filters (the oldest goes first).
  static const int maxItems = 30;
  SavedPacketFilterStore({this.file});

  List<SavedPacketFilter> get items => _items;

  Future<List<SavedPacketFilter>> load() async {
    if (_loaded) return _items;
    _loaded = true;
    final f = file;
    if (f == null) return _items;
    try {
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is List) _items = List.unmodifiable([for (final e in j) ?SavedPacketFilter.fromJson(e)]);
      }
    } catch (_) {
      _items = const [];
    }
    return _items;
  }

  /// Saves [s]; one with the same name (any case) is replaced.
  Future<void> save(SavedPacketFilter s) async {
    await load();
    final rest = [for (final e in _items) if (e.name.toLowerCase() != s.name.toLowerCase()) e];
    final next = [s, ...rest];
    _items = List.unmodifiable(next.length > maxItems ? next.sublist(0, maxItems) : next);
    await _write();
  }

  Future<void> remove(String name) async {
    await load();
    _items = List.unmodifiable([for (final e in _items) if (e.name != name) e]);
    await _write();
  }

  Future<void> _write() {
    final f = file;
    if (f == null) return Future.value();
    final body = jsonEncode([for (final e in _items) e.toJson()]);
    final next = _last.then((_) async {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(f.path);
    });
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
