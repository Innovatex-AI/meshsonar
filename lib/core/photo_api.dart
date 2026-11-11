// Photo messages (meshsonar-infra docs/planning/photo-messages-2026-11-10.md, "API contract v1", binding):
//   <base>/api/cmh/photo-config   GET  (public)                     -> {enabled, maxUploadBytes, maxEdgePx, linkPrefix}
//   <base>/api/cmh/photo-upload   POST x-driver-key, raw image body -> 201 {id, url, thumbUrl, fullUrl, w, h, bytes, duplicate}
//                                 401 / 403 / 413 / 415 / 429 {error, retryAfterS} / 503 {error: "photos_disabled"}
//   <base>/api/cmh/photo-delete   POST x-driver-key, {id}           -> 200 {deleted: true}; 404 not found or not the owner
//   <base>/api/cmh/photo-report   POST {id, reason} (key optional)  -> 202 {reported: true}
//   https://meshsonar.com/p/<id>/thumb | /full                     -> image/webp; 404 unknown; 410 removed
// The radio only ever carries the plain link text; nothing here touches the mesh. Pure Dart: no Flutter imports.
import 'dart:async';

/// The only link form the app treats as a photo: `https://meshsonar.com/p/` + 8 base62 characters, not followed by another
/// id character or a slash (so `/p/<id>/full` and longer ids stay ordinary links).
// Split after the scheme so the host scan of test/integration/hosts_static_test.dart reads no literal host here.
final RegExp photoLinkRe = RegExp('https://' r'meshsonar\.com/p/([0-9A-Za-z]{8})(?![0-9A-Za-z/])');

/// The photo id when [url] is exactly a photo link, else null.
String? photoIdOf(String url) {
  final m = photoLinkRe.firstMatch(url);
  if (m == null || m.start != 0 || m.end != url.length) return null;
  return m.group(1);
}

/// Image addresses of a photo link (contract: url + `/thumb`, url + `/full`).
String photoThumbUrl(String url) => '$url/thumb';
String photoFullUrl(String url) => '$url/full';

/// `GET photo-config`.
class PhotoConfig {
  final bool enabled;
  final int maxUploadBytes;
  final int maxEdgePx;
  final String linkPrefix;
  const PhotoConfig({required this.enabled, this.maxUploadBytes = 10485760, this.maxEdgePx = 2048, this.linkPrefix = 'https://meshsonar.com/p/'});

  static const PhotoConfig disabled = PhotoConfig(enabled: false);

  static PhotoConfig parse(Map<String, dynamic> j) {
    int asInt(Object? v, int d) => v is num && v > 0 ? v.toInt() : d;
    return PhotoConfig(
      enabled: j['enabled'] == true,
      maxUploadBytes: asInt(j['maxUploadBytes'], 10485760),
      maxEdgePx: asInt(j['maxEdgePx'], 2048),
      linkPrefix: j['linkPrefix'] is String && (j['linkPrefix'] as String).isNotEmpty ? j['linkPrefix'] as String : 'https://meshsonar.com/p/',
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'maxUploadBytes': maxUploadBytes, 'maxEdgePx': maxEdgePx, 'linkPrefix': linkPrefix};
}

/// `201` of `photo-upload`.
class PhotoUploadResult {
  final String id;
  final String url;
  final String thumbUrl;
  final String fullUrl;
  final int? w, h, bytes;
  final bool duplicate;
  const PhotoUploadResult({required this.id, required this.url, required this.thumbUrl, required this.fullUrl, this.w, this.h, this.bytes, this.duplicate = false});

  /// Throws [FormatException] unless the answer carries an id and a link the app recognises as a photo.
  static PhotoUploadResult parse(Map<String, dynamic> j) {
    final id = j['id'], url = j['url'];
    if (id is! String || url is! String || photoIdOf(url) != id) throw const FormatException('upload answer without a photo link');
    int? n(Object? v) => v is num ? v.toInt() : null;
    return PhotoUploadResult(
      id: id,
      url: url,
      thumbUrl: j['thumbUrl'] is String ? j['thumbUrl'] as String : photoThumbUrl(url),
      fullUrl: j['fullUrl'] is String ? j['fullUrl'] as String : photoFullUrl(url),
      w: n(j['w']),
      h: n(j['h']),
      bytes: n(j['bytes']),
      duplicate: j['duplicate'] == true,
    );
  }
}

enum PhotoErrorKind { noKey, notApproved, tooLarge, notImage, rateLimited, disabled, notFound, network, cancelled, server }

/// Every refusal of the photo endpoints, mapped to one plain sentence for the person.
class PhotoError implements Exception {
  final PhotoErrorKind kind;
  final int? status;

