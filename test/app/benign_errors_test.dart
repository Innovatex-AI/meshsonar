// The tile loader's cancellation (vector_map_tiles / executor_lib "Cancelled") is dropped; every other error still goes on.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/benign_errors.dart';

/// Stands in for executor_lib's exception (same type name and text).
class CancellationException implements Exception {
  @override
  String toString() => 'Cancelled';
}

class _OtherCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

void main() {
  test('only the tile loader cancellation is benign', () {
    expect(isBenignTileCancel(CancellationException()), isTrue);
    expect(isBenignTileCancel(_OtherCancelled(), StackTrace.fromString('#0 _IsolateExecutor._completeCancelled (package:executor_lib/src/isolate_executor.dart:108:24)')), isTrue);
    expect(isBenignTileCancel(_OtherCancelled(), StackTrace.fromString('#0 foo (package:vector_map_tiles/src/tile.dart:1:1)')), isTrue);
    expect(isBenignTileCancel(_OtherCancelled(), StackTrace.fromString('#0 foo (package:meshsonar/x.dart:1:1)')), isFalse, reason: 'some other "Cancelled"');
    expect(isBenignTileCancel(_OtherCancelled()), isFalse);
    expect(isBenignTileCancel(StateError('Cancelled tiles')), isFalse);
    expect(isBenignTileCancel(Exception('boom')), isFalse);
    expect(isBenignTileCancel(const FormatException('Cancelled')), isFalse);
  });

  test('only sensors_plus "no barometer" is benign among platform exceptions', () {
    expect(isBenignNoBarometer(PlatformException(code: 'UNAVAILABLE', message: 'Barometer is not available on this device')), isTrue);
    expect(isBenignNoBarometer(PlatformException(code: 'UNAVAILABLE', message: 'Bluetooth is off')), isFalse);
    expect(isBenignNoBarometer(PlatformException(code: 'ERROR', message: 'Barometer failed')), isFalse);
    expect(isBenignNoBarometer(Exception('Barometer is not available')), isFalse);
  });

  test('the installed filter drops the cancel and forwards everything else to the previous handlers', () {
    final oldPlatform = PlatformDispatcher.instance.onError;
    final oldFlutter = FlutterError.onError;
    final platformSeen = <Object>[];
    final flutterSeen = <Object>[];
    PlatformDispatcher.instance.onError = (e, s) {
      platformSeen.add(e);
      return false;
    };
    FlutterError.onError = (d) => flutterSeen.add(d.exception);
    try {
      installBenignErrorFilter();
      installBenignErrorFilter(); // twice is the same as once
      final onError = PlatformDispatcher.instance.onError!;
      expect(onError(CancellationException(), StackTrace.empty), isTrue);
      expect(platformSeen, isEmpty);
      final boom = StateError('boom');
      expect(onError(boom, StackTrace.empty), isFalse, reason: 'the previous handler decides');
      expect(platformSeen, [boom]);

      FlutterError.onError!(FlutterErrorDetails(exception: CancellationException()));
      expect(flutterSeen, isEmpty);
      FlutterError.onError!(FlutterErrorDetails(exception: PlatformException(code: 'UNAVAILABLE', message: 'Barometer is not available on this device')));
      expect(flutterSeen, isEmpty, reason: 'the no-barometer report is dropped');
      FlutterError.onError!(FlutterErrorDetails(exception: boom));
      expect(flutterSeen, [boom]);
    } finally {
      PlatformDispatcher.instance.onError = oldPlatform;
      FlutterError.onError = oldFlutter;
    }
  });
}
