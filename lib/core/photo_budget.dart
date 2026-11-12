// Size budget of a photo upload. A slow uplink (~14 KB/s measured on Andy's phone) needs a minute for a 1 MB JPEG, so
// after the shrink to the server's maxEdgePx at q80 a photo above [photoBudgetBytes] is encoded again at q70, then q60,
// then at q60 with the long edge 20 % smaller per step, never below [photoMinEdgePx]. The smallest result is used even if
// it is still above the budget (the server takes up to maxUploadBytes). Pure Dart; the encoder is injected
// (lib/platform/photo_picker.dart passes flutter_image_compress), the metadata strip and its check run after this.
import 'dart:math' as math;
import 'dart:typed_data';

/// 450 KB (decimal, as the person would read it): ~32 s at 14 KB/s.
const int photoBudgetBytes = 450 * 1000;

/// The long edge never goes below this to meet the budget.
const int photoMinEdgePx = 800;

/// The re-encode steps after the q80 shrink at [edge]: (long edge, JPEG quality), in order.
List<(int, int)> photoBudgetSteps(int edge, {int minEdge = photoMinEdgePx}) {
  final steps = <(int, int)>[(edge, 70), (edge, 60)];
  var e = edge;
  while (e > minEdge) {
    e = math.max(minEdge, (e * 0.8).round());
    steps.add((e, 60));
  }
  return steps;
}

/// [first] is the q80 shrink at [edge]. Returns it when within [budget], else the first step of [photoBudgetSteps] that
/// fits, else the smallest encoding seen. [encode] returns null (or empty) when a step could not be made; it is skipped.
Future<Uint8List> fitPhotoBudget(Uint8List first, int edge, Future<Uint8List?> Function(int edge, int quality) encode,
    {int budget = photoBudgetBytes, int minEdge = photoMinEdgePx}) async {
  if (first.length <= budget) return first;
  var best = first;
  for (final (e, q) in photoBudgetSteps(edge, minEdge: minEdge)) {
    final out = await encode(e, q);
    if (out == null || out.isEmpty) continue;
    if (out.length < best.length) best = out;
    if (out.length <= budget) return out;
  }
  return best;
}

// ---- the link in the message (160-byte packet budget) and the private thumb ----

/// `https://meshsonar.com/p/<8>`: 24 + 8.
const int plainPhotoLinkBytes = 32;

/// `https://meshsonar.com/e/<8>#<22>`: 24 + 8 + 1 + 22 (same value as `privatePhotoLinkBytes`, lib/core/private_photo.dart).
const int privatePhotoLinkBytesBudget = 55;

/// Bytes a photo link takes in the message, [private] or plain.
int photoLinkBytes({required bool private}) => private ? privatePhotoLinkBytesBudget : plainPhotoLinkBytes;

/// Bytes of text left beside a photo link: the link and the separating space come out of [maxTextBytes]
/// (a direct message: 160 - 55 - 1 = 104 private, 160 - 32 - 1 = 127 plain).
int textBytesBesidePhoto(int maxTextBytes, {required bool private}) => maxTextBytes - photoLinkBytes(private: private) - 1;

/// The private thumb: long edge and JPEG quality (docs/planning/photo-e2e-private-2026-11-12.md).
const int privateThumbEdgePx = 480;
const int privateThumbQuality = 70;
