// Drive Format v1.2 wire shapes for the drive context (stream 7 WP5), written against the live server contract:
// meshcore-insights docs/MESHSONAR_DRIVE_FORMAT.md "v1.2" and src/lib/drive/context.ts.
//
//   ContextUpload       what rides with a drive-upload request when the server accepts meshsonar.drive.v1.2:
//                       session.device, the companion extras, session.enrich.weather, per-ping `ctx`, `samples`.
//   DriveContextBatch   the late-context body of `POST /api/cmh/drive-context` (meshsonar.drive-context.v1).
//
// The server is STRICT: an unknown key inside ctx / a sample / device / companion / enrich is rejected, and a bad
// device / companion / enrich fails the whole request. So everything is re-checked here on the way out, in the
// server's own terms (charsets, os, lengths), and local-only keys (`ble_rssi`) never leave the phone. A value the
// server would refuse is left out; the rest is still sent.
//
// Pure Dart: no Flutter imports.
import 'drive_context.dart';

/// The `format` id of the late-context body.
const String driveContextFormat = 'meshsonar.drive-context.v1';

/// Samples per request (the server rejects the request above this).
const int maxSamplesPerUpload = 2000;

final RegExp _modelRe = RegExp(r'^[A-Za-z0-9 ,._-]+$');
final RegExp _versionishRe = RegExp(r'^[A-Za-z0-9 ,._:+-]+$');

bool _text(String? v, int max, RegExp re) => v != null && v.isNotEmpty && v.length <= max && re.hasMatch(v);

/// `session.device` for the wire, or null (nothing to send). Only `ios` / `android` are valid `os` values on the
/// server, so a desktop build sends no device at all rather than a half-truth.
Map<String, dynamic>? wireDevice(DeviceDetails? d) {
  if (d == null || (d.os != 'ios' && d.os != 'android')) return null;
  final out = <String, dynamic>{
    'os': d.os,
    if (_text(d.osVersion, 20, _versionishRe)) 'os_version': d.osVersion,
    if (_text(d.model, 40, _modelRe)) 'model': d.model,
    if (_text(d.appBuild, 10, _versionishRe)) 'app_build': d.appBuild,
  };
  return out;
}

/// The companion extras (`model`, `fw_code`, `fw_build`, `max_tx_dbm`, `path_hash_mode`) for the wire, or null.
Map<String, dynamic>? wireCompanionExt(CompanionDetails? c) {
  if (c == null) return null;
  final out = <String, dynamic>{
    if (_text(c.model, 40, _modelRe)) 'model': c.model,
    if (c.fwCode != null) 'fw_code': c.fwCode,
    if (_text(c.fwBuild, 12, _versionishRe)) 'fw_build': c.fwBuild,
    if (c.maxTxDbm != null) 'max_tx_dbm': c.maxTxDbm,
    if (c.pathHashMode != null) 'path_hash_mode': c.pathHashMode,
  };
  return out.isEmpty ? null : out;
}

/// A ping's `ctx` for the wire (only measured keys), or null when empty.
Map<String, dynamic>? wireCtx(PingContext? c) {
  if (c == null || c.isEmpty) return null;
  return c.toJson();
}

/// A sample for the wire, or null when nothing the server accepts is left (a sample with no measurement is
/// rejected there). Drops `ble_rssi`: it is a local-only key and the server refuses unknown keys.
Map<String, dynamic>? wireSample(DriveSample s) {
  final j = s.toJson()..remove('ble_rssi');
  return j.length <= 2 ? null : j;
}

/// `ts|src` identity of a sample: what the server dedupes on (session, src, ts) and what the sent-ledger stores.
String sampleKey(DriveSample s) => '${s.src.name}|${s.ts.toUtc().toIso8601String()}';

/// The context part of one v1.2 drive-upload request.
class ContextUpload {
  /// `session.enrich.weather`: the weather category is on.
  final bool weather;
  final DeviceDetails? device;
  final CompanionDetails? companion;

  /// Ping id -> context, for the pings of this request.
  final Map<String, PingContext> pingContexts;
  final List<DriveSample> samples;
  const ContextUpload({
    required this.weather,
    this.device,
    this.companion,
    this.pingContexts = const {},
    this.samples = const [],
  });

  Map<String, dynamic>? get deviceJson => wireDevice(device);
  Map<String, dynamic>? get companionJson => wireCompanionExt(companion);
  Map<String, dynamic>? ctxJson(String pingId) => wireCtx(pingContexts[pingId]);
  List<Map<String, dynamic>> get samplesJson => [
        for (final s in samples)
          ?wireSample(s),
      ];

  /// True when there is any measured context in this request (the weather flag alone does not count).
  bool get hasContext =>
      deviceJson != null || companionJson != null || pingContexts.keys.any((id) => ctxJson(id) != null) || samplesJson.isNotEmpty;
}

/// One ping's late context in a [DriveContextBatch].
class PingContextEntry {
  final String id;
  final PingContext ctx;
  const PingContextEntry(this.id, this.ctx);
}

/// `POST /api/cmh/drive-context`: context for an already uploaded drive of this driver (same validator and rules as a
/// v1.2 upload; `ts` is checked against the stored session; at most [maxSamplesPerUpload] samples).
class DriveContextBatch {
  final String session;
  final List<PingContextEntry> pings;
  final List<DriveSample> samples;
  const DriveContextBatch({required this.session, this.pings = const [], this.samples = const []});

  Map<String, dynamic> toJson() => {
        'format': driveContextFormat,
        'session': session,
        'pings': [
          for (final p in pings)
            if (wireCtx(p.ctx) case final c?) {'id': p.id, 'ctx': c},
        ],
        'samples': [
          for (final s in samples)
            ?wireSample(s),
        ],
      };
}

/// A sample the server refused (`sampleRejections[]`); `index` is its position in the `samples` list sent.
class SampleRejection {
  final int index;
  final String reason;
  const SampleRejection({required this.index, required this.reason});
}

/// A ping whose context the server refused (`rejections[]` of the late-context answer).
class ContextRejection {
  final int index;
  final String? id;
  final String reason;
  const ContextRejection({required this.index, this.id, required this.reason});
}

/// The answer to `POST /api/cmh/drive-context`.
class ContextUploadResult {
  final int pingsUpdated;
  final int rejected;
  final List<ContextRejection> rejections;
  final int samplesStored;
  final int samplesDuplicate;
  final int samplesRejected;
  final List<SampleRejection> sampleRejections;
  const ContextUploadResult({
    this.pingsUpdated = 0,
    this.rejected = 0,
    this.rejections = const [],
    this.samplesStored = 0,
    this.samplesDuplicate = 0,
    this.samplesRejected = 0,
    this.sampleRejections = const [],
  });
}
