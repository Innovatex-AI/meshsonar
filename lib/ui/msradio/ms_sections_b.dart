// Builder B's sections: map pack, firmware, Lua apps, radio screen and sounds, owner link, RF tools.
// The owner link shows only while the server advertises radio proof: the screen renders nothing otherwise, and the page can
// ask [msBOwnerAvailable] (needs a BuildContext under AppScope) to leave its row out.
import 'package:flutter/widgets.dart';

import '../../core/msradio/msradio.dart';
import 'ms_b_firmware_screen.dart';
import 'ms_b_lua_apps_screen.dart';
import 'ms_b_map_pack_screen.dart';
import 'ms_b_owner_screen.dart';
import 'ms_b_rf_tools_screen.dart';
import 'ms_b_screen_sounds_screen.dart';
import 'ms_sections.dart';

export 'ms_b_owner_screen.dart' show msBOwnerAvailable;

Widget? msSectionScreenB(MsSection s, MsRadioController c) => switch (s) {
      MsSection.mapPack => MsBMapPackScreen(c: c),
      MsSection.firmware => MsBFirmwareScreen(c: c),
      MsSection.luaApps => MsBLuaAppsScreen(c: c),
      MsSection.screenSounds => MsBScreenSoundsScreen(c: c),
      MsSection.owner => MsBOwnerScreen(c: c),
      MsSection.rfTools => MsBRfToolsScreen(c: c),
      _ => null,
    };
