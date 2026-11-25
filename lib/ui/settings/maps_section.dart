// Settings > Map: how the map follows you (heading-up, zoom out at speed).
import 'package:flutter/material.dart';

import '../../core/map_prefs.dart';

import 'settings_kit.dart';

const String mapsHelp = 'How the map follows you.';

List<Widget> mapsSectionRows(BuildContext context) => [
      SettingsAnchor(id: 'map-follow-options', child: const MapFollowOptions()),
    ];

/// The follow choices (remembered on this phone, MapPrefs): the Drive tab's heading-up button changes the same setting.
class MapFollowOptions extends StatelessWidget {
  const MapFollowOptions({super.key});

  @override
  Widget build(BuildContext context) {
    final p = MapPrefs.shared;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => Column(
        key: const Key('map-follow-options'),
        children: [
          SwitchListTile(
            key: const Key('map-heading-up-setting'),
            secondary: const Icon(Icons.navigation_outlined),
            title: const Text('Heading-up map'),
            subtitle: const Text('The way you are driving is up. Off: north is up.'),
            value: p.headingUp,
            onChanged: (v) => p.headingUp = v,
          ),
          SwitchListTile(
            key: const Key('map-zoom-speed-setting'),
            secondary: const Icon(Icons.zoom_out_map_outlined),
            title: const Text('Zoom out at speed'),
            subtitle: const Text('Shows more road on the highway.'),
            value: p.zoomBySpeed,
            onChanged: (v) => p.zoomBySpeed = v,
          ),
        ],
      ),
    );
  }
}
