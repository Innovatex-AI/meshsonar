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
//
// Build 71 (Network on `/v1`, site pages in a webview): two more cancellations that are not faults.
//  - package:http when a screen closes its `/v1` client (or the live stream is torn down) with a request still in
//    flight, or aborts it: ClientException "HTTP request failed. Client is already closed.", RequestAbortedException,
//    and dart:io's "Connection closed ..." HttpException (IOClient re-throws it as a ClientException with the same text).
//    The API classes turn these into an offline state where they await the call; this only covers the ones nobody awaits.
//  - A webview load that was cancelled (the user left the page, or a new load replaced it): NSURLErrorCancelled
//    (NSURLErrorDomain -999) on iOS / macOS, net::ERR_ABORTED on Android.
// Real failures stay reported: DNS, refused or reset connections, TLS, timeouts, HTTP status errors, other webview codes.

import 'dart:io' show HttpException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart' show WebResourceError;

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

/// True only for an HTTP request that ended because OUR side stopped it: the client was closed before or while the
/// request ran, or the request was aborted. Never true for a failure to reach the server (SocketException, TLS, timeout).
bool isBenignHttpCancel(Object error) {
  if (error is http.RequestAbortedException) return true;
  final String message;
  if (error is http.ClientException) {
    message = error.message;
  } else if (error is HttpException) {
    message = error.message;
  } else {
    return false;
  }
  // IOClient.send on a closed client; then dart:io _HttpClientConnection / _HttpIncoming when the socket is closed under
  // a request ("Connection closed before full header was received", "Connection closed while receiving data").
  return message == 'HTTP request failed. Client is already closed.' || message.startsWith('Connection closed ');
}

/// NSURLErrorCancelled: the code WebKit gives a load that was cancelled.
const int _nsUrlErrorCancelled = -999;

/// True only for a cancelled webview load: a [WebResourceError] with NSURLErrorCancelled (-999; Android's codes stop at
/// -16) or Chromium's net::ERR_ABORTED, or a [PlatformException] whose details are an NSError-like object or map with
/// domain NSURLErrorDomain and code -999. Every other webview error (no connection, host lookup, TLS, ...) is real.
bool isBenignWebViewCancel(Object error) {
  if (error is WebResourceError) {
    return error.errorCode == _nsUrlErrorCancelled || error.description.contains('net::ERR_ABORTED');
  }
  if (error is! PlatformException) return false;
  final Object? d = error.details;
  Object? domain, code;
  if (d is Map) {
    domain = d['domain'];
    code = d['code'];
  } else if (d != null && d is! String && d is! num && d is! bool && d is! List) {
    // webview_flutter_wkwebview hands over its NSError (fields `domain` and `code`); it is not a direct dependency.
    try {
      domain = (d as dynamic).domain;
      code = (d as dynamic).code;
    } catch (_) {
      return false;
    }
  }
  return domain == 'NSURLErrorDomain' && code == _nsUrlErrorCancelled;
}

/// Every harmless error the filter drops.
bool isBenignError(Object error, [StackTrace? stack]) =>
    isBenignTileCancel(error, stack) || isBenignNoBarometer(error) || isBenignHttpCancel(error) || isBenignWebViewCancel(error);

bool _installed = false;

/// Installs the filter on [PlatformDispatcher.instance.onError] (uncaught async errors) and [FlutterError.onError] (errors
/// Flutter reports). Each forwards what is not benign to the previous handler. Safe to call more than once.
void installBenignErrorFilter() {
  if (_installed) return;
  _installed = true;
  final prevPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    if (isBenignError(error, stack)) return true;
    if (prevPlatform != null) return prevPlatform(error, stack);
    FlutterError.presentError(FlutterErrorDetails(exception: error, stack: stack, library: 'meshsonar'));
    return true;
  };
  final prevFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    if (isBenignError(details.exception, details.stack)) return;
    (prevFlutter ?? FlutterError.presentError)(details);
  };
}
