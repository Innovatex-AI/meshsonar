// The tile loader's cancellation (vector_map_tiles / executor_lib "Cancelled") is dropped; every other error still goes on.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/app/benign_errors.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebResourceError, WebResourceErrorType;

/// Stands in for webview_flutter_wkwebview's NSError (fields `domain` and `code`).
class _NSError {
  final String domain;
  final int code;
  const _NSError(this.domain, this.code);
}

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

  final uri = Uri.parse('https://cmh.meshsonar.com/v1/packets');

  test('http: a request on a closed client is benign (the real package:http error)', () async {
    final c = http.Client()..close();
    Object? got;
    try {
      await c.get(uri);
    } catch (e) {
      got = e;
    }
    expect(got, isA<http.ClientException>());
    expect(isBenignHttpCancel(got!), isTrue);
    expect(isBenignHttpCancel(http.ClientException('HTTP request failed. Client is already closed.', uri)), isTrue);
  });

  test('http: an aborted request is benign', () {
    expect(isBenignHttpCancel(http.RequestAbortedException(uri)), isTrue);
  });

  test('http: a connection closed under a request is benign, as ClientException and as dart:io HttpException', () {
    expect(isBenignHttpCancel(http.ClientException('Connection closed before full header was received', uri)), isTrue);
    expect(isBenignHttpCancel(http.ClientException('Connection closed while receiving data', uri)), isTrue);
    expect(isBenignHttpCancel(HttpException('Connection closed before full header was received', uri: uri)), isTrue);
    expect(isBenignHttpCancel(const HttpException('Connection closed while receiving data')), isTrue);
  });

  test('http: real failures are not benign', () {
    expect(isBenignHttpCancel(http.ClientException('Failed host lookup: cmh.meshsonar.com', uri)), isFalse);
    expect(isBenignHttpCancel(http.ClientException('Connection reset by peer', uri)), isFalse);
    expect(isBenignHttpCancel(http.ClientException('Connection refused', uri)), isFalse);
    expect(isBenignHttpCancel(const HttpException('Invalid response line')), isFalse);
    expect(isBenignHttpCancel(const SocketException('Failed host lookup')), isFalse);
    expect(isBenignHttpCancel(const HandshakeException('bad certificate')), isFalse);
    expect(isBenignHttpCancel(TimeoutException('v1')), isFalse);
    expect(isBenignHttpCancel(StateError('HTTP request failed. Client is already closed.')), isFalse);
    expect(isBenignHttpCancel(Exception('Connection closed while receiving data')), isFalse);
  });

  test('webview: a cancelled load on iOS (NSURLErrorCancelled -999) is benign', () {
    expect(isBenignWebViewCancel(const WebResourceError(errorCode: -999, description: 'cancelled')), isTrue);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', details: const _NSError('NSURLErrorDomain', -999))), isTrue);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', details: const {'domain': 'NSURLErrorDomain', 'code': -999})), isTrue);
  });

  test('webview: an aborted load on Android (net::ERR_ABORTED) is benign', () {
    expect(isBenignWebViewCancel(const WebResourceError(errorCode: -1, description: 'net::ERR_ABORTED', errorType: WebResourceErrorType.unknown)), isTrue);
  });

  test('webview: real load failures are not benign', () {
    expect(isBenignWebViewCancel(const WebResourceError(errorCode: -1009, description: 'The Internet connection appears to be offline.')), isFalse);
    expect(isBenignWebViewCancel(const WebResourceError(errorCode: -1003, description: 'A server with the specified hostname could not be found.')), isFalse);
    expect(isBenignWebViewCancel(const WebResourceError(errorCode: -2, description: 'net::ERR_INTERNET_DISCONNECTED', errorType: WebResourceErrorType.hostLookup)), isFalse);
    expect(isBenignWebViewCancel(const WebResourceError(errorCode: -6, description: 'net::ERR_CONNECTION_REFUSED', errorType: WebResourceErrorType.connect)), isFalse);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', details: const _NSError('NSURLErrorDomain', -1009))), isFalse);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', details: const _NSError('WKErrorDomain', -999))), isFalse);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', details: const {'domain': 'NSURLErrorDomain', 'code': -1001})), isFalse);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', message: 'cancelled', details: 'NSURLErrorDomain -999')), isFalse);
    expect(isBenignWebViewCancel(PlatformException(code: 'error', details: Object())), isFalse);
    expect(isBenignWebViewCancel(PlatformException(code: '-999')), isFalse);
    expect(isBenignWebViewCancel(Exception('cancelled')), isFalse);
  });

  test('isBenignError is the union and nothing more', () {
    expect(isBenignError(CancellationException()), isTrue);
    expect(isBenignError(PlatformException(code: 'UNAVAILABLE', message: 'Barometer is not available on this device')), isTrue);
    expect(isBenignError(http.RequestAbortedException()), isTrue);
    expect(isBenignError(const WebResourceError(errorCode: -999, description: 'cancelled')), isTrue);
    expect(isBenignError(StateError('boom')), isFalse);
    expect(isBenignError(const SocketException('Connection refused')), isFalse);
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

      // Build 71: network cancellations are dropped on both handlers; a real network failure still goes on.
      final closed = http.ClientException('HTTP request failed. Client is already closed.', uri);
      const cancelledLoad = WebResourceError(errorCode: -999, description: 'cancelled');
      expect(onError(closed, StackTrace.empty), isTrue);
      expect(onError(cancelledLoad, StackTrace.empty), isTrue);
      expect(platformSeen, [boom]);
      FlutterError.onError!(FlutterErrorDetails(exception: closed));
      FlutterError.onError!(FlutterErrorDetails(exception: cancelledLoad));
      expect(flutterSeen, [boom]);
      const offline = SocketException('Failed host lookup');
      expect(onError(offline, StackTrace.empty), isFalse);
      FlutterError.onError!(FlutterErrorDetails(exception: offline));
      expect(platformSeen, [boom, offline]);
      expect(flutterSeen, [boom, offline]);
    } finally {
      PlatformDispatcher.instance.onError = oldPlatform;
      FlutterError.onError = oldFlutter;
    }
  });
}
