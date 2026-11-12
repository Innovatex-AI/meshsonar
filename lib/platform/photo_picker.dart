// Camera / photo library, the on-phone shrink (long edge <= maxEdgePx, JPEG q80, then the 450 KB budget) and the metadata strip of photo messages.
// The compressor re-encodes without EXIF (keepExif: false); stripJpegMetadata (lib/core/jpeg_meta.dart) then removes any
// APP1/XMP/COM segment that might still be there, and the result is checked for GPS before it may leave the phone. Also:
// Save to Photos (gal) and the sharing of a photo file.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/jpeg_meta.dart';
import '../core/photo_budget.dart';

enum PhotoPickSource { camera, library }

/// A photo ready to upload: JPEG bytes with no metadata, at most [maxEdgePx] on its long edge.
class PreparedPhoto {
  final Uint8List bytes;
  final int width, height;
  const PreparedPhoto(this.bytes, this.width, this.height);
}

class PhotoPrepareException implements Exception {
  final String message;
  const PhotoPrepareException(this.message);
  @override
  String toString() => message;
}

/// The seam the composer uses. [DevicePhotoPicker] on a phone; tests and the debug screenshot build use fakes.
abstract class PhotoPicker {
  /// Null when the person backed out. Throws [PhotoPrepareException] when the picture could not be read or shrunk.
  Future<PreparedPhoto?> pick(PhotoPickSource source, {int maxEdgePx = 2048});

  /// The small copy of [full] for a private photo (long edge [edge], JPEG [quality], no metadata). Throws
  /// [PhotoPrepareException].
  Future<PreparedPhoto> thumbnail(PreparedPhoto full, {int edge = privateThumbEdgePx, int quality = privateThumbQuality});
}

/// Long and short edge of [bytes] when Flutter can read its header, else null.
Future<(int, int)?> imageSize(Uint8List bytes) async {
  try {
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    final d = await ui.ImageDescriptor.encoded(buf);
    final r = (d.width, d.height);
    d.dispose();
    buf.dispose();
    return r;
  } catch (_) {
    return null;
  }
}

/// The compressor's min width/height (it scales so that BOTH edges stay at or above them) that make the long edge of a
/// [w] x [h] picture land on [maxEdge]. Orientation does not matter: the same value is used for both.
int compressMinFor(int w, int h, int maxEdge) {
  final long = math.max(w, h), short = math.min(w, h);
  if (long <= maxEdge || short <= 0) return math.max(1, short);
  return math.max(1, (maxEdge * short / long).floor());
}

class DevicePhotoPicker implements PhotoPicker {
  final ImagePicker _picker = ImagePicker();

  @override
  Future<PreparedPhoto?> pick(PhotoPickSource source, {int maxEdgePx = 2048}) async {
    final XFile? f;
    try {
      // requestFullMetadata false: no full-library permission needed and the picker asks for no location data.
      f = await _picker.pickImage(source: source == PhotoPickSource.camera ? ImageSource.camera : ImageSource.gallery, requestFullMetadata: false);
    } on PlatformException catch (e) {
      throw PhotoPrepareException(e.code == 'camera_access_denied' || e.code == 'photo_access_denied'
          ? 'MeshSonar is not allowed to use the ${source == PhotoPickSource.camera ? 'camera' : 'photo library'}. Turn it on in the Settings app.'
          : 'Could not open the ${source == PhotoPickSource.camera ? 'camera' : 'photo library'}.');
    }
    if (f == null) return null;
    final original = await f.readAsBytes();
    return preparePhotoBytes(original, maxEdgePx: maxEdgePx, path: f.path);
  }

  @override
  Future<PreparedPhoto> thumbnail(PreparedPhoto full, {int edge = privateThumbEdgePx, int quality = privateThumbQuality}) => prepareThumbnail(full, edge: edge, quality: quality);
}

/// Shrinks the already metadata-free [full] to a thumbnail (long edge [edge], JPEG [quality]) and proves it carries no EXIF or
/// GPS, like [preparePhotoBytes] does for the full image.
Future<PreparedPhoto> prepareThumbnail(PreparedPhoto full, {int edge = privateThumbEdgePx, int quality = privateThumbQuality}) async {
  var w = full.width, h = full.height;
  if (w <= 0 || h <= 0) {
    final size = await imageSize(full.bytes);
    if (size != null) (w, h) = size;
  }
  final min = w <= 0 || h <= 0 ? edge : compressMinFor(w, h, edge);
  Uint8List? out;
  try {
    out = await FlutterImageCompress.compressWithList(full.bytes, minWidth: min, minHeight: min, quality: quality, format: CompressFormat.jpeg, keepExif: false, autoCorrectionAngle: true);
  } catch (_) {
    out = null;
  }
  if (out == null || out.isEmpty) throw const PhotoPrepareException('Could not make a preview of that photo.');
  final clean = stripJpegMetadata(out);
  if (!jpegIsClean(clean)) throw const PhotoPrepareException('Could not remove the photo details (like location) safely, so it was not sent.');
  final dims = await imageSize(clean);
  return PreparedPhoto(clean, dims?.$1 ?? 0, dims?.$2 ?? 0);
}

