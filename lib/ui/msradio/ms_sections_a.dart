// Builder A's sections (build 78): pairing, overview, sharing and wardrive, log and backlog, apps paired with this radio.
import 'package:flutter/widgets.dart';

import '../../core/msradio/msradio.dart';
import 'ms_log_screen.dart';
import 'ms_overview_screen.dart';
import 'ms_paired_apps_screen.dart';
import 'ms_pairing_screen.dart';
import 'ms_sections.dart';
import 'ms_sharing_screen.dart';

Widget? msSectionScreenA(MsSection s, MsRadioController c) => switch (s) {
      MsSection.pairing => MsPairingScreen(c),
      MsSection.overview => MsOverviewScreen(c),
      MsSection.sharing => MsSharingScreen(c),
      MsSection.log => MsLogScreen(c),
      MsSection.pairedApps => MsPairedAppsScreen(c),
      _ => null,
    };
