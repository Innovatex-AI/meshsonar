// About: what MeshSonar is, its MIT licence, and third-party notices.
import 'package:flutter/material.dart';

import '../core/api.dart' show openMeteoCredit;
import '../core/server_url.dart' show privacyPolicyUrl;
import 'app.dart';

const String mitLicenseText = '''MIT License

Copyright (c) 2026 MeshSonar contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';

/// Short credits for projects MeshSonar builds on. Full texts: THIRD_PARTY_NOTICES.md in the source.
const List<({String name, String license, String note})> thirdPartyNotices = [
  (
    name: 'MeshCore Open',
    license: 'MIT, © 2025 zjs81',
    note: 'Where MeshSonar adapts code from this project, the source file says so.',
  ),
  (
    name: 'MeshMapper web client',
    license: 'MIT, © 2025 MrAlders0n',
    note: 'Where MeshSonar adapts code from this project, the source file says so.',
  ),
  (name: 'Flutter', license: 'BSD-3-Clause, © The Flutter Authors', note: 'App framework.'),
  (name: 'flutter_blue_plus', license: 'FlutterBluePlus License (free for personal, nonprofit and educational use; for-profit use needs a paid licence)', note: 'Bluetooth LE. MeshSonar is a noncommercial community project.'),
  (name: 'MeshCore firmware', license: 'MIT, © Scott Powell / rippleradios.com', note: 'Companion protocol and packet formats, re-implemented in Dart.'),
  (name: 'geolocator', license: 'MIT, © Baseflow', note: 'GPS.'),
  (name: 'share_plus, path_provider', license: 'BSD-3-Clause, © Flutter Community / The Flutter Authors', note: 'Sharing and file locations.'),
  (name: 'http, path, uuid', license: 'BSD-3-Clause / MIT', note: 'Networking and utilities.'),
  (name: 'pdf', license: 'Apache-2.0, © David PHAM-VAN', note: 'Drive and region reports as PDF (made on the phone).'),
  (
    name: 'Open-Meteo',
    license: 'Data under CC BY 4.0. Its free service is for non-commercial use.',
    note: openMeteoCredit,
  ),
];

/// Credits that link out: the notice name -> the page its credit line opens.
final Map<String, Uri> thirdPartyNoticeLinks = {'Open-Meteo': Uri.parse('https://open-meteo.com')};

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About MeshSonar')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('MeshSonar ${s.services.appInfo.version ?? ''}', style: t.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'Open-source MeshCore wardriving. MeshSonar pings a channel from your companion radio, listens for '
              'repeaters that echo it, and records every ping with GPS. Drives are saved on this phone first, '
              'can be exported as files, and upload to any server that speaks the MeshSonar Drive Format.',
            ),
            const SizedBox(height: 16),
            ListTile(
              key: const Key('about-privacy-policy'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.policy_outlined),
              title: const Text('Privacy policy'),
              subtitle: const Text(privacyPolicyUrl),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => s.services.openUrl(Uri.parse(privacyPolicyUrl)),
            ),
            const SizedBox(height: 8),
            Text('Licence', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(mitLicenseText, key: const Key('mit-license'), style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
            const SizedBox(height: 16),
            Text('Third-party notices', style: t.textTheme.titleMedium),
            for (final n in thirdPartyNotices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                key: Key('notice-${n.name}'),
                title: Text(n.name),
                subtitle: Text('${n.license}\n${n.note}'),
                isThreeLine: true,
                trailing: thirdPartyNoticeLinks[n.name] == null ? null : const Icon(Icons.open_in_new, size: 18),
                onTap: thirdPartyNoticeLinks[n.name] == null ? null : () => s.services.openUrl(thirdPartyNoticeLinks[n.name]!),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('show-licenses'),
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'MeshSonar',
                applicationVersion: s.services.appInfo.version,
                applicationLegalese: 'MIT License. See THIRD_PARTY_NOTICES.md for adapted code.',
              ),
              icon: const Icon(Icons.description),
              label: const Text('All package licences'),
            ),
          ],
        ),
      ),
    );
  }
}
