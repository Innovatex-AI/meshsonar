// The Group sheet as the iPad side panel at 1024 pt wide (build 67 sim tour, the one iPad-width shot): groups page and a
// group's people, rendered with the system SF font. Writes PNGs only when MT_SHOTS=<dir> is set:
//   MT_SHOTS=/tmp/shots flutter test test/ui/meshtrack/ipad_side_panel_shot_test.dart
// Without it the layout checks still run (side panel, 420 pt on the right, the map side free, no overflow).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/meshtrack/group_sheet.dart';

import 'mt_kit.dart';

const _sf = '/System/Library/Fonts/SFNS.ttf';

Future<void> _loadSystemFont() async {
  final f = File(_sf);
  if (!f.existsSync()) return;
  final bytes = ByteData.sublistView(f.readAsBytesSync());
  // The families the app's text resolves to in a test (Material default, the Cupertino system names, AppType display).
  for (final family in ['Roboto', 'CupertinoSystemText', 'CupertinoSystemDisplay', '.SF Pro Text', '.SF Pro Display', '.SF UI Text']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
  // The symbols (AppSymbolIcon draws CupertinoIcons on Apple platforms): the cupertino_icons package font.
  final config = File('.dart_tool/package_config.json');
  if (config.existsSync()) {
    final pkgs = (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    final ci = pkgs.cast<Map>().where((p) => p['name'] == 'cupertino_icons').firstOrNull;
    if (ci != null) {
      final root = Uri.parse(ci['rootUri'] as String);
      final dir = root.isAbsolute ? root.toFilePath() : File('.dart_tool/${root.path}').absolute.path;
      final font = File('$dir/assets/CupertinoIcons.ttf');
      if (font.existsSync()) {
        await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())))).load();
      }
    }
  }
}

void main() {
  final out = Platform.environment['MT_SHOTS'];

  testWidgets('iPad 1024 pt: the Group sheet is a 420 pt side panel on the right, groups and people', (tester) async {
    tester.view.physicalSize = const Size(1024 * 2, 768 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    if (out != null) {
      await tester.runAsync(_loadSystemFont);
      WidgetsApp.debugAllowBannerOverride = false;
      addTearDown(() => WidgetsApp.debugAllowBannerOverride = true);
    }

    final rig = MtRig();
    rig.ops.introSeen = true;
    rig.svc
      ..addGroup(1, 'Saturday crew')
      ..addGroup(2, 'Family')
      ..setRadioConnected(true)
      ..driveStarted()
      ..setShare(1, true);
    rig.fix();
    rig.hear(1, 'Sam KD8SAM', speed: 47, pathLen: 1, snr: 5.5);
    rig.hear(1, 'Jo N8JO', dLat: -0.012, dLon: -0.02, speed: 40, pathLen: 2, snr: -1.5);

    final shot = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: shot,
      child: rig.host(Opener((c) => showGroupSheet(c))),
    ));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    final panel = find.byKey(const Key('mt-side-panel'));
    expect(panel, findsOneWidget);
    expect(tester.getSize(panel).width, 420);
    expect(tester.getTopRight(panel).dx, 1024, reason: 'on the right edge; the map stays visible on the left');
    expect(tester.takeException(), isNull);

    Future<void> save(String name) async {
      if (out == null) return;
      await tester.runAsync(() async {
        final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio: 2);
        final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        Directory(out).createSync(recursive: true);
        File('$out/$name.png').writeAsBytesSync(png);
      });
    }

    await save('mt-ipad-01-side-panel-groups');
    await tester.tap(find.byKey(const Key('mt-open-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mt-people')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await save('mt-ipad-02-side-panel-people');
    await rig.done(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
