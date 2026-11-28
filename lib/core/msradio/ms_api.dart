// The MeshSonar radio local app API client (meshsonar-firmware docs/APP-INTEGRATION.md sections 2-4):
// `http://<radio>/api/app/v1/...`, port 80, plain HTTP on the local network, JSON replies.
//   - `X-MS: 1` on every POST; `Authorization: Bearer <token>` on authorised calls and on the upload routes.
//   - 4 s per call (uploads and the log download get longer), ONE request at a time per radio (the radio's web server is
//     single-threaded: [MsSerialQueue]), a 503 is retried once after 1 s.
//   - Errors are [MsRadioError] with the radio's own `error` text. A 401 drops the token ([onUnauthorized]): pair again.
// The token is never logged and never part of an error or toString. Nothing read here is sent to MeshSonar servers by the
// app. Pure Dart (package:http), no Flutter.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ms_errors.dart';
import 'ms_models.dart';

/// The ONE place lib/core/msradio makes an HTTP client (test/integration/hosts_static_test.dart). It only ever talks to
/// the address discovery confirmed as the connected radio (its `/info` key equals the Bluetooth key): a local address
/// found at run time, never a host written in the code.
http.Client msRadioHttp() => http.Client();

/// The API prefix on the radio.
const String kMsApiPrefix = '/api/app/v1';

/// One request at a time for one radio. Calls queue in order; a failed call does not block the next.
class MsSerialQueue {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// Calls waiting or running.
  int get pending => _pending;

  Future<T> run<T>(Future<T> Function() job) {
    _pending++;
    final done = Completer<T>();
    final prev = _tail;
    _tail = done.future.then<void>((_) {}, onError: (_) {});
    prev.whenComplete(() async {
      try {
        done.complete(await job());
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        _pending--;
      }
    });
    return done.future;
  }
}

/// A file to upload: its name, size and a way to open its bytes (opened again when a 503 is retried).
class MsUploadSource {
  final String name;
  final int size;
  final Stream<List<int>> Function() open;
  const MsUploadSource({required this.name, required this.size, required this.open});

  /// From bytes in memory (tests, small files such as `main.lua`).
  factory MsUploadSource.bytes(String name, List<int> bytes) =>
      MsUploadSource(name: name, size: bytes.length, open: () => Stream<List<int>>.value(bytes));
}

/// (bytes sent or received so far, total bytes or null when unknown).
typedef MsProgress = void Function(int done, int? total);

/// The client for ONE radio at [baseUrl] (`http://<radio ip>` or `http://<meshsonar-xxxxxxxx>.local`, from discovery).
class MsRadioApi {
  final Uri baseUrl;
  final http.Client _client;

  /// The pairing token (32 hex), or null before pairing. Cleared on a 401.
  String? token;

  /// Called after a 401 dropped [token] (the controller deletes the stored token and offers pairing again).
  void Function()? onUnauthorized;

  final Duration timeout;
  final Duration uploadTimeout;
  final Duration downloadTimeout;

  /// The wait before the one retry of a 503.
  final Duration busyRetryAfter;
  final Future<void> Function(Duration d) _wait;
  final MsSerialQueue queue;

  MsRadioApi({
    required this.baseUrl,
    this.token,
    http.Client? client,
    MsSerialQueue? queue,
    this.onUnauthorized,
    this.timeout = const Duration(seconds: 4),
    this.uploadTimeout = const Duration(minutes: 10),
    this.downloadTimeout = const Duration(minutes: 2),
    this.busyRetryAfter = const Duration(seconds: 1),
    Future<void> Function(Duration d)? wait,
  })  : _client = client ?? msRadioHttp(),
        queue = queue ?? MsSerialQueue(),
        _wait = wait ?? Future<void>.delayed;

  /// `http://<address>` for an address as the person or discovery gives it: an IPv4 address, `[v6]`, a bare IPv6 address,
  /// a host name, each optionally with `:port` (an `http://` prefix is accepted). Null when it cannot be an address.
  static Uri? baseFor(String address) {
    var a = address.trim();
    if (a.isEmpty) return null;
    if (a.startsWith('http://')) a = a.substring(7);
    if (a.endsWith('/')) a = a.substring(0, a.length - 1);
    if (a.isEmpty || a.contains('/') || a.contains(' ') || a.contains('@')) return null;
    // a bare IPv6 address (more than one ':' and no brackets)
    if (!a.startsWith('[') && ':'.allMatches(a).length > 1) a = '[$a]';
    final u = Uri.tryParse('http://$a');
    if (u == null || u.host.isEmpty) return null;
    return Uri(scheme: 'http', host: u.host, port: u.hasPort ? u.port : 80);
  }

