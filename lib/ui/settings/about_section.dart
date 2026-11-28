// Settings > About: version and licences, the map legend and the terms. The intro again is in More > Help (build 77: one
// place; a search for it still finds it there).
import 'package:flutter/material.dart';

import '../about_screen.dart';
import '../app.dart';
import '../map/legend_sheet.dart' show showMapLegend;
import 'privacy_section.dart' show termsOfServiceRow;
import 'settings_index.dart';
import 'settings_kit.dart';

List<Widget> aboutSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  return [
    SettingsAnchor(
      id: 'about',
      child: ListTile(
        key: const Key('about'),
        leading: const Icon(Icons.info_outline),
        title: Text(settingsEntry('about').title),
        subtitle: Text(s.services.appInfo.version == null ? 'Version unknown' : 'Version ${s.services.appInfo.version}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
      ),
    ),
    SettingsAnchor(
      id: 'map-legend',
      child: ListTile(
        key: const Key('map-legend'),
        leading: const Icon(Icons.legend_toggle_rounded),
        title: Text(settingsEntry('map-legend').title),
        subtitle: const Text('What the colours and symbols on the maps mean.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showMapLegend(context),
      ),
    ),
    termsOfServiceRow(context),
  ];
}
