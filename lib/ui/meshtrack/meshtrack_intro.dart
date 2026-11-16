// The MeshTrack intro (plan section 7): a disclosure shown the first time sharing is turned on, never again after
// "Got it". Closing it any other way keeps Share off and asks again next time.
import 'package:flutter/cupertino.dart';

import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/sheet_detents.dart' show formSheetDetents;
import '../design/tokens.dart';
import 'meshtrack_binding.dart';
import 'meshtrack_copy.dart';

/// True when sharing may go ahead: the intro was accepted before, or "Got it" was pressed now.
Future<bool> ensureMeshTrackIntro(BuildContext context, MeshTrackGroupOps ops) async {
  if (ops.introSeen) return true;
  final ok = await showAppSheet<bool>(
    context,
    detents: formSheetDetents(context),
    builder: (ctx, scroll) => MeshTrackIntro(controller: scroll),
  );
  if (ok != true) return false;
  await ops.setIntroSeen();
  return true;
}

class MeshTrackIntro extends StatelessWidget {
  final ScrollController controller;
  const MeshTrackIntro({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppSheetScaffold(
      key: const Key('mt-intro'),
      controller: controller,
      primaryAction: CupertinoButton.filled(
        key: const Key('mt-intro-ok'),
        minimumSize: const Size.square(kMtHit),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Got it'),
      ),
      secondaryAction: CupertinoButton(
        key: const Key('mt-intro-not-now'),
        minimumSize: const Size.square(kMtHit),
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Not now'),
      ),
      children: [
        const SizedBox(height: Gap.m),
        Center(child: AppSymbolIcon(AppSymbols.person2Fill, size: 40, color: c.accent)),
        const SizedBox(height: Gap.m),
        Semantics(
          header: true,
          child: Text(mtIntroTitle, key: const Key('mt-intro-title'), textAlign: TextAlign.center, style: AppType.title2.copyWith(color: c.textPrimary)),
        ),
        const SizedBox(height: Gap.m),
        Text(mtIntroBody, key: const Key('mt-intro-body'), style: AppType.body.copyWith(color: c.textPrimary)),
        const SizedBox(height: Gap.l),
      ],
    );
  }
}
