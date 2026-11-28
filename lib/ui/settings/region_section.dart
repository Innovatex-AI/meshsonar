// Settings > Region: which region the app shows, and which region the server answers for.
import 'package:flutter/material.dart';

import '../app.dart';
import '../region/region_switcher.dart';
import 'settings_kit.dart';

/// Account > Server (advanced): which region the server answers for. The row exists only once
/// `GET /api/cmh/site-config` has answered; a slow or failing fetch leaves it out and nothing else is affected.
/// Build 77 (round 5 S6): the radio preset comparison is no longer repeated here; it is in My radio's settings
/// (lib/ui/radio/radio_screen.dart), with the region's preset, its source and the "no preset" reason.
List<Widget> serverRegionRows(BuildContext context) {
  final s = AppScope.of(context);
  return [
    if (s.siteConfig != null) const SettingsAnchor(id: 'site-region', child: RegionTile()),
  ];
}

/// Which region the current server URL resolves to (`GET /api/cmh/site-config`). Only built once that answer has
/// arrived (see regionSectionRows) — a slow or failing fetch simply leaves this tile out, the
/// Server URL tile above it is unaffected either way.
class RegionTile extends StatelessWidget {
  const RegionTile({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final region = s.siteConfig!.region;
    // No human-readable region name exists on the wire; the host is the recognisable part.
    final host = Uri.tryParse(region.url)?.host ?? region.url;
    return ListTile(
      key: const Key('site-region'),
      leading: const Icon(Icons.public),
      title: const Text('Connected to'),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(host),
        if (s.viewingTimezone != null) Text('Time zone of ${s.viewingRegion?.name ?? 'this region'}: ${s.viewingTimezone}', key: const Key('site-region-timezone')),
      ]),
    );
  }
}

/// Which region the app is viewing; opens the switcher.
class RegionPickTile extends StatelessWidget {
  const RegionPickTile({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.viewingRegion;
    return ListTile(
      key: const Key('region-pick'),
      leading: const Icon(Icons.map_outlined),
      title: const Text('Region'),
      subtitle: Text(v == null
          ? 'Loading the region list…'
          : '${v.name} (${v.code}) · ${s.viewingIsManual ? 'picked by you' : 'follows your location'}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showRegionSwitcher(context),
    );
  }
}

