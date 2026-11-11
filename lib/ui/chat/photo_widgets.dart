// Photo messages in the chat UI: the thumbnail inside a bubble (loading, loaded, "Tap to load photo" when automatic loading
// is off, "Photo, loads when online" when it cannot be fetched, "Photo removed" after a 410), the full-screen viewer (pinch
// zoom, Save to Photos, Share, Report, Delete photo for own uploads) and the shared actions the long-press menu also uses.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/photo_controller.dart';
import '../../core/photo_api.dart';
import '../../core/photo_cache.dart';
import '../../platform/photo_picker.dart' as platform;
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';

/// Thumbnail box: at most this wide and tall; placeholders use 4:3 at full width.
const double kPhotoThumbMaxW = 240;
const double kPhotoThumbMaxH = 300;

enum PhotoThumbState { loading, loaded, tapToLoad, offline, removed }

class PhotoThumb extends StatefulWidget {
  final String url;
  final PhotoSource source;

  /// "Load photos automatically". Off: nothing is fetched until the person taps (unless it is already on the phone).
  final bool autoLoad;
  final double maxWidth;
  final void Function(String url)? onOpen;
  const PhotoThumb({super.key, required this.url, required this.source, this.autoLoad = true, this.maxWidth = kPhotoThumbMaxW, this.onOpen});

  @override
  State<PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<PhotoThumb> {
  PhotoThumbState _state = PhotoThumbState.loading;
  Uint8List? _bytes;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void didUpdateWidget(PhotoThumb old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.source != widget.source || (!old.autoLoad && widget.autoLoad && _state == PhotoThumbState.tapToLoad)) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    final g = ++_gen;
    if (await widget.source.knownRemoved(widget.url)) {
      _set(g, PhotoThumbState.removed);
      return;
    }
    final hit = await widget.source.cached(widget.url, PhotoVariant.thumb);
    if (hit != null) {
      _set(g, PhotoThumbState.loaded, Uint8List.fromList(hit));
      return;
    }
    if (!widget.autoLoad) {
      _set(g, PhotoThumbState.tapToLoad);
      return;
    }
    await _load(g);
  }

  Future<void> _load(int g) async {
    _set(g, PhotoThumbState.loading);
    final r = await widget.source.fetch(widget.url, PhotoVariant.thumb);
    switch (r.state) {
      case PhotoFetchState.ok:
        _set(g, PhotoThumbState.loaded, Uint8List.fromList(r.bytes!));
      case PhotoFetchState.removed:
        _set(g, PhotoThumbState.removed);
      case PhotoFetchState.failed:
        _set(g, PhotoThumbState.offline);
    }
  }

  void _set(int g, PhotoThumbState s, [Uint8List? b]) {
    if (!mounted || g != _gen) return;
    setState(() {
      _state = s;
      _bytes = b;
    });
  }

  void _tap() {
    switch (_state) {
      case PhotoThumbState.loaded:
        widget.onOpen?.call(widget.url);
      case PhotoThumbState.tapToLoad:
      case PhotoThumbState.offline:
        unawaited(_load(++_gen));
      case PhotoThumbState.loading:
      case PhotoThumbState.removed:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final w = widget.maxWidth.clamp(120.0, kPhotoThumbMaxW);
    final radius = BorderRadius.circular(14);
    Widget tile(AppSymbol symbol, String text, {Key? key, bool spinner = false}) => Container(
          key: key,
          width: w,
          height: w * 0.75,
          decoration: BoxDecoration(color: c.bg.withValues(alpha: 0.35), borderRadius: radius, border: Border.all(color: c.outline.withValues(alpha: 0.4), width: 0.5)),
          padding: const EdgeInsets.all(Gap.m),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (spinner) const CupertinoActivityIndicator() else AppSymbolIcon(symbol, size: 28, color: c.textMuted),
            if (text.isNotEmpty) ...[
              const SizedBox(height: Gap.s),
              Text(text, textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
            ],
          ]),
        );
    final Widget child = switch (_state) {
      PhotoThumbState.loading => tile(AppSymbols.photo, '', key: const Key('photo-loading'), spinner: true),
      PhotoThumbState.tapToLoad => tile(AppSymbols.photo, 'Tap to load photo', key: const Key('photo-tap-to-load')),
      PhotoThumbState.offline => tile(AppSymbols.photo, 'Photo, loads when online', key: const Key('photo-offline')),
      PhotoThumbState.removed => tile(AppSymbols.xmarkCircleFill, 'Photo removed', key: const Key('photo-removed')),
      PhotoThumbState.loaded => ConstrainedBox(
          key: const Key('photo-loaded'),
          constraints: BoxConstraints(maxWidth: w, maxHeight: kPhotoThumbMaxH, minWidth: 80, minHeight: 60),
          child: ClipRRect(
            borderRadius: radius,
            child: Image.memory(
              _bytes!,
              gaplessPlayback: true,
              fit: BoxFit.cover,
              frameBuilder: (context, img, frame, sync) => frame == null && !sync ? tile(AppSymbols.photo, '') : img,
              errorBuilder: (context, e, s) => tile(AppSymbols.photo, 'Photo, loads when online'),
            ),
          ),
        ),
    };
    final label = switch (_state) {
      PhotoThumbState.loaded => 'Photo. Double tap to open',
      PhotoThumbState.loading => 'Photo, loading',
      PhotoThumbState.tapToLoad => 'Photo. Double tap to load it',
      PhotoThumbState.offline => 'Photo, loads when online. Double tap to try again',
      PhotoThumbState.removed => 'Photo removed',
    };
    return Semantics(
      button: _state != PhotoThumbState.removed && _state != PhotoThumbState.loading,
      image: _state == PhotoThumbState.loaded,
      label: label,
      excludeSemantics: true,
      onTap: _tap,
      child: GestureDetector(key: Key('photo-thumb-${photoIdOf(widget.url) ?? widget.url}'), behavior: HitTestBehavior.opaque, onTap: _tap, child: child),
    );
  }
}