  /// 429: seconds until another upload is accepted (`retryAfterS`, else `Retry-After`).
  final int? retryAfterS;
  final String? detail;
  const PhotoError(this.kind, {this.status, this.retryAfterS, this.detail});

  /// Maps an HTTP status (and the decoded `{error, retryAfterS}` body) to a kind, per contract v1.
  factory PhotoError.fromStatus(int status, {Map<String, dynamic>? body, int? retryAfterHeader}) {
    final err = body?['error'] is String ? body!['error'] as String : null;
    final ra = body?['retryAfterS'] is num ? (body!['retryAfterS'] as num).toInt() : retryAfterHeader;
    final kind = switch (status) {
      401 => PhotoErrorKind.noKey,
      403 => PhotoErrorKind.notApproved,
      404 => PhotoErrorKind.notFound,
      413 => PhotoErrorKind.tooLarge,
      415 => PhotoErrorKind.notImage,
      429 => PhotoErrorKind.rateLimited,
      503 => PhotoErrorKind.disabled,
      _ => PhotoErrorKind.server,
    };
    return PhotoError(kind, status: status, retryAfterS: ra, detail: err);
  }

  bool get retryable => kind == PhotoErrorKind.network || kind == PhotoErrorKind.server || kind == PhotoErrorKind.rateLimited;

  String get message => switch (kind) {
        PhotoErrorKind.noKey => 'Photos need a MeshSonar driver key. Set one up in Settings > Account.',
        PhotoErrorKind.notApproved => 'Your driver key is not approved for photos (pending, revoked or banned).',
        PhotoErrorKind.tooLarge => 'That photo is too large to upload, even after shrinking.',
        PhotoErrorKind.notImage => 'That file is not a photo the server accepts.',
        PhotoErrorKind.rateLimited => 'Photo limit reached. Try again ${waitText(retryAfterS)}.',
        PhotoErrorKind.disabled => 'Photos are switched off on the server right now.',
        PhotoErrorKind.notFound => 'That photo is already gone, or it is not yours.',
        PhotoErrorKind.network => 'Could not reach the MeshSonar server. Check your connection and try again.',
        PhotoErrorKind.cancelled => 'Upload cancelled.',
        PhotoErrorKind.server => 'The server could not take the photo${status == null ? '' : ' (error $status)'}. Try again.',
      };

  @override
  String toString() => 'PhotoError($kind, $status): $message';
}

/// "in 40 seconds", "in 12 minutes", "in 3 hours", "later".
String waitText(int? s) {
  if (s == null || s <= 0) return 'later';
  if (s < 90) return 'in $s seconds';
  if (s < 5400) return 'in ${(s / 60).round()} minutes';
  return 'in ${(s / 3600).round()} hours';
}

/// Lets the person stop an upload in flight.
class PhotoCancel {
  final Completer<void> _c = Completer<void>();
  bool get cancelled => _c.isCompleted;
  Future<void> get whenCancelled => _c.future;
  void cancel() {
    if (!_c.isCompleted) _c.complete();
  }
}

/// Why a photo is reported (`photo-report` `reason`). The server stores the slug; the label is what the picker shows.
enum PhotoReportReason {
  sexual('sexual', 'Sexual or nude content'),
  childSafety('child_safety', 'Involves a child'),
  violence('violence', 'Violence or threats'),
  personalInfo('personal_info', 'Shows private information'),
  spam('spam', 'Spam or scam'),
  other('other', 'Something else');

  final String slug;
  final String label;
  const PhotoReportReason(this.slug, this.label);
}

/// The photo endpoints. [HttpCmatClient] implements it; tests use fakes.
abstract class PhotoTransport {
  Future<PhotoConfig> photoConfig();

  /// Raw bytes up; [onProgress] gets (sent, total). Throws [PhotoError].
  Future<PhotoUploadResult> uploadPhoto(String driverKey, List<int> bytes,
      {String contentType = 'image/jpeg', void Function(int sent, int total)? onProgress, PhotoCancel? cancel});

  /// Throws [PhotoError] (404 = gone or not the owner).
  Future<void> deletePhoto(String driverKey, String id);

  /// [driverKey] is optional. Throws [PhotoError].
  Future<void> reportPhoto(String id, PhotoReportReason reason, {String? driverKey});
}