  bool get isPaired => token != null;

  Uri _url(String path, [Map<String, String>? query]) => baseUrl.replace(path: path, queryParameters: query == null || query.isEmpty ? null : query);
  Uri _api(String path, [Map<String, String>? query]) => _url('$kMsApiPrefix$path', query);

  // ---------------------------------------------------------------- transport
  Map<String, String> _headers({required bool post, required bool auth}) => {
        'Accept': 'application/json',
        if (post) 'X-MS': '1',
        if (auth && token != null) 'Authorization': 'Bearer $token',
      };

  static String _fmt(Object v) => v is bool ? (v ? 'true' : 'false') : '$v';

  /// Runs [once] in the queue with the 503 retry; [once] maps transport failures itself.
  Future<T> _queued<T>(Future<T> Function() once) => queue.run(() async {
        try {
          return await once();
        } on MsRadioError catch (e) {
          if (e.kind != MsErrorKind.busy) rethrow;
          await _wait(busyRetryAfter);
          return await once();
        }
      });

  /// Sends [build]'s request with a deadline of [limit]; returns status and body bytes. Throws [MsRadioError] for
  /// a timeout or a network failure.
  Future<(int, Uint8List, Map<String, String>)> _send(http.BaseRequest Function(Future<void> abort) build, Duration limit,
      {MsProgress? onReceive}) async {
    final abort = Completer<void>();
    Future<(int, Uint8List, Map<String, String>)> go() async {
      final resp = await _client.send(build(abort.future));
      final total = resp.contentLength;
      final b = BytesBuilder(copy: false);
      await for (final chunk in resp.stream) {
        b.add(chunk);
        onReceive?.call(b.length, total);
      }
      return (resp.statusCode, b.takeBytes(), resp.headers);
    }

    try {
      return await go().timeout(limit);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw MsRadioError(MsErrorKind.timeout, MsRadioError.defaultMessage(MsErrorKind.timeout));
    } on MsRadioError {
      rethrow;
    } on http.ClientException {
      // IOClient wraps socket and HTTP failures (no route, refused, host not found) in ClientException
      throw MsRadioError(MsErrorKind.notOnWifi, MsRadioError.defaultMessage(MsErrorKind.notOnWifi));
    }
  }

  /// Maps a non-2xx status to an error (and drops the token on 401).
  MsRadioError _errorFor(int status, Uint8List body) {
    String? text;
    try {
      final j = jsonDecode(utf8.decode(body, allowMalformed: true));
      if (j is Map && j['error'] is String) text = j['error'] as String;
    } catch (_) {
      final t = utf8.decode(body, allowMalformed: true).trim();
      // a plain-text refusal (upload routes); never an HTML page
      if (t.isNotEmpty && !t.startsWith('<')) text = t;
    }
    final e = MsRadioError.fromStatus(status, text);
    if (status == 401) {
      token = null;
      onUnauthorized?.call();
    }
    return e;
  }

  Future<Map<String, dynamic>> _json(String method, String path,
      {Map<String, Object?>? fields, Map<String, String>? query, bool auth = true}) {
    final post = method == 'POST';
    return _queued(() async {
      final (status, body, _) = await _send((abort) {
        final r = http.AbortableRequest(method, _api(path, query), abortTrigger: abort)..headers.addAll(_headers(post: post, auth: auth));
        if (post) {
          r.bodyFields = {
            for (final e in (fields ?? const <String, Object?>{}).entries)
              if (e.value != null) e.key: _fmt(e.value!),
          };
        }
        return r;
      }, timeout);
      if (status < 200 || status > 299) throw _errorFor(status, body);
      final Object? j;
      try {
        j = jsonDecode(utf8.decode(body));
      } catch (_) {
        throw MsRadioError(MsErrorKind.badReply, MsRadioError.defaultMessage(MsErrorKind.badReply), status: status);
      }
      final m = msObject(j);
      if (m == null) throw MsRadioError(MsErrorKind.badReply, MsRadioError.defaultMessage(MsErrorKind.badReply), status: status);
      return m;
    });
  }

  Future<T> _parsed<T>(Future<Map<String, dynamic>> reply, T Function(Map<String, dynamic>) parse) async {
    final j = await reply;
    try {
      return parse(j);
    } on FormatException {
      throw MsRadioError(MsErrorKind.badReply, MsRadioError.defaultMessage(MsErrorKind.badReply));
    }
  }

  Future<T> _get<T>(String path, T Function(Map<String, dynamic>) parse, {Map<String, String>? query, bool auth = true}) =>
      _parsed(_json('GET', path, query: query, auth: auth), parse);

