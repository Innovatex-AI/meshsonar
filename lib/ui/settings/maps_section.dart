// Settings > Map: how the map follows you (heading-up, zoom out at speed).
import 'package:flutter/material.dart';

import '../../core/map_prefs.dart';

import 'settings_kit.dart';

const String mapsHelp = 'The map loads over the network as you look around. Places you have looked at are kept on this '
    'phone for a while, so they still draw with a weak signal.';

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
            subtitle: const Text('The map turns so the way you are driving is up. Off keeps north at the top.'),
            value: p.headingUp,
            onChanged: (v) => p.headingUp = v,
          ),
          SwitchListTile(
            key: const Key('map-zoom-speed-setting'),
            secondary: const Icon(Icons.zoom_out_map_outlined),
            title: const Text('Zoom out at speed'),
            subtitle: const Text('Eases the map out a little on the highway so more road shows. Off keeps the zoom you set.'),
            value: p.zoomBySpeed,
            onChanged: (v) => p.zoomBySpeed = v,
          ),
        ],
      ),
    );
  }
}
