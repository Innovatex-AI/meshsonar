// The sections of the MeshSonar radio page (build 78). Two builders own the screens: [msSectionScreenA] (pairing,
// overview, sharing, log, paired apps) and [msSectionScreenB] (map pack, firmware, Lua apps, radio screen and sounds,
// owner link, RF tools). The page asks A, then B.
import 'package:flutter/widgets.dart';

import '../../core/msradio/msradio.dart';
import 'ms_sections_a.dart';
import 'ms_sections_b.dart';

enum MsSection { pairing, overview, sharing, log, mapPack, firmware, luaApps, screenSounds, owner, rfTools, pairedApps }

/// The screen for [s], or null when it is not built yet.
Widget? msSectionScreen(MsSection s, MsRadioController c) => msSectionScreenA(s, c) ?? msSectionScreenB(s, c);
