import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/drive_guard.dart';
import 'package:meshsonar/ui/theme.dart';

/// A MaterialApp with the app theme on [platform] and a button row that runs [onTap] callbacks.
Widget designApp({
  required Widget Function(BuildContext) home,
  TargetPlatform platform = TargetPlatform.iOS,
  Brightness brightness = Brightness.light,
  Size? size,
  double textScale = 1.0,
}) {
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: meshSonarTheme(brightness).copyWith(platform: platform),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: Builder(builder: home)),
  );
  return app;
}

void resetDesignGlobals() {
  DriveGuard.instance.reset();
}

Future<void> setSize(WidgetTester tester, Size s) async {
  tester.view.physicalSize = s;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
