// AC-12, static half (spec m1-app-0.4.0 §5): every http(s) host written in lib/ is on the allow-list, and only the
// two HTTP clients (CMAT client, public node map) create an HTTP client. The dynamic half is hosts_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/server_url.dart';
import 'package:path/path.dart' as p;

/// The MeshSonar server's addresses (0.5.0: the default https://meshsonar.com plus the aliases in
/// lib/core/server_url.dart, kept equal to [sameServerHosts] by the test below), the public node map, and
/// OpenStreetMap tiles.
const allowedServerHosts = {'meshsonar.com', 'cmh.meshsonar.com', 'cmh-meshcore.lovable.app'};
const allowedLiteralHosts = {...allowedServerHosts, 'map.meshcore.io', 'tile.openstreetmap.org'};

void main() {
  test('the allow-list matches the alias set, and the default server is one of them', () {
    expect(allowedServerHosts, sameServerHosts);
    expect(retiredServerHosts.difference(sameServerHosts), isEmpty);
    expect(sameServerHosts, contains(Uri.parse(defaultServerUrl).host));
  });

  test('every http(s) host in lib/ is allowed; only cmat_client, repeater_directory and region_repeaters_api make HTTP clients', () {
    final hostRe = RegExp(r'''https?://([A-Za-z0-9.-]+)''');
    final clientRe = RegExp(r'''http\.Client\(|HttpClient\(|IOClient\(|http\.(get|post|put|patch|delete|head|read|readBytes)\(''');
    final hosts = <String, String>{};
    final clients = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in hostRe.allMatches(src)) {
        hosts[m.group(1)!.toLowerCase()] = f.path;
      }
      if (clientRe.hasMatch(src)) clients.add(p.basename(f.path));
    }
    expect(hosts.keys, containsAll(['map.meshcore.io', 'tile.openstreetmap.org']), reason: 'the scan itself works');
    final unknown = {for (final e in hosts.entries) if (!allowedLiteralHosts.contains(e.key)) e.key: e.value};
    expect(unknown, isEmpty, reason: 'a new host in lib/ needs a spec decision (MeshSonar sends only to its server)');
    expect(clients.difference({'cmat_client.dart', 'repeater_directory.dart', 'region_repeaters_api.dart', 'region_overview_api.dart', 'region_reports_api.dart'}), isEmpty);
    expect(hosts.keys.where((h) => h.contains('meshmapper')), isEmpty);
  });

  test('no setting or code path names MeshMapper as a destination', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final code = f
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n')
          .toLowerCase();
      expect(code.contains('also_send') || code.contains('alsosend'), isFalse, reason: f.path);
      expect(RegExp(r'meshmapper[a-z_]*(url|endpoint|upload|send)').hasMatch(code), isFalse, reason: f.path);
    }
  });
}