  Future<T> _post<T>(String path, T Function(Map<String, dynamic>) parse, {Map<String, Object?>? fields, bool auth = true}) =>
      _parsed(_json('POST', path, fields: fields, auth: auth), parse);

  /// A multipart upload of [src] as field [field] to the root route [path] (`/maps`, `/apps/upload`, `/update`), with the
  /// Bearer token and progress as the body is sent.
  Future<MsUploadResult> _upload(String path, MsUploadSource src, {Map<String, String>? query, String field = 'file', MsProgress? onProgress}) {
    return _queued(() async {
      final boundary = 'ms-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${math.Random().nextInt(1 << 31).toRadixString(16)}';
      final safeName = src.name.replaceAll(RegExp(r'["\r\n\\]'), '_');
      final head = utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="$field"; filename="$safeName"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n');
      final tail = utf8.encode('\r\n--$boundary--\r\n');
      final total = head.length + src.size + tail.length;
      final (status, body, _) = await _send((abort) {
        final r = http.AbortableStreamedRequest('POST', _url(path, query), abortTrigger: abort)
          ..headers.addAll(_headers(post: true, auth: true))
          ..headers['Content-Type'] = 'multipart/form-data; boundary=$boundary'
          ..contentLength = total;
        () async {
          var sent = 0;
          try {
            r.sink.add(head);
            sent += head.length;
            onProgress?.call(0, src.size);
            await r.sink.addStream(src.open().map((c) {
              sent += c.length;
              onProgress?.call(sent - head.length, src.size);
              return c;
            }));
            r.sink.add(tail);
          } catch (e) {
            r.sink.addError(e);
          } finally {
            await r.sink.close();
          }
        }();
        return r;
      }, uploadTimeout);
      final text = utf8.decode(body, allowMalformed: true).trim();
      if (status < 200 || status > 299) throw _errorFor(status, body);
      return MsUploadResult(status, text);
    });
  }

  // ---------------------------------------------------------------- identity (open)
  /// `GET /` (the API index), as the radio sends it.
  Future<Map<String, dynamic>> index() => _json('GET', '', auth: false);

  /// `GET /info`. Sends the token when there is one, so [MsInfo.paired] tells whether it is still good.
  Future<MsInfo> info() => _get('/info', MsInfo.parse);

  // ---------------------------------------------------------------- pairing (open)
  /// `POST /pair/start`. [appNonce] must come from MsAppNonces.issue (lib/core/person_identity.dart).
  Future<MsPairStart> pairStart({required String appNonce, required String app}) =>
      _post('/pair/start', MsPairStart.parse, fields: {'app_nonce': appNonce, 'app': app}, auth: false);

  /// `POST /pair/finish` with the radio's signature (128 hex) over the pairing text.
  Future<MsPairToken> pairFinish({required String nonce, required String sigHex, required String app}) =>
      _post('/pair/finish', MsPairToken.parse, fields: {'nonce': nonce, 'sig': sigHex, 'app': app}, auth: false);

  /// `POST /pair/ask`: the radio asks the person to Allow this app (60 s).
  Future<MsPairAsk> pairAsk({required String app}) => _post('/pair/ask', MsPairAsk.parse, fields: {'app': app}, auth: false);

  /// `GET /pair/ask?n=`.
  Future<MsPairAskResult> pairAskResult(String n) => _get('/pair/ask', MsPairAskResult.parse, query: {'n': n}, auth: false);

  /// `POST /unpair`: drops this app's own token on the radio.
  Future<MsActionResult> unpair() => _post('/unpair', MsActionResult.parse);

  /// `GET /tokens`: the apps paired with this radio.
  Future<MsTokens> tokens() => _get('/tokens', MsTokens.parse);

  /// `POST /tokens/revoke i=<i>`.
  Future<MsActionResult> revokeToken(int i) => _post('/tokens/revoke', MsActionResult.parse, fields: {'i': i});

  /// `POST /tokens/revoke i=all` (this app's token too).
  Future<MsActionResult> revokeAllTokens() => _post('/tokens/revoke', MsActionResult.parse, fields: {'i': 'all'});

  // ---------------------------------------------------------------- status and uplink
  Future<MsStatus> status() => _get('/status', MsStatus.parse);

  Future<MsUplink> uplink() => _get('/uplink', MsUplink.parse);

  /// `POST /uplink` with the given switches; returns the new state. `wardrive` and the backlog need `capture` on.
  Future<MsUplink> setUplink({bool? capture, bool? share, bool? wardrive, String? iata}) {
    if (iata != null && !RegExp(r'^[A-Za-z0-9]{3}$').hasMatch(iata)) {
      throw const MsRadioError(MsErrorKind.badRequest, 'The IATA code is 3 letters or digits.');
    }
    return _post('/uplink', MsUplink.parse, fields: {'capture': capture, 'share': share, 'wardrive': wardrive, 'iata': iata?.toUpperCase()});
  }

