// Where saved plans live on this phone (release 0.38 foundation seam for the Master Planner). One JSON document per plan
// id, kept as text: the Plan JSON v1 codec (lib/core/plan/) encodes and decodes it, this store only keeps it safe
// (atomic write, a damaged file costs only that plan). Its own directory, never mixed with the tools' result cache
// (plan_store.dart) or region data. Nothing here leaves the phone.
// Pure Dart.
import 'dart:io';

abstract class PlanRepository {
  /// Saved plan ids, most recently written first.
  Future<List<String>> ids();

  /// The document saved under [id]; null when there is none or it cannot be read.
  Future<String?> read(String id);
  Future<void> write(String id, String json);
  Future<void> delete(String id);
}

/// Plan ids are file names: letters, digits, `-` and `_`, 1 to 64 characters.
bool isValidPlanId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);

void _checkId(String id) {
  if (!isValidPlanId(id)) throw ArgumentError.value(id, 'id', 'not a plan id');
}

/// One `<id>.plan.json` file per plan in [dir].
class FilePlanRepository implements PlanRepository {
  final Directory dir;
  FilePlanRepository(this.dir);

  static const String _suffix = '.plan.json';
  File _file(String id) => File('${dir.path}${Platform.pathSeparator}$id$_suffix');

  @override
  Future<List<String>> ids() async {
    try {
      if (!await dir.exists()) return const [];
      final files = <(String, DateTime)>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.endsWith(_suffix)) continue;
        final id = name.substring(0, name.length - _suffix.length);
        if (!isValidPlanId(id)) continue;
        files.add((id, await e.lastModified()));
      }
      files.sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final f in files) f.$1];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> read(String id) async {
    if (!isValidPlanId(id)) return null;
    try {
      final f = _file(id);
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String id, String json) async {
    _checkId(id);
    await dir.create(recursive: true);
    final f = _file(id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String id) async {
    if (!isValidPlanId(id)) return;
    try {
      final f = _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// In memory (tests, no file system).
class MemoryPlanRepository implements PlanRepository {
  final Map<String, String> _docs = {};
  final List<String> _order = [];

  @override
  Future<List<String>> ids() async => List.of(_order.reversed);

  @override
  Future<String?> read(String id) async => _docs[id];

  @override
  Future<void> write(String id, String json) async {
    _checkId(id);
    _docs[id] = json;
    _order
      ..remove(id)
      ..add(id);
  }

  @override
  Future<void> delete(String id) async {
    _docs.remove(id);
    _order.remove(id);
  }
}
