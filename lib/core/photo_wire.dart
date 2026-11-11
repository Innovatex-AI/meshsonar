// The socket under a photo upload (photo-upload, contract v1). The old path pushed every chunk of the body into
// package:http's StreamedRequest sink at once, so the bar said 100% while nothing had left the phone and a fixed 120 s
// timeout then fired on a slow uplink (~14 KB/s, a 1 MB JPEG). This seam writes one chunk at a time and completes each write
// only when the OS has taken it, so the caller can report real progress and time out on a stall instead of on a total.
// [IoPhotoWire] is the phone's (dart:io HttpClient); tests use a fake (test/support/photo_fakes.dart). Pure Dart.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The server's answer: status, headers (lower-case names, values joined by ", ") and the whole body.
class PhotoWireResponse {
  final int status;
  final Map<String, String> headers;
  final List<int> body;
  const PhotoWireResponse(this.status, this.body, {this.headers = const {}});
}

/// One request in flight.
abstract class PhotoWireRequest {
  /// Hands [chunk] to the network; completes once the OS socket has accepted it (not when it is merely buffered here).
  Future<void> write(List<int> chunk);

  /// The body is complete: waits for the answer.
  Future<PhotoWireResponse> finish();

  /// Drops the connection; a pending [write] or [finish] then fails.
  void abort();
}

abstract class PhotoWire {
  /// Connects and sends the request head. Throws on DNS / connect / TLS failure.
  Future<PhotoWireRequest> open(String method, Uri url, Map<String, String> headers, int contentLength);
}

/// dart:io HttpClient, one client per upload (closed when the answer is read or the request is aborted).
class IoPhotoWire implements PhotoWire {
  final Duration connectTimeout;
  const IoPhotoWire({this.connectTimeout = const Duration(seconds: 30)});

  @override
  Future<PhotoWireRequest> open(String method, Uri url, Map<String, String> headers, int contentLength) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final req = await client.openUrl(method, url);
      // Unbuffered: each add goes straight to the socket, and flush waits for the socket to take it.
      req.bufferOutput = false;
      req.persistentConnection = false;
      headers.forEach(req.headers.set);
      req.contentLength = contentLength;
      return _IoRequest(client, req);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

class _IoRequest implements PhotoWireRequest {
  final HttpClient _client;
  final HttpClientRequest _req;
  _IoRequest(this._client, this._req);

  @override
  Future<void> write(List<int> chunk) async {
    _req.add(chunk);
    await _req.flush();
  }

  @override
  Future<PhotoWireResponse> finish() async {
    try {
      final res = await _req.close();
      final b = BytesBuilder(copy: false);
      await for (final part in res) {
        b.add(part);
      }
      final h = <String, String>{};
      res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(', '));
      return PhotoWireResponse(res.statusCode, b.takeBytes(), headers: h);
    } finally {
      _client.close();
    }
  }

  @override
  void abort() {
    _req.abort();
    _client.close(force: true);
  }
}
