// Widget-test rig for the Tools screens: a fake ToolsHost around a REAL RadioTools over the simulated radio, the real
// theme, and the checks every screen must pass (phone and tablet, text at 2.5x, dark, tap targets, no overflow, semantics).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show RadioPreset;
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/tools/rx_log.dart' show KnownChannel;
import 'package:meshsonar/ui/theme.dart';
import 'package:meshsonar/ui/tools/tool_kit.dart';
import 'package:meshsonar/ui/tools/tools_host.dart';

import 'tools_rig.dart';

class FakeToolsHost extends ChangeNotifier implements ToolsHost {
  RadioTools? toolsValue;
  @override
  LinkState linkState = LinkState.connected;
  @override
  String? radioName = 'Test Radio';
  @override
  bool driveRecording = false;
  @override
  RadioPreset? regionPreset = const RadioPreset(name: 'MeshCore US Recommended', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);
  @override
  String? regionName = 'Columbus';
  @override
  Uri? regionSite = Uri.parse('https://cmh.meshsonar.com');
  @override
  List<String> scopeNames = const ['#cmh'];
  List<KnownChannel> channels = const [];
  ({double lat, double lon})? phone = (lat: 40.1258, lon: -82.9312);
  @override
  ({double lat, double lon})? lastPosition = (lat: 40.1258, lon: -82.9312);
  final openedUrls = <Uri>[];
  int stopDriveCalls = 0;
  int connectOpened = 0;

  @override
  RadioTools? get tools => toolsValue;
  @override
  Future<void> stopDrive() async {
    stopDriveCalls++;
    driveRecording = false;
    notifyListeners();
  }

  @override
  Future<List<KnownChannel>> knownChannels() async => channels;
  @override
  Future<({double lat, double lon})?> phonePosition() async => phone;
  @override
  Future<void> openUrl(Uri url) async => openedUrls.add(url);
  @override
  void openConnect(BuildContext context) => connectOpened++;

  void setTools(RadioTools? t, {LinkState? state}) {
    toolsValue = t;
    if (state != null) linkState = state;
    notifyListeners();
  }
}

/// Screen sizes the Tools are tested at.
enum Device {
  iphone(390, 844, 3.0),
  iphoneSmall(320, 568, 2.0),
  ipad(820, 1180, 2.0);

  final double w, h, dpr;
  const Device(this.w, this.h, this.dpr);
}

/// Pumps [screen] in the real theme with [host] above it. Call before the first pump of the screen.
Future<void> pumpTool(
  WidgetTester tester,
  Widget screen,
  FakeToolsHost host, {
  Device device = Device.iphone,
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(device.w * device.dpr, device.h * device.dpr);
  tester.view.devicePixelRatio = device.dpr;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  ToolMap.tilesEnabled = false;
  addTearDown(() => ToolMap.tilesEnabled = true);
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(brightness),
    home: ToolsHostScope(host: host, child: screen),
  ));
  await tester.pump();
}

/// Lets real-time work (the simulated radio's timers, the tools' waits) happen inside a widget test. Pumping alone does not
/// advance real time, so this awaits real delays and then pumps.
Future<void> settleReal(WidgetTester tester, {Duration real = const Duration(milliseconds: 400)}) async {
  await tester.runAsync(() => Future<void>.delayed(real));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Builds the rig and a host connected to it, inside runAsync (the simulated radio uses real timers).
Future<(ToolsRig, FakeToolsHost)> connectedRig(WidgetTester tester, {bool ambient = false, int? noiseFloorDbm = -112}) async {
  final rig = (await tester.runAsync(() => ToolsRig.start(ambient: ambient, noiseFloorDbm: noiseFloorDbm)))!;
  addTearDown(() async {
    await tester.runAsync(() => rig.close());
  });
  final host = FakeToolsHost()..toolsValue = rig.tools;
  addTearDown(host.dispose);
  return (rig, host);
}

/// Every enabled button, icon button and list row is at least 48 x 48 logical px.
void expectTapTargets(WidgetTester tester, {int minimum = 48}) {
  final small = <String>[];
  final f = find.byWidgetPredicate((w) => w is ButtonStyleButton || w is IconButton || w is ListTile || w is SwitchListTile || w is CheckboxListTile);
  for (final e in f.evaluate()) {
    final w = e.widget;
    final enabled = switch (w) {
      ButtonStyleButton() => w.enabled,
      IconButton() => w.onPressed != null,
      ListTile() => w.onTap != null,
      SwitchListTile() => w.onChanged != null,
      CheckboxListTile() => w.onChanged != null,
      _ => true,
    };
    if (!enabled) continue;
    final size = tester.getSize(find.byElementPredicate((x) => identical(x, e)));
    if (size.height < minimum - 0.5 || size.width < minimum - 0.5) small.add('${w.runtimeType} ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}');
  }
  expect(small, isEmpty, reason: 'tap targets under $minimum px');
}

/// Runs [body] for a screen at phone, small phone and tablet, light and dark, and 2.5x text: any overflow or exception fails.
/// [open] builds the screen fresh each time.
Future<void> forEachLook(
  WidgetTester tester,
  Widget Function() open,
  FakeToolsHost Function() hostFor,
  Future<void> Function(WidgetTester tester) body,
) async {
  for (final look in <({Device d, double scale, Brightness b})>[
    (d: Device.iphone, scale: 1.0, b: Brightness.light),
    (d: Device.iphone, scale: 2.5, b: Brightness.dark),
    (d: Device.iphoneSmall, scale: 2.5, b: Brightness.light),
    (d: Device.ipad, scale: 1.0, b: Brightness.dark),
  ]) {
    await pumpTool(tester, open(), hostFor(), device: look.d, textScale: look.scale, brightness: look.b);
    await body(tester);
    expect(tester.takeException(), isNull, reason: 'overflow at ${look.d.name} x${look.scale} ${look.b.name}');
  }
}
