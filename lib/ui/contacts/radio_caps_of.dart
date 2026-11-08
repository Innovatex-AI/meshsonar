import 'package:flutter/widgets.dart' show BuildContext;

import '../../radio/caps.dart';
import '../../radio/companion_link.dart' show MeshCoreCompanionLink;
import '../app.dart' show AppScope;

/// What the connected radio's firmware can do (DEVICE_INFO, remembered path-discovery refusal), or the baseline when no
/// radio is connected or the app has no radio session (tests).
RadioCaps radioCapsOf(BuildContext context) {
  final link = AppScope.maybeOf(context)?.radioSessions.link;
  return link is MeshCoreCompanionLink ? link.radioCaps : RadioCaps.baseline;
}
