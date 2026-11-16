// Errors the app knows are harmless and must not count as crashes (Q3 run, Nov 15 2026).
//
// vector_map_tiles loads tiles through executor_lib; when a map is disposed while tiles are still loading (leaving the
// region repeater page, a tab switch) the executor completes the queued jobs with its `CancellationException`
// (`_IsolateExecutor._completeCancelled`, toString "Cancelled") and nothing awaits them, so it surfaces as an uncaught
// async error. [installBenignErrorFilter] drops exactly that and hands every other error to the handler that was there
// before (or Flutter's default reporting).
//
// sensors_plus on a phone with no barometer (or Motion & Fitness refused, or the iOS simulator): the plugin's onListen
// answers PlatformException(UNAVAILABLE, "Barometer is not available on this device") and Flutter's EventChannel reports
// it through FlutterError.reportError instead of handing it to the stream (V-5, build 67: it failed the screen tour as
// soon as a drive really started). The drive treats a silent barometer as unavailable (SensorsPlusBarometer's silence
// timeout), so this report is expected and dropped too.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

/// True only for the tile loader's cancellation: executor_lib's `CancellationException` (matched by its type name and its
/// "Cancelled" text, since executor_lib is not a direct dependency), or a "Cancelled" error thrown from the tile or executor
/// code. Anything else is not benign.
bool isBenignTileCancel(Object error, [StackTrace? stack]) {
  final text = error.toString();
  if (text != 'Cancelled') return false;
  if (error.runtimeType.toString() == 'CancellationException') return true;
  final s = stack?.toString() ?? '';
  return s.contains('package:executor_lib/') || s.contains('package:vector_map_tiles/');
}

/// True only for sensors_plus's "no barometer" answer: a PlatformException with code UNAVAILABLE about the barometer.
bool isBenignNoBarometer(Object error) =>
    error is PlatformException && error.code == 'UNAVAILABLE' && (error.message ?? '').toLowerCase().contains('barometer');

bool _installed = false;

/// Installs the filter on [PlatformDispatcher.instance.onError] (uncaught async errors) and [FlutterError.onError] (errors
/// Flutter reports). Each forwards what is not benign to the previous handler. Safe to call more than once.
void installBenignErrorFilter() {
  if (_installed) return;
  _installed = true;
  final prevPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    if (isBenignTileCancel(error, stack) || isBenignNoBarometer(error)) return true;
    if (prevPlatform != null) return prevPlatform(error, stack);
    FlutterError.presentError(FlutterErrorDetails(exception: error, stack: stack, library: 'meshsonar'));
    return true;
  };
  final prevFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    if (isBenignTileCancel(details.exception, details.stack) || isBenignNoBarometer(details.exception)) return;
    (prevFlutter ?? FlutterError.presentError)(details);
  };
}