  // ---------------------------------------------------------------- log, probes
  Future<MsLog> log() => _get('/log', MsLog.parse);

  /// `GET /log/records`: one decoded page (at most 100 records). Continue with `off: page.next` while [MsLogPage.hasMore].
  Future<MsLogPage> logRecords({MsLogWhich which = MsLogWhich.current, int off = 0, int limit = 50, MsRecordKind? kind}) => _get(
        '/log/records',
        MsLogPage.parse,
        query: {
          'which': which.name,
          'off': '$off',
          'limit': '${limit.clamp(1, 100)}',
          if (kind != null && kind != MsRecordKind.unknown) 'kind': kind.name,
        },
      );

  /// `GET /log/file`: the raw log file (`application/octet-stream`, at most about 1.2 MB). The current file grows while it
  /// is read; a record cut at the end is incomplete.
  Future<Uint8List> logFile(MsLogWhich which, {MsProgress? onProgress}) => _queued(() async {
        final (status, body, _) = await _send(
            (abort) => http.AbortableRequest('GET', _api('/log/file', {'which': which.name}), abortTrigger: abort)
              ..headers.addAll(_headers(post: false, auth: true)),
            downloadTimeout,
            onReceive: onProgress);
        if (status < 200 || status > 299) throw _errorFor(status, body);
        return body;
      });

  /// `GET /probes` (newest first, at most 40).
  Future<MsProbes> probes({int limit = 20}) => _get('/probes', MsProbes.parse, query: {'limit': '${limit.clamp(1, 40)}'});

  /// `POST /probe/now`; read `/probes` about 10 s later (20 s with a repeater ping). 409 with the reason when one runs.
  Future<MsProbeStart> probeNow() => _post('/probe/now', MsProbeStart.parse);

  // ---------------------------------------------------------------- map pack
  Future<MsMaps> maps() => _get('/maps', MsMaps.parse);

  /// `POST /maps?size=<bytes>` (multipart field `file`): an `.msmp` pack (starts with `MSMP`, must fit the partition).
  /// [onProgress] counts the bytes sent; the radio's own progress is in `status.maps`.
  Future<MsUploadResult> uploadMapPack(MsUploadSource src, {MsProgress? onProgress}) =>
      _upload('/maps', src, query: {'size': '${src.size}'}, onProgress: onProgress);

  // ---------------------------------------------------------------- Lua apps
  Future<MsApps> apps() => _get('/apps', MsApps.parse);

  /// Loads the catalog; poll [apps] until `catalog.state` is ok.
  Future<MsActionResult> loadCatalog() => _post('/apps/catalog', MsActionResult.parse);

  /// Installs [id] from the catalog; poll [apps] (`installing`, `install_note`).
  Future<MsActionResult> installApp(String id) => _post('/apps/install', MsActionResult.parse, fields: {'id': id});

  /// Opens [id] on the radio's screen.
  Future<MsActionResult> runApp(String id) => _post('/apps/run', MsActionResult.parse, fields: {'id': id});

  Future<MsActionResult> stopApp() => _post('/apps/stop', MsActionResult.parse);

  Future<MsActionResult> removeApp(String id) => _post('/apps/remove', MsActionResult.parse, fields: {'id': id});

  /// `POST /apps/upload?id=&name=&version=&icon=&desc=&http=&mem=&size=` with `main.lua` (32 KB max) as field `file`.
  Future<MsUploadResult> uploadApp(
    MsUploadSource mainLua, {
    required String id,
    required String name,
    String version = '1.0.0',
    String icon = '',
    String desc = '',
    bool internet = false,
    int memoryKb = 64,
    MsProgress? onProgress,
  }) {
    if (mainLua.size > 32 * 1024) throw const MsRadioError(MsErrorKind.badRequest, 'main.lua can be at most 32 KB.');
    return _upload(
      '/apps/upload',
      mainLua,
      query: {
        'id': id,
        'name': name,
        'version': version,
        'icon': icon,
        'desc': desc,
        'http': internet ? '1' : '0',
        'mem': '$memoryKb',
        'size': '${mainLua.size}',
      },
      onProgress: onProgress,
    );
  }

  // ---------------------------------------------------------------- firmware
  Future<MsOta> ota() => _get('/ota', MsOta.parse);

  /// Checks the feed; poll [ota].
  Future<MsActionResult> otaCheck() => _post('/ota/check', MsActionResult.parse);

