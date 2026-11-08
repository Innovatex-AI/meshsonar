// Saved radios: every Bluetooth radio this phone has connected to, with the person's nickname, the board model the radio
// reported (DEVICE_INFO), when it last connected, and which one auto-connect goes to (the star). One small JSON file,
// `saved_radios.json`, next to the other app data (format: docs/DATA_MODEL.md "Saved radios").
//
// Rules (also in docs/FEATURES.md "Saved radios"):
//  * A radio is added or updated on every Bluetooth connect (never the Simulator). It is matched by public key first, then by
//    Bluetooth id. The same Bluetooth id reporting a DIFFERENT public key is a different radio: the old entry is replaced.
//  * The star (auto-connect target) follows the most recently connected radio, unless the person starred one themselves
//    ("pinned"): then it stays there until they star another, choose "Follow the most recent radio", or forget it.
//  * Disconnecting or handing the radio to another app on purpose never deletes it: it sets [autoConnectHeld], so nothing
//    reconnects over that choice (design doc 4.1 "Single connection handover"). The next connect, by hand or by tapping a saved
//    radio, clears the hold. A dropped link or a system kill leaves it alone, which is the point of auto-connect.
//  * Forget removes the entry only. Chat history, contacts and the antenna profile stay (they are keyed elsewhere).
//  * Migration: the single remembered radio of 0.27 (`last_radio.json` {id, name, key}) becomes the first entry, starred,
//    with its file time as the last connect (that file was written on every connect). The old file is left in place, read
//    only, so nothing is lost; once `saved_radios.json` exists it is never read again.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../radio/radio_api.dart';

class SavedRadio {
  /// Bluetooth id (iOS peripheral UUID, Android MAC). What a connect needs.
  final String id;

  /// The radio's public key (lower-case hex) when known.
  final String? publicKeyHex;

  /// The name the radio reports for itself.
  final String name;

  /// The person's own name for it; null when not set.
  final String? nickname;

  /// Board model from DEVICE_INFO (e.g. "Heltec V3"), when the firmware reports it.
  final String? model;
  final DateTime? lastConnected;

  const SavedRadio({required this.id, required this.name, this.publicKeyHex, this.nickname, this.model, this.lastConnected});

  /// The nickname when set, else the radio's own name.
  String get displayName {
    final n = nickname?.trim();
    if (n != null && n.isNotEmpty) return n;
    return name.trim().isEmpty ? 'Unnamed radio' : name;
  }

  RadioDevice get device => RadioDevice(id: id, name: name);

  SavedRadio copyWith({String? id, String? name, String? publicKeyHex, String? model, DateTime? lastConnected}) => SavedRadio(
        id: id ?? this.id,
        name: name ?? this.name,
        publicKeyHex: publicKeyHex ?? this.publicKeyHex,
        nickname: nickname,
        model: model ?? this.model,
        lastConnected: lastConnected ?? this.lastConnected,
      );

  SavedRadio withNickname(String? n) => SavedRadio(
      id: id, name: name, publicKeyHex: publicKeyHex, nickname: n, model: model, lastConnected: lastConnected);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (publicKeyHex != null) 'key': publicKeyHex,
        if (nickname != null) 'nickname': nickname,
        if (model != null) 'model': model,
        if (lastConnected != null) 'last_connected': lastConnected!.toUtc().toIso8601String(),
      };

  static SavedRadio? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || (j['id'] as String).isEmpty) return null;
    String? str(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    final at = str('last_connected');
    return SavedRadio(
      id: j['id'] as String,
      name: str('name') ?? 'Unnamed radio',
      publicKeyHex: str('key')?.toLowerCase(),
      nickname: str('nickname'),
      model: str('model'),
      lastConnected: at == null ? null : DateTime.tryParse(at)?.toLocal(),
    );
  }
}

class SavedRadiosStore extends ChangeNotifier {
  /// `saved_radios.json`; null = memory only (tests, the inert runtime).
  final File? file;

  /// `last_radio.json` of 0.27, read once for the migration.
  final File? legacyFile;
  final DateTime Function() clock;

  final List<SavedRadio> _radios = [];
  String? _starredId;
  bool _starPinned = false;
  bool _held = false;
  Future<void>? _loading;
  bool _loaded = false;

  SavedRadiosStore({this.file, this.legacyFile, DateTime Function()? clock, List<SavedRadio> initial = const [], String? starredId, bool starPinned = false})
      : clock = clock ?? DateTime.now {
    _radios.addAll(initial);
    _starredId = starredId ?? (initial.isEmpty ? null : _mostRecent()?.id);
    _starPinned = starPinned;
    if (file == null) {
      _loading = Future<void>.value();
      _loaded = true;
    }
  }

  /// The file has been read (always true for a memory-only store).
  bool get loaded => _loaded;

