// Build 76: what the removed map packs feature left on a tester's phone is deleted at launch, and nothing else is touched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/removed_map_packs.dart';

void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('ms-removed-packs'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('deletes the old pack folder with every file a build up to 75 kept there, and reports the bytes freed', () async {
    final packs = oldMapPackFolder(base)..createSync(recursive: true);
    expect(packs.path, '${base.path}/meshsonar/offline_packs');
    final sizes = {
      'CMH.pmtiles': 4096,
      'CMH.coverage.pmtiles': 1024,
      'NYC.pmtiles.part': 512,
      'NYC.pmtiles.part.json': 20,
      'packs.json': 120,
      'prefs.json': 40,
      'manifest.cache.json': 300,
      'packs.json.tmp': 7,
    };
    sizes.forEach((name, n) => File('${packs.path}/$name').writeAsBytesSync(List.filled(n, 1)));
    // Other things the app keeps beside it stay.
    final drives = File('${base.path}/meshsonar/sessions/d1/pings.jsonl')..createSync(recursive: true);
    drives.writeAsStringSync('{"keep":true}\n');
    final profile = File('${base.path}/meshsonar/power_profile.json')..writeAsStringSync('{}');

    final freed = await removeOldMapPackFiles([base]);

    expect(freed, sizes.values.reduce((a, b) => a + b));
    expect(packs.existsSync(), isFalse);
    expect(drives.readAsStringSync(), '{"keep":true}\n');
    expect(profile.existsSync(), isTrue);
    expect(Directory('${base.path}/meshsonar').listSync().map((e) => e.path.split('/').last).toSet(), {'sessions', 'power_profile.json'});
  });

  test('nothing there (every later launch, a new install): does nothing and does not create the folder', () async {
    expect(await removeOldMapPackFiles([base]), 0);
    expect(base.listSync(), isEmpty);
    expect(await removeOldMapPackFiles([Directory('${base.path}/missing')]), 0);
  });

  test('both data folders are cleaned, and a second run finds nothing', () async {
    final docs = Directory('${base.path}/docs'), support = Directory('${base.path}/support');
    for (final d in [docs, support]) {
      File('${oldMapPackFolder(d).path}/X.pmtiles')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
    }
    expect(await removeOldMapPackFiles([support, docs]), 6);
    expect(oldMapPackFolder(docs).existsSync(), isFalse);
    expect(oldMapPackFolder(support).existsSync(), isFalse);
    expect(await removeOldMapPackFiles([support, docs]), 0);
  });
}