// ------------------------------------------------------------------ shared actions

String _errorText(Object e) => e is PhotoError ? e.message : 'Something went wrong. Try again.';

/// Report flow: reason picker, then `photo-report`. Toasts the outcome.
Future<void> reportPhotoFlow(BuildContext context, PhotoController photos, String url) async {
  final reason = await showAppActionSheet<PhotoReportReason>(
    context,
    sheetKey: const Key('photo-report-sheet'),
    title: 'Report this photo',
    message: 'MeshSonar reviews reported photos and removes what breaks the rules. The sender is not told who reported it.',
    actions: [for (final r in PhotoReportReason.values) AppAction(r.label, r, key: Key('photo-report-${r.slug}'))],
  );
  if (reason == null || !context.mounted) return;
  try {
    await photos.report(url, reason);
    if (context.mounted) showAppToast(context, 'Reported. Thank you.', kind: AppToastKind.success);
  } catch (e) {
    if (context.mounted) showAppToast(context, _errorText(e), kind: AppToastKind.error);
  }
}

/// Delete flow for an own photo: confirm, then `photo-delete`. Returns true when it is gone.
Future<bool> deletePhotoFlow(BuildContext context, PhotoController photos, String url) async {
  final ok = await showAppAlert(
    context,
    title: 'Delete this photo?',
    message: 'It is removed from the MeshSonar server, so the link shows "Photo removed" for everyone. The message text stays.',
    confirmLabel: 'Delete photo',
    cancelLabel: 'Keep',
    destructive: true,
    confirmKey: const Key('confirm-delete-photo'),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await photos.delete(url);
    if (context.mounted) showAppToast(context, 'Photo deleted', kind: AppToastKind.success);
    return true;
  } catch (e) {
    if (context.mounted) showAppToast(context, _errorText(e), kind: AppToastKind.error);
    return false;
  }
}

Future<Uint8List?> _fullBytes(PhotoSource source, String url) async {
  final r = await source.fetch(url, PhotoVariant.full);
  if (r.state == PhotoFetchState.ok) return Uint8List.fromList(r.bytes!);
  final t = await source.cached(url, PhotoVariant.thumb);
  return t == null ? null : Uint8List.fromList(t);
}

Future<void> savePhotoFlow(BuildContext context, PhotoSource source, String url) async {
  final b = await _fullBytes(source, url);
  if (!context.mounted) return;
  if (b == null) {
    showAppToast(context, 'The photo has not loaded yet. Try again when online.', kind: AppToastKind.error);
    return;
  }
  final err = await platform.savePhotoToLibrary(b);
  if (context.mounted) showAppToast(context, err ?? 'Saved to Photos', kind: err == null ? AppToastKind.success : AppToastKind.error);
}

Future<void> sharePhotoFlow(BuildContext context, PhotoSource source, String url) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
  final b = await _fullBytes(source, url);
  try {
    if (b == null) {
      await platform.sharePhotoLink(url, origin: origin);
    } else {
      await platform.sharePhoto(b, url, origin: origin);
    }
  } catch (_) {
    if (context.mounted) showAppToast(context, 'Could not share the photo.', kind: AppToastKind.error);
  }
}