  /// Starred first, then most recently connected first; radios without a time (only a hand-edited file) last, by name.
  List<SavedRadio> get radios {
    final l = List.of(_radios);
    l.sort((a, b) {
      if (a.id == _starredId) return -1;
      if (b.id == _starredId) return 1;
      final ta = a.lastConnected, tb = b.lastConnected;
      if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
      if (ta != null && tb == null) return -1;
      if (ta == null && tb != null) return 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return List.unmodifiable(l);
  }

  bool get isEmpty => _radios.isEmpty;
  String? get starredId => _starredId;

  /// True when the person chose the star; false when it follows the most recent radio.
  bool get starPinned => _starPinned;

  /// The person disconnected or handed the radio over on purpose: no automatic connect until the next connect.
  bool get autoConnectHeld => _held;

  SavedRadio? get starred => _byId(_starredId);

  /// What auto-connect goes to: the starred radio, unless held.
  SavedRadio? get autoConnectTarget => _held ? null : starred;

  SavedRadio? byId(String id) => _byId(id);

  SavedRadio? _byId(String? id) {
    if (id == null) return null;
    for (final r in _radios) {
      if (r.id == id) return r;
    }
    return null;
  }

  SavedRadio? _mostRecent() {
    SavedRadio? best;
    for (final r in _radios) {
      if (best == null) {
        best = r;
      } else if (r.lastConnected != null && (best.lastConnected == null || r.lastConnected!.isAfter(best.lastConnected!))) {
        best = r;
      }
    }
    return best;
  }

  /// Reads the file once (later calls return the same future). Safe to call from anywhere before using the list.
  Future<void> load() => _loading ??= _load().whenComplete(() => _loaded = true);

  Future<void> _load() async {
    final f = file;
    if (f == null) return;
    try {
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          _radios
            ..clear()
            ..addAll([for (final r in (j['radios'] as List?) ?? const []) ?SavedRadio.fromJson(r)]);
          final star = j['starred'];
          _starredId = star is String && _byId(star) != null ? star : _mostRecent()?.id;
          _starPinned = j['star_pinned'] == true && _starredId == star;
          _held = j['auto_connect_held'] == true;
        }
        notifyListeners();
        return;
      }
    } catch (_) {
      // A damaged file costs the list, never the app. It is rewritten on the next connect.
      notifyListeners();
      return;
    }
    await _migrate();
  }

  Future<void> _migrate() async {
    final old = legacyFile;
    if (old == null) return;
    try {
      if (!await old.exists()) return;
      final j = jsonDecode(await old.readAsString());
      if (j is! Map || j['id'] is! String || (j['id'] as String).isEmpty) return;
      DateTime? at;
      try {
        at = await old.lastModified();
      } catch (_) {}
      final key = j['key'];
      _radios.add(SavedRadio(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Unnamed radio',
        publicKeyHex: key is String && key.isNotEmpty ? key.toLowerCase() : null,
        lastConnected: at,
      ));
      _starredId = j['id'] as String;
      _starPinned = false;
      // The old file existed, so the person had not disconnected on purpose: auto-connect stays as it was.
      _held = false;
      await _save();
    } catch (_) {}
  }

  /// Writes run one after another (two quick changes never write the same temp file at once), each with the latest state.
  Future<void> _writes = Future<void>.value();

  Future<void> _save() {
    notifyListeners();
    if (file == null) return Future<void>.value();
    return _writes = _writes.then((_) => _write());
  }

  Future<void> _write() async {
    final f = file!;
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
          jsonEncode({
            'version': 1,
            'radios': [for (final r in _radios) r.toJson()],
            if (_starredId != null) 'starred': _starredId,
            'star_pinned': _starPinned,
            'auto_connect_held': _held,
          }),
          flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// A Bluetooth radio connected (by hand or automatically). Adds or updates it, moves the star unless pinned, clears the hold.
  Future<void> recordConnect({required String id, required String name, String? publicKeyHex, String? model}) async {
    await load();
    final key = publicKeyHex?.toLowerCase();
    final now = clock();
    var i = key == null ? -1 : _radios.indexWhere((r) => r.publicKeyHex == key);
    if (i < 0) {
      final j = _radios.indexWhere((r) => r.id == id);
      // Same Bluetooth id with another public key = another identity (re-flashed or a new key): not this entry.
      if (j >= 0 && (key == null || _radios[j].publicKeyHex == null || _radios[j].publicKeyHex == key)) i = j;
    }
    final keep = i >= 0 ? _radios[i] : null;
    final oldId = keep?.id;
    // Any other entry at this Bluetooth id can no longer be connected on its own: it is replaced.
    for (final r in _radios.where((r) => r.id == id && !identical(r, keep)).toList()) {
      if (_starredId == r.id) _starPinned = false;
      _radios.remove(r);
    }
    final updated = keep != null
        ? keep.copyWith(id: id, name: name, publicKeyHex: key, model: model, lastConnected: now)
        : SavedRadio(id: id, name: name, publicKeyHex: key, model: model, lastConnected: now);
    if (keep != null) {
      _radios[_radios.indexOf(keep)] = updated;
    } else {
      _radios.add(updated);
    }
    if (oldId != null && _starredId == oldId) _starredId = id;
    if (!_starPinned || starred == null) {
      _starredId = id;
      _starPinned = false;
    }
    _held = false;
    await _save();
  }

  /// The person disconnected or handed the radio over on purpose.
  Future<void> holdAutoConnect() async {
    await load();
    if (_held) return;
    _held = true;
    await _save();
  }

  /// Removes [id] from the list (only the list). A forgotten star goes to the most recent radio left, unpinned.
  Future<void> forget(String id) async {
    await load();
    final before = _radios.length;
    _radios.removeWhere((r) => r.id == id);
    if (_radios.length == before) return;
    if (_starredId == id) {
      _starredId = _mostRecent()?.id;
      _starPinned = false;
    }
    await _save();
  }

  /// Sets or clears (empty / null) the nickname.
  Future<void> setNickname(String id, String? nickname) async {
    await load();
    final i = _radios.indexWhere((r) => r.id == id);
    if (i < 0) return;
    final n = nickname?.trim();
    _radios[i] = _radios[i].withNickname(n == null || n.isEmpty ? null : n);
    await _save();
  }

  /// The person starred [id]: auto-connect goes there until they change it.
  Future<void> pinStar(String id) async {
    await load();
    if (_byId(id) == null) return;
    _starredId = id;
    _starPinned = true;
    await _save();
  }

  /// Back to the default: the star follows the most recently connected radio.
  Future<void> followMostRecent() async {
    await load();
    _starPinned = false;
    _starredId = _mostRecent()?.id;
    await _save();
  }
}