  /// The radio downloads the offer over Wi-Fi into the other slot and asks on its screen to restart.
  Future<MsActionResult> otaInstall({bool force = false}) => _post('/ota/install', MsActionResult.parse, fields: {if (force) 'force': true});

  Future<MsActionResult> otaChannel({required bool beta}) => _post('/ota/channel', MsActionResult.parse, fields: {'beta': beta});

  Future<MsActionResult> otaAuto({required bool on}) => _post('/ota/auto', MsActionResult.parse, fields: {'on': on});

  /// Restarts the radio (ask the person to confirm first).
  Future<MsActionResult> otaRestart() => _post('/ota/restart', MsActionResult.parse, fields: {'confirm': 'yes'});

  /// `POST /update` with a `meshsonar-<board>-<version>.bin` file as field `file`; the radio checks it is for its board,
  /// then restarts into it (rolled back when it does not run for 60 s).
  Future<MsUploadResult> uploadFirmware(MsUploadSource bin, {MsProgress? onProgress}) => _upload('/update', bin, onProgress: onProgress);

  // ---------------------------------------------------------------- settings and lock
  Future<MsSettings> settings() => _get('/settings', MsSettings.parse);

  /// `POST /settings` with any of the values; returns the new settings. An out-of-range value changes nothing (400).
  /// [quietStart] and [quietEnd] go together.
  Future<MsSettings> setSettings({
    String? name,
    int? brightness,
    int? screenTimeoutMs,
    bool? buzzerFitted,
    int? volume,
    bool? flash,
    int? events,
    bool? quietOn,
    int? quietStart,
    int? quietEnd,
  }) {
    if ((quietStart == null) != (quietEnd == null)) {
      throw const MsRadioError(MsErrorKind.badRequest, 'Quiet hours need both a start and an end.');
    }
    return _post('/settings', MsSettings.parse, fields: {
      'name': name,
      'brightness': brightness,
      'screen_timeout_ms': screenTimeoutMs,
      'buzzer_fitted': buzzerFitted,
      'volume': volume,
      'flash': flash,
      'events': events,
      'quiet_on': quietOn,
      'quiet_start': quietStart,
      'quiet_end': quietEnd,
    });
  }

  /// Locks the radio's screen now (needs a PIN set).
  Future<MsActionResult> lockNow() => _post('/lock', MsActionResult.parse, fields: {'action': 'lock_now'});

  /// Sets a PIN (4-8 digits; only when none is set). The PIN is only sent, never kept.
  Future<MsActionResult> setPin(String pin) {
    _checkPin(pin);
    return _post('/lock', MsActionResult.parse, fields: {'action': 'set', 'pin': pin});
  }

  /// Removes the PIN. Five wrong PINs block this for 5 minutes (429).
  Future<MsActionResult> clearPin(String pin) {
    _checkPin(pin);
    return _post('/lock', MsActionResult.parse, fields: {'action': 'clear', 'pin': pin});
  }

  static void _checkPin(String pin) {
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) throw const MsRadioError(MsErrorKind.badRequest, 'The PIN is 4 to 8 digits.');
  }

  // ---------------------------------------------------------------- owner link
  Future<MsOwner> owner() => _get('/owner', MsOwner.parse);

  /// Names the radio [ownerKey] (64 hex, not this radio's own key) as this radio's owner; returns the new state.
  Future<MsOwner> setOwner({required String ownerKey, String name = ''}) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(ownerKey)) throw const MsRadioError(MsErrorKind.badRequest, 'That is not a radio key.');
    return _post('/owner', MsOwner.parse, fields: {'key': ownerKey.toLowerCase(), 'name': name});
  }

  Future<MsOwner> clearOwner() => _post('/owner/clear', MsOwner.parse);

  // ---------------------------------------------------------------- spectrum
  Future<MsSpectrum> spectrum() => _get('/spectrum', MsSpectrum.parse);

  /// Starts a scan from [f0] to [f1] MHz (150-960) in [step] MHz steps (at most 1024) for [seconds] (5-600). Mesh receive
  /// pauses in bursts of at most about 12 ms; the radio never transmits for it.
  Future<MsActionResult> spectrumStart({double f0 = 902, double f1 = 928, double step = 0.2, int seconds = 15}) =>
      _post('/spectrum/start', MsActionResult.parse, fields: {'f0': f0, 'f1': f1, 'step': step, 'seconds': seconds});

  Future<MsActionResult> spectrumStop() => _post('/spectrum/stop', MsActionResult.parse);

  /// Closes the HTTP client (only when this API made it or owns it).
  void close() => _client.close();
}
