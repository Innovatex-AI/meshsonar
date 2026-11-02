// Settings > Map & offline maps: download region maps for use with no signal (the packs screen does the work).
import 'package:flutter/material.dart';

import '../../core/map_prefs.dart';

import 'offline_packs_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String mapsHelp = 'The map loads tiles over the network as you look around. An offline map keeps one region on '
    'this phone so the map still draws with no signal.';

List<Widget> mapsSectionRows(BuildContext context) => [
      SettingsAnchor(
        id: 'offline-maps',
        child: ListTile(
          key: const Key('offline-maps'),
          leading: const Icon(Icons.map_outlined),
          title: Text(settingsEntry('offline-maps').title),
          subtitle: const Text('Download a region so the map works with no signal. Each map uses storage; delete it '
              'any time on that screen.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OfflinePacksScreen())),
        ),
      ),
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
            key: const Key('map-auto-recenter-setting'),
            secondary: const Icon(Icons.my_location_outlined),
            title: const Text('Re-centre by itself'),
            subtitle: const Text('After you move the map while driving, it returns to you 10 seconds after you let go. Off: tap the '
                're-centre button.'),
            value: p.autoResumeSec > 0,
            onChanged: (v) => p.autoResumeSec = v ? 10 : 0,
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