/// Shrinks and re-encodes [original] (any format the phone reads, HEIC included) to a metadata-free JPEG q80.
/// Then, above 450 KB, steps down the quality and the edge (lib/core/photo_budget.dart) so a slow uplink can carry it.
Future<PreparedPhoto> preparePhotoBytes(Uint8List original, {int maxEdgePx = 2048, String? path}) async {
  Future<Uint8List?> compress(Uint8List src, int min, {bool fromPath = false, int quality = 80}) async {
    try {
      if (fromPath && path != null) {
        return await FlutterImageCompress.compressWithFile(path,
            minWidth: min, minHeight: min, quality: quality, format: CompressFormat.jpeg, keepExif: false, autoCorrectionAngle: true);
      }
      return await FlutterImageCompress.compressWithList(src,
          minWidth: min, minHeight: min, quality: quality, format: CompressFormat.jpeg, keepExif: false, autoCorrectionAngle: true);
    } catch (_) {
      return null;
    }
  }

  final size = await imageSize(original);
  var out = await compress(original, size == null ? maxEdgePx : compressMinFor(size.$1, size.$2, maxEdgePx), fromPath: true);
  if (out == null || out.isEmpty) throw const PhotoPrepareException('Could not read that photo.');
  var dims = await imageSize(out);
  // A format Flutter could not measure (HEIC): the first pass kept the SHORT edge at maxEdge; shrink once more.
  if (dims != null && math.max(dims.$1, dims.$2) > maxEdgePx) {
    final again = await compress(out, compressMinFor(dims.$1, dims.$2, maxEdgePx));
    if (again != null && again.isNotEmpty) {
      out = again;
      dims = await imageSize(out);
    }
  }
  // Size budget: re-encode from the original (not the q80 output, to avoid stacking JPEG losses) at lower quality, then a
  // smaller edge. The aspect comes from the shrunk picture, so the compressor's min-both-edges rule lands the long edge.
  if (out.length > photoBudgetBytes) {
    final aspect = dims ?? size;
    final edge = dims == null ? maxEdgePx : math.max(dims.$1, dims.$2);
    final fitted = await fitPhotoBudget(out, edge, (e, q) async {
      final min = aspect == null ? e : compressMinFor(aspect.$1, aspect.$2, e);
      return compress(original, min, fromPath: true, quality: q);
    });
    if (!identical(fitted, out)) {
      out = fitted;
      dims = await imageSize(out);
    }
  }
  final clean = stripJpegMetadata(out);
  if (!jpegIsClean(clean)) {
    // Never upload a picture whose metadata could not be proven gone.
    throw const PhotoPrepareException('Could not remove the photo details (like location) safely, so it was not sent.');
  }
  return PreparedPhoto(clean, dims?.$1 ?? 0, dims?.$2 ?? 0);
}

/// Saves [bytes] (the full WebP) to the Photos library as a JPEG. Returns null on success, else a sentence.
Future<String?> savePhotoToLibrary(Uint8List bytes, {String name = 'MeshSonar photo'}) async {
  try {
    if (!await Gal.hasAccess()) {
      if (!await Gal.requestAccess()) return 'MeshSonar is not allowed to add to Photos. Turn it on in the Settings app.';
    }
    final jpeg = await webpToJpeg(bytes);
    await Gal.putImageBytes(jpeg, name: name);
    return null;
  } on GalException catch (e) {
    return e.type == GalExceptionType.accessDenied ? 'MeshSonar is not allowed to add to Photos. Turn it on in the Settings app.' : 'Could not save the photo.';
  } catch (_) {
    return 'Could not save the photo.';
  }
}

/// Re-encodes a WebP (or anything Flutter decodes) as JPEG q92 for Photos and sharing; falls back to PNG.
Future<Uint8List> webpToJpeg(Uint8List bytes) async {
  if (isJpeg(bytes)) return bytes;
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (png == null) throw const PhotoPrepareException('Could not read the photo.');
  final pngBytes = png.buffer.asUint8List();
  try {
    final j = await FlutterImageCompress.compressWithList(pngBytes, quality: 92, format: CompressFormat.jpeg, keepExif: false, minWidth: 1, minHeight: 1);
    if (j.isNotEmpty) return j;
  } catch (_) {}
  return pngBytes;
}

/// Shares the photo file and its link through the system share sheet.
Future<void> sharePhoto(Uint8List bytes, String url, {ui.Rect? origin}) async {
  final jpeg = await webpToJpeg(bytes).catchError((_) => bytes);
  final dir = await getTemporaryDirectory();
  final ext = isJpeg(jpeg) ? 'jpg' : 'png';
  final f = File('${dir.path}${Platform.pathSeparator}meshsonar-photo-${url.split('/').last}.$ext');
  await f.writeAsBytes(jpeg, flush: true);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: url, sharePositionOrigin: origin));
}

/// Shares the link only (when the picture itself has not loaded).
Future<void> sharePhotoLink(String url, {ui.Rect? origin}) => SharePlus.instance.share(ShareParams(text: url, sharePositionOrigin: origin));
