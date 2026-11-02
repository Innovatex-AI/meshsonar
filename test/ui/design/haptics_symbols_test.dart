import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/platform/accessibility_channel.dart';
import 'package:meshsonar/ui/design/app_haptics.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/design/app_symbols.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppHaptics', () {
    final calls = <String>[];
    setUp(() {
      calls.clear();
      AppHaptics.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'HapticFeedback.vibrate') calls.add('sys:${c.arguments}');
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.meshsonar/haptics'), (c) async {
        calls.add('${c.method}:${c.arguments}');
        return null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.meshsonar/haptics'), null);
    });

    test('success / warning / error use the notification channel', () async {
      await AppHaptics.success();
      await AppHaptics.warning();
      await AppHaptics.error();
      expect(calls, ['notify:success', 'notify:warning', 'notify:error']);
    });

    test('selection and light use the system generators', () async {
      await AppHaptics.selection();
      await AppHaptics.light();
      expect(calls, ['sys:HapticFeedbackType.selectionClick', 'sys:HapticFeedbackType.lightImpact']);
    });

    test('soft is rate limited to once per 3 seconds', () async {
      var t = DateTime(2026, 11, 2, 12);
      AppHaptics.now = () => t;
      await AppHaptics.soft();
      t = t.add(const Duration(seconds: 2));
      await AppHaptics.soft();
      t = t.add(const Duration(seconds: 2));
      await AppHaptics.soft();
      expect(calls.where((c) => c == 'impact:soft').length, 2);
    });

    test('the Haptics setting off silences everything', () async {
      AppHaptics.enabled = false;
      await AppHaptics.selection();
      await AppHaptics.success();
      await AppHaptics.soft();
      expect(calls, isEmpty);
    });

    test('a missing channel (Android, desktop) falls back to system haptics', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.meshsonar/haptics'), null);
      await AppHaptics.error();
      expect(calls.where((c) => c.startsWith('sys:')), isNotEmpty);
    });
  });

  test('Settings.haptics defaults on, is written only when off, and round-trips', () {
    const s = Settings();
    expect(s.haptics, isTrue);
    expect(s.toJson().containsKey('haptics'), isFalse);
    final off = s.copyWith(haptics: false);
    expect(off.toJson()['haptics'], false);
    expect(Settings.fromJson(off.toJson()).haptics, isFalse);
    expect(Settings.fromJson(const {}).haptics, isTrue);
  });

  testWidgets('Blur.opaque: opaque when Reduce Transparency is on or unknown, translucent only when it reports off', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    AccessibilitySignals.reduceTransparency = null;
    expect(Blur.opaque(ctx), isTrue);
    AccessibilitySignals.reduceTransparency = true;
    expect(Blur.opaque(ctx), isTrue);
    AccessibilitySignals.reduceTransparency = false;
    expect(Blur.opaque(ctx), isFalse);
    AccessibilitySignals.reduceTransparency = null;
  });

  group('AppSymbols', () {
    test('every symbol is unique and listed in the manifest, and the manifest lists nothing else', () {
      final manifest = File('lib/ui/design/symbols_manifest.md').readAsStringSync();
      final inManifest = RegExp(r'^\| `(\w+)` \| `([^`]+)`', multiLine: true).allMatches(manifest).map((m) => m.group(2)!).toList();
      final names = AppSymbols.all.map((s) => s.sfName).toList();
      expect(names.toSet().length, names.length, reason: 'unique SF names');
      expect(inManifest.toSet(), names.toSet());
    });

    test('every constant is in AppSymbols.all', () {
      final src = File('lib/ui/design/app_symbols.dart').readAsStringSync();
      final declared = RegExp(r'static const \w+ = AppSymbol\(').allMatches(src).length;
      expect(AppSymbols.all.length, declared);
    });

    testWidgets('Apple platforms get the Cupertino glyph, Android the Material glyph', (tester) async {
      Future<IconData?> glyph(TargetPlatform p) async {
        await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: p), home: const AppSymbolIcon(AppSymbols.car)));
        await tester.pumpAndSettle();
        return tester.widget<Icon>(find.byType(Icon)).icon;
      }

      expect(await glyph(TargetPlatform.iOS), AppSymbols.car.apple);
      expect(await glyph(TargetPlatform.android), AppSymbols.car.material);
    });
  });
}
