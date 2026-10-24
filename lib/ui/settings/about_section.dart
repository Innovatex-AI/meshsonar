// Settings > About: version and licences, and the welcome tour again.
import 'package:flutter/material.dart';

import '../about_screen.dart';
import '../app.dart';
import '../onboarding/onboarding_screen.dart';
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
        subtitle: Text('Version ${s.services.appInfo.version ?? ''} · MIT licence'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
      ),
    ),
    SettingsAnchor(
      id: 'show-intro',
      child: ListTile(
        key: const Key('show-intro'),
        leading: const Icon(Icons.auto_awesome_outlined),
        title: Text(settingsEntry('show-intro').title),
        subtitle: const Text('The intro pages from first launch. Changes nothing.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (ctx) => OnboardingScreen(onFinish: (_) => Navigator.of(ctx).pop()),
        )),
      ),
    ),
  ];
}