/// Tapping the photo button without an approved driver key.
Future<void> showPhotoNeedsKey(BuildContext context) => showAppAlert(
      context,
      title: 'Photos need a driver key',
      message: 'Photos are stored on the MeshSonar server, so sending one needs an approved driver key. '
          'Set it up in Settings > Account. Reading photos others send does not.',
      confirmLabel: 'OK',
      cancelLabel: 'Close',
      dialogKey: const Key('photo-needs-key'),
    );

// ------------------------------------------------------------------ viewer

class PhotoViewerScreen extends StatefulWidget {
  final String url;
  final PhotoController photos;
  const PhotoViewerScreen({super.key, required this.url, required this.photos});

  static Future<void> open(BuildContext context, {required String url, required PhotoController photos}) =>
      Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, a, b) => PhotoViewerScreen(url: url, photos: photos),
        transitionsBuilder: (context, a, b, child) => FadeTransition(opacity: a, child: child),
      ));

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  Uint8List? _bytes;
  bool _full = false;
  PhotoFetchState? _failed;

  PhotoSource get _src => widget.photos.source;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final thumb = await _src.cached(widget.url, PhotoVariant.thumb);
    if (thumb != null && mounted) setState(() => _bytes = Uint8List.fromList(thumb));
    final r = await _src.fetch(widget.url, PhotoVariant.full);
    if (!mounted) return;
    setState(() {
      if (r.state == PhotoFetchState.ok) {
        _bytes = Uint8List.fromList(r.bytes!);
        _full = true;
        _failed = null;
      } else {
        _failed = r.state;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final own = widget.photos.isOwn(photoIdOf(widget.url) ?? '');
    const ink = Colors.white;
    final b = _bytes;
    final removed = _failed == PhotoFetchState.removed;
    Widget body;
    if (removed) {
      body = Text('Photo removed', key: const Key('viewer-removed'), style: AppType.body.copyWith(color: ink));
    } else if (b == null) {
      body = _failed == null
          ? const CupertinoActivityIndicator(color: ink)
          : Text('Photo, loads when online', key: const Key('viewer-offline'), style: AppType.body.copyWith(color: ink));
    } else {
      body = InteractiveViewer(
        key: const Key('viewer-zoom'),
        minScale: 1,
        maxScale: 6,
        child: Center(child: Image.memory(b, key: Key(_full ? 'viewer-full' : 'viewer-thumb'), fit: BoxFit.contain, gaplessPlayback: true)),
      );
    }
    Widget action(Key key, AppSymbol s, String label, void Function(BuildContext ctx)? onTap, {bool danger = false}) => Expanded(
          child: Builder(
            builder: (ctx) => CupertinoButton(
              key: key,
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              minimumSize: Size.square(Hit.of(context)),
              onPressed: onTap == null ? null : () => onTap(ctx),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                AppSymbolIcon(s, size: 24, color: onTap == null ? Colors.white38 : (danger ? AppColors.of(context).danger : ink)),
                const SizedBox(height: 2),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.caption.copyWith(color: onTap == null ? Colors.white38 : ink)),
              ]),
            ),
          ),
        );
    final loaded = b != null && !removed;
    return Scaffold(
      key: const Key('photo-viewer'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Row(children: [
            CupertinoButton(
              key: const Key('viewer-close'),
              padding: const EdgeInsets.all(Gap.s),
              minimumSize: Size.square(Hit.of(context)),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Semantics(label: 'Close', button: true, child: const AppSymbolIcon(AppSymbols.xmark, size: 24, color: ink)),
            ),
            const Spacer(),
            Text('Photo', style: AppType.headline.copyWith(color: ink)),
            const Spacer(),
            const SizedBox(width: 44 + Gap.s * 2),
          ]),
          Expanded(child: Center(child: body)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.s),
            child: Row(children: [
              action(const Key('viewer-save'), AppSymbols.squareAndArrowDown, 'Save', loaded ? (ctx) => savePhotoFlow(ctx, _src, widget.url) : null),
              action(const Key('viewer-share'), AppSymbols.squareAndArrowUp, 'Share', removed ? null : (ctx) => sharePhotoFlow(ctx, _src, widget.url)),
              action(const Key('viewer-report'), AppSymbols.flag, 'Report', removed ? null : (ctx) => reportPhotoFlow(ctx, widget.photos, widget.url)),
              if (own)
                action(const Key('viewer-delete'), AppSymbols.trash, 'Delete', removed
                    ? null
                    : (ctx) async {
                        if (await deletePhotoFlow(ctx, widget.photos, widget.url) && mounted) setState(() => _failed = PhotoFetchState.removed);
                      }, danger: true),
            ]),
          ),
        ]),
      ),
    );
  }
}
