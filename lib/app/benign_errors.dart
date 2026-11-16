// Errors the app knows are harmless and must not count as crashes (Q3 run, Nov 15 2026).
//
// vector_map_tiles loads tiles through executor_lib; when a map is disposed while tiles are still loading (leaving the
// region repeater page, a tab switch) the executor completes the queued jobs with its `CancellationException`
// (`_IsolateExecutor._completeCancelled`, toString "Cancelled") and nothing awaits them, so it surfaces as an uncaught
// async error. [installBenignErrorFilter] drops exactly that and hands every other error to the handler that was there
// before (or Flutter's default reporting).

import 'package:flutter/foundation.dart';

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

bool _installed = false;

/// Installs the filter on [PlatformDispatcher.instance.onError] (uncaught async errors) and [FlutterError.onError] (errors
/// Flutter reports). Each forwards what is not benign to the previous handler. Safe to call more than once.
void installBenignErrorFilter() {
  if (_installed) return;
  _installed = true;
  final prevPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    if (isBenignTileCancel(error, stack)) return true;
    if (prevPlatform != null) return prevPlatform(error, stack);
    FlutterError.presentError(FlutterErrorDetails(exception: error, stack: stack, library: 'meshsonar'));
    return true;
  };
  final prevFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    if (isBenignTileCancel(details.exception, details.stack)) return;
    (prevFlutter ?? FlutterError.presentError)(details);
  };
}
