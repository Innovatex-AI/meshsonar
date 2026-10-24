// Settings > Map & offline maps: download region maps for use with no signal (the packs screen does the work).
import 'package:flutter/material.dart';

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
    ];
