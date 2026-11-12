// The compose bar (chat plan 4.3): a pill that grows to five lines, a send button whose ring fills with the bytes used (the
// number appears inside it at 20 or fewer left), a quick-replies chip strip, an @mention strip, a one-line "Trimmed to fit"
// caption after an over-long paste, the offline hint and the passenger lock. No reply feature (cut, R07).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter/services.dart';

import '../../app/chat_controller.dart';
import '../../app/photo_controller.dart';
import '../../chat/photo_kind.dart';
import '../../core/photo_api.dart';
import '../../platform/photo_picker.dart' show PhotoPickSource, PhotoPrepareException, PreparedPhoto;
import '../../chat/models.dart' show ConvKey, ConvKind;
import '../../chat/quick_replies.dart';
import '../design/app_surfaces.dart';
import '../../chat/send_budget.dart';
import '../alerts/permission_prompt.dart';
import '../design/app_haptics.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import 'photo_widgets.dart' show showPhotoNeedsKey;
import 'quick_replies_sheet.dart';

/// Keeps the field inside the packet: typing past the limit is refused (warning haptic), a paste is cut at a character
/// boundary and reported through [onTrimmed].
class ByteLimitFormatter extends TextInputFormatter {
  final int Function() maxBytes;
  final void Function(bool paste) onTrimmed;
  ByteLimitFormatter({required this.maxBytes, required this.onTrimmed});

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final max = maxBytes();
    if (utf8.encode(newValue.text).length <= max) return newValue;
    final grew = newValue.text.length - oldValue.text.length;
    final cut = trimToBytes(newValue.text, max);
    onTrimmed(grew > 2);
    final end = math.min(newValue.selection.end < 0 ? cut.length : newValue.selection.end, cut.length);
    return TextEditingValue(text: cut, selection: TextSelection.collapsed(offset: end));
  }

}

class Composer extends StatefulWidget {
  final ChatController controller;
  final String convKey;
  final String hint;

  /// Recent senders of a channel, offered when the person types "@". Empty turns the mention strip off.
  final List<String> mentionNames;
  final VoidCallback? onSent;

  /// Set when the conversation is a channel that is no longer on the radio: the bar explains and offers this.
  final VoidCallback? onChannelInfoWhenOffRadio;

  /// Photo messages: the photo button, the upload strip and the link insertion. Null = no photo button.
  final PhotoController? photos;

  const Composer({super.key, required this.controller, required this.convKey, this.hint = 'Message', this.mentionNames = const [], this.onSent, this.onChannelInfoWhenOffRadio, this.photos});

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  Timer? _trimTimer;
  String? _error;
  bool _chips = false;
  bool _trimmed = false;
  BudgetLevel _level = BudgetLevel.quiet;
  List<String> _replies = const [];
  _PhotoJob? _job;
  PhotoController? _photosBound;

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: c.service.loadDraft(widget.convKey) ?? '');
    _text.addListener(_onChanged);
    c.addListener(_onController);
    _replies = loadQuickReplies(c.store);
    _level = ByteBudget.of(_text.text, c.service.maxTextBytes(widget.convKey)).level;
    _bindPhotos();
  }

  void _bindPhotos() {
    if (identical(_photosBound, widget.photos)) return;
    _photosBound?.removeListener(_onController);
    _photosBound = widget.photos?..addListener(_onController);
    unawaited(_photosBound?.refreshConfig());
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    _bindPhotos();
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _onChanged() {
    _error = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _saveDraft);
    final b = ByteBudget.of(_text.text, c.service.maxTextBytes(widget.convKey));
    final msg = b.announcementFor(_level);
    if (msg != null && mounted) SemanticsService.sendAnnouncement(View.of(context), msg, Directionality.of(context));
    _level = b.level;
    // A photo link that did not fit goes in by itself once enough text was cut.
    final j = _job;
    if (j != null && j.stage == _PhotoStage.waitingForRoom && _linkFits(j.result!.url)) _insertLink(j.result!.url);
    setState(() {});
  }

  void _saveDraft() {
    _debounce?.cancel();
    if (!mounted) return;
    c.service.saveDraft(widget.convKey, _text.text);
  }

  @override
  void dispose() {
    // Flush the draft: leaving the screen must not lose what was typed.
    _debounce?.cancel();
    _trimTimer?.cancel();
    c.removeListener(_onController);
    _photosBound?.removeListener(_onController);
    _job?.cancel.cancel();
    try {
      // Straight to the store: no event while the widget tree is being torn down.
      c.store.drafts.save(widget.convKey, _text.text, c.now().millisecondsSinceEpoch);
    } catch (_) {}
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTrimmed(bool paste) {
    AppHaptics.warning();
    if (!paste) return;
    _trimTimer?.cancel();
    // Formatters run inside the framework's edit handling: show the caption on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _trimmed = true);
      _trimTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _trimmed = false);
      });
    });
  }

  /// A direct message (person or room): long-press Send offers the choice of route (CR2).
  bool get _direct => ConvKey.kindOf(widget.convKey) != ConvKind.channel;

  /// Long-press Send on a direct message: send normally (the saved route, searching on the last try) or flood every try
  /// (searches for a new route, like the official app's long-press Send).
  Future<void> _chooseRoute() async {
    AppHaptics.selection();
    final flood = await showAppActionSheet<bool>(
      context,
      sheetKey: const Key('send-route-sheet'),
      title: 'How should this message go?',
      message: 'Searching asks every repeater to pass it on. It finds a new route when the saved one stopped working, '
          'but uses more of the mesh.',
      actions: const [
        AppAction('Send', false, isDefault: true, key: Key('send-normal')),
        AppAction('Send and search for a new route', true, key: Key('send-flood')),
      ],
    );
    if (flood != null && mounted) _send(forceFlood: flood);
  }

  void _send({bool forceFlood = false}) {
    final res = c.send(widget.convKey, _text.text, forceFlood: forceFlood);
    if (res.ok) {
      AppHaptics.light();
      _text.clear();
      setState(() => _error = null);
      widget.onSent?.call();
      // First message sent: the right moment to explain alerts (once; never at launch).
      unawaited(offerAlertsAfterFirstAction(context));
    } else {
      setState(() => _error = res.error);
    }
  }

  void _insert(String s) {
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : _text.text.length;
    final end = sel.isValid ? sel.end : at;
    final before = _text.text.substring(0, at);
    final lead = before.isEmpty || before.endsWith(' ') || before.endsWith('\n') ? '' : ' ';
    final ins = '$lead$s';
    _text.value = TextEditingValue(text: _text.text.replaceRange(at, end, ins), selection: TextSelection.collapsed(offset: at + ins.length));
    _focus.requestFocus();
  }

  // ---------- photos ----------

  int get _max => c.service.maxTextBytes(widget.convKey);

  String _withLink(String url) {
    final t = _text.text.trimRight();
    return t.isEmpty ? url : '$t $url';
  }

  bool _linkFits(String url) => utf8.encode(_withLink(url).trim()).length <= _max;

  /// Bytes to cut from the text before [url] fits.
  int _bytesToCut(String url) => utf8.encode(_withLink(url).trim()).length - _max;

  void _insertLink(String url) {
    final t = _withLink(url);
    _job = null;
    _text.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  /// Private (end-to-end encrypted) or plain link for this conversation (lib/chat/photo_kind.dart): decided by the
  /// conversation, never by the person.
  bool get _privatePhoto => c.service.photoKind(widget.convKey) == PhotoKind.private;

  Future<void> _photoTapped() async {
    final p = widget.photos;
    if (p == null) return;
    AppHaptics.selection();
    final private = _privatePhoto;
    if (p.buttonFor(private ? PhotoKind.private : PhotoKind.plain) == PhotoButton.hidden) return;
    if (p.button == PhotoButton.needsKey) {
      await showPhotoNeedsKey(context);
      return;
    }
    if (_job != null && _job!.stage == _PhotoStage.uploading) return;
    final src = await showAppActionSheet<PhotoPickSource>(
      context,
      sheetKey: const Key('photo-source-sheet'),
      title: 'Send a photo',
      message: private
          ? 'The photo is shrunk, its details (like location) removed and then encrypted on this phone. MeshSonar stores only '
              'the encrypted copy; the link in the message holds the key, so only people who get the message can open it. '
              'It is deleted after 30 days.'
          : 'The photo is shrunk and its details (like location) removed on this phone, then stored on the MeshSonar '
              'server. The message carries a short link to it.',
      actions: const [
        AppAction('Take Photo', PhotoPickSource.camera, symbol: AppSymbols.camera, key: Key('photo-camera')),
        AppAction('Choose from Library', PhotoPickSource.library, symbol: AppSymbols.photo, key: Key('photo-library')),
      ],
    );
    if (src == null || !mounted) return;
    PreparedPhoto? photo, thumb;
    setState(() => _job = _PhotoJob(_PhotoStage.preparing));
    try {
      photo = await p.picker.pick(src, maxEdgePx: p.config.maxEdgePx);
    } on PhotoPrepareException catch (e) {
      if (mounted) setState(() => _job = _PhotoJob(_PhotoStage.failed, error: e.message));
      return;
    } catch (_) {
      if (mounted) setState(() => _job = _PhotoJob(_PhotoStage.failed, error: 'Could not read that photo.'));
      return;
    }
    if (!mounted) return;
    if (photo == null) {
      setState(() => _job = null);
      return;
    }
    if (private) {
      try {
        thumb = await p.picker.thumbnail(photo);
      } on PhotoPrepareException catch (e) {
        if (mounted) setState(() => _job = _PhotoJob(_PhotoStage.failed, photo: photo, error: e.message, retryable: false));
        return;
      } catch (_) {
        if (mounted) setState(() => _job = _PhotoJob(_PhotoStage.failed, photo: photo, error: 'Could not read that photo.', retryable: false));
        return;
      }
    }
    await _upload(photo, thumb: thumb);
  }

  /// [thumb] is set for a private conversation: the photo then goes up encrypted and the link carries the key; a private
  /// conversation never gets a plain link.
  Future<void> _upload(PreparedPhoto photo, {PreparedPhoto? thumb}) async {
    final p = widget.photos;
    if (p == null) return;
    final private = _privatePhoto;
    final job = _PhotoJob(_PhotoStage.uploading, photo: photo, thumb: thumb);
    setState(() => _job = job);
    void progress(int sent, int total) {
      if (!mounted || !identical(_job, job)) return;
      setState(() => job.progress = total <= 0 ? 0 : sent / total);
    }

    try {
      final PhotoUploadResult r;
      if (private) {
        final t = thumb ?? await p.picker.thumbnail(photo);
        job.thumb = t;
        r = await p.uploadPrivate(photo, t, cancel: job.cancel, onProgress: progress);
      } else {
        r = await p.upload(photo.bytes, cancel: job.cancel, onProgress: progress);
      }
      if (!mounted || !identical(_job, job)) return;
      if (_linkFits(r.url)) {
        _insertLink(r.url);
        AppHaptics.light();
      } else {
        AppHaptics.warning();
        setState(() => _job = _PhotoJob(_PhotoStage.waitingForRoom, photo: photo, result: r));
      }
    } on PhotoPrepareException catch (e) {
      if (!mounted || !identical(_job, job)) return;
      setState(() => _job = _PhotoJob(_PhotoStage.failed, photo: photo, thumb: job.thumb, error: e.message, retryable: false));
    } on PhotoError catch (e) {
      if (!mounted || !identical(_job, job)) return;
      setState(() => _job = e.kind == PhotoErrorKind.cancelled ? null : _PhotoJob(_PhotoStage.failed, photo: photo, thumb: job.thumb, error: e.message, retryable: e.kind != PhotoErrorKind.tooLarge && e.kind != PhotoErrorKind.notImage));
    } catch (_) {
      if (!mounted || !identical(_job, job)) return;
      setState(() => _job = _PhotoJob(_PhotoStage.failed, photo: photo, error: const PhotoError(PhotoErrorKind.server).message));
    }
  }

  void _dropPhoto() {
    _job?.cancel.cancel();
    setState(() => _job = null);
  }

  Widget _photoStrip(AppColors colors) {
    final j = _job!;
    final bytes = j.photo?.bytes;
    final String text;
    Color tone = colors.textMuted;
    switch (j.stage) {
      case _PhotoStage.preparing:
        text = 'Preparing photo';
      case _PhotoStage.uploading:
        // progress counts bytes the network took; at 1 the body is out and the server's answer is awaited.
        text = j.progress >= 1 ? 'Processing…' : 'Uploading photo ${(j.progress * 100).round()}%';
      case _PhotoStage.waitingForRoom:
        final n = _bytesToCut(j.result!.url);
        text = 'Photo uploaded. Its link needs ${utf8.encode(j.result!.url).length + 1} bytes: cut $n ${n == 1 ? 'byte' : 'bytes'} from your message to add it.';
        tone = colors.warning;
      case _PhotoStage.failed:
        text = j.error ?? 'Upload failed.';
        tone = colors.danger;
    }
    Widget btn(Key key, String label, VoidCallback onTap) => CupertinoButton(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: Gap.s),
          minimumSize: Size.square(Hit.of(context)),
          onPressed: onTap,
          child: Text(label, style: AppType.footnote.copyWith(color: colors.accent, fontWeight: FontWeight.w600)),
        );
    return Padding(
      key: const Key('composer-photo-strip'),
      padding: const EdgeInsets.only(left: Gap.s, bottom: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 40,
            height: 40,
            child: bytes == null
                ? ColoredBox(color: colors.surfaceHigh, child: const Center(child: CupertinoActivityIndicator()))
                : Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 120, gaplessPlayback: true),
          ),
        ),
        const SizedBox(width: Gap.s),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, key: const Key('composer-photo-status'), style: AppType.footnote.copyWith(color: tone)),
            if (j.stage == _PhotoStage.uploading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  key: const Key('composer-photo-progress'),
                  height: 3,
                  decoration: BoxDecoration(color: colors.outline.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: j.progress.clamp(0.0, 1.0),
                    child: Container(decoration: BoxDecoration(color: colors.accent, borderRadius: BorderRadius.circular(2))),
                  ),
                ),
              ),
          ]),
        ),
        if (j.stage == _PhotoStage.uploading) btn(const Key('composer-photo-cancel'), 'Cancel', _dropPhoto),
        if (j.stage == _PhotoStage.failed && j.retryable && j.photo != null) btn(const Key('composer-photo-retry'), 'Retry', () => _upload(j.photo!, thumb: j.thumb)),
        if (j.stage == _PhotoStage.failed || j.stage == _PhotoStage.waitingForRoom) btn(const Key('composer-photo-remove'), 'Remove', _dropPhoto),
      ]),
    );
  }

  /// "@par" right before the cursor: the partial name, or null.
  String? get _mentionQuery {
    if (widget.mentionNames.isEmpty) return null;
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : _text.text.length;
    final m = RegExp(r'(?:^|\s)@([^\s@\[\]]*)$').firstMatch(_text.text.substring(0, at));
    return m?.group(1);
  }

  void _pickMention(String name) {
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : _text.text.length;
    final before = _text.text.substring(0, at);
    final i = before.lastIndexOf('@');
    if (i < 0) return;
    final ins = '@[$name] ';
    _text.value = TextEditingValue(text: _text.text.replaceRange(i, at, ins), selection: TextSelection.collapsed(offset: i + ins.length));
    _focus.requestFocus();
  }

  Future<void> _editReplies() async {
    await showQuickRepliesSheet(context, store: c.store);
    if (mounted) setState(() => _replies = loadQuickReplies(c.store));
  }

  @override
  Widget build(BuildContext context) {
    if (c.composerLocked) return _LockedComposer(controller: c);
    final colors = AppColors.of(context);
    final max = c.service.maxTextBytes(widget.convKey);
    final b = ByteBudget.of(_text.text, max);
    final offAir = widget.onChannelInfoWhenOffRadio != null;
    final canSend = c.hasRadioIdentity && !offAir && b.used > 0 && !b.over;
    final showPhoto = !offAir && (widget.photos?.buttonFor(_privatePhoto ? PhotoKind.private : PhotoKind.plain) ?? PhotoButton.hidden) != PhotoButton.hidden;
    final mention = _mentionQuery;
    final mentionHits = mention == null ? const <String>[] : [for (final n in widget.mentionNames) if (n.toLowerCase().startsWith(mention.toLowerCase())) n].take(8).toList();

    // The strip slot: mention names while typing "@", else the quick replies when switched on. One line, 44 pt chips.
    Widget? strip;
    if (mention != null && mentionHits.isNotEmpty) {
      strip = _Strip(key: const Key('mention-strip'), children: [
        for (final n in mentionHits) _Chip(key: Key('mention-$n'), label: n, onTap: () => _pickMention(n)),
      ]);
    } else if (_chips) {
      strip = _Strip(key: const Key('quick-strip'), children: [
        for (final r in _replies) _Chip(key: Key('quick-$r'), label: r, onTap: () => _insert(r)),
        _Chip(key: const Key('quick-edit'), label: 'Edit', muted: true, onTap: _editReplies),
      ]);
    }

    final note = offAir
        ? 'This channel is not on your radio, so nothing can be sent or received.'
        : (!c.hasRadioIdentity ? 'Connect your radio once to start chatting.' : (!c.radioConnected ? 'Will send when radio connects' : null));

    final bar = Container(
      decoration: BoxDecoration(
        color: Blur.opaque(context) ? colors.surface : colors.surface.withValues(alpha: Blur.backgroundOpacity),
        border: Border(top: BorderSide(color: colors.outline.withValues(alpha: 0.35), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.s, Gap.xs, Gap.s, Gap.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_trimmed)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.m, bottom: Gap.xs),
                  child: Text('Trimmed to fit', key: const Key('composer-trimmed'), style: AppType.footnote.copyWith(color: colors.warning)),
                ),
              ?strip,
              if (_job != null) _photoStrip(colors),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.m, bottom: Gap.xs),
                  child: Row(children: [
                    Flexible(child: Text(note, key: const Key('composer-offline'), style: AppType.footnote.copyWith(color: colors.textMuted))),
                    if (offAir)
                      CupertinoButton(
                        key: const Key('composer-channel-info'),
                        padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                        minimumSize: Size.square(Hit.of(context)),
                        onPressed: widget.onChannelInfoWhenOffRadio,
                        child: Text('Put it back on the radio', style: AppType.footnote.copyWith(color: colors.accent, fontWeight: FontWeight.w600)),
                      ),
                  ]),
                ),
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => canSend ? _send() : null,
                  // "Return sends" (More > Chat): a plain Return from a hardware keyboard sends; Shift-Return stays a new line.
                  if (loadReturnSends(c.store)) const SingleActivator(LogicalKeyboardKey.enter): () => canSend ? _send() : null,
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _RoundButton(
                      key: const Key('composer-quick'),
                      symbol: AppSymbols.message,
                      label: _chips ? 'Hide quick replies' : 'Quick replies',
                      selected: _chips,
                      onTap: () => setState(() => _chips = !_chips),
                    ),
                    if (showPhoto)
                      _RoundButton(
                        key: const Key('composer-photo'),
                        symbol: AppSymbols.camera,
                        label: 'Send a photo',
                        onTap: _photoTapped,
                      ),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(color: colors.surfaceHigh, borderRadius: BorderRadius.circular(22)),
                        constraints: BoxConstraints(minHeight: Hit.of(context)),
                        child: CupertinoTextField(
                          key: const Key('composer-field'),
                          controller: _text,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 5,
                          enabled: !offAir,
                          placeholder: widget.hint,
                          placeholderStyle: AppType.body.copyWith(color: colors.textMuted),
                          style: AppType.body.copyWith(color: colors.textPrimary),
                          cursorColor: colors.accent,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          decoration: null,
                          textCapitalization: TextCapitalization.sentences,
                          keyboardType: TextInputType.multiline,
                          inputFormatters: [ByteLimitFormatter(maxBytes: () => c.service.maxTextBytes(widget.convKey), onTrimmed: _onTrimmed)],
                        ),
                      ),
                    ),
                    _SendButton(budget: b, enabled: canSend, offline: !c.radioConnected, onTap: _send, onLongPress: _direct ? _chooseRoute : null),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.m, top: 2),
                  child: Text(_error!, key: const Key('composer-error'), style: AppType.footnote.copyWith(color: colors.danger)),
                ),
            ],
          ),
        ),
      ),
    );

    if (Blur.opaque(context)) return bar;
    return ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: Blur.sigma, sigmaY: Blur.sigma), child: bar));
  }
}

enum _PhotoStage { preparing, uploading, waitingForRoom, failed }

/// The photo being sent from this composer: what it is doing and what the person can do about it.
class _PhotoJob {
  final _PhotoStage stage;
  final PreparedPhoto? photo;

  /// The small copy of a private photo, kept so a retry does not redo it.
  PreparedPhoto? thumb;
  final PhotoUploadResult? result;
  final String? error;
  final bool retryable;
  final PhotoCancel cancel = PhotoCancel();
  double progress = 0;
  _PhotoJob(this.stage, {this.photo, this.thumb, this.result, this.error, this.retryable = true});
}

class _Strip extends StatelessWidget {
  final List<Widget> children;
  const _Strip({super.key, required this.children});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Hit.of(context),
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: Gap.xs), children: children),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool muted;
  const _Chip({super.key, required this.label, required this.onTap, this.muted = false});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: Gap.s),
      child: Center(
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.square(Hit.of(context)),
          onPressed: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.chip + 4)),
            child: Text(label, style: AppType.subhead.copyWith(color: muted ? c.textMuted : c.textPrimary)),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final AppSymbol symbol;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RoundButton({super.key, required this.symbol, required this.label, required this.onTap, this.selected = false});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      excludeSemantics: true,
      onTap: onTap,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.square(Hit.of(context)),
        onPressed: onTap,
        child: AppSymbolIcon(symbol, size: 24, color: selected ? c.accent : c.textMuted),
      ),
    );
  }
}

/// 32 pt send button inside a 44 pt target. The ring around it fills with the bytes used; at 20 or fewer left the number
/// replaces the arrow (tabular, 11 pt floor); orange at 10 or fewer, red at 0.
class _SendButton extends StatelessWidget {
  final ByteBudget budget;
  final bool enabled;
  final bool offline;
  final VoidCallback onTap;

  /// Direct messages only: choose direct or flood (CR2).
  final VoidCallback? onLongPress;
  const _SendButton({required this.budget, required this.enabled, required this.offline, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final level = budget.level;
    final ringColor = switch (level) {
      BudgetLevel.full => c.danger,
      BudgetLevel.warning => c.warning,
      _ => c.accent,
    };
    final fill = enabled ? c.accent : c.surfaceHigh;
    final ink = enabled ? c.onAccent : c.textMuted;
    final Widget inner = budget.showNumber
        ? Text('${budget.left < 0 ? 0 : budget.left}', key: const Key('composer-left'), style: AppType.num(12, weight: FontWeight.w700).copyWith(color: ink))
        : AppSymbolIcon(offline ? AppSymbols.clock : AppSymbols.arrowUpCircleFill, size: 18, color: ink, scaleWithText: false);
    final label = budget.full ? 'Send. No bytes left' : (budget.showNumber ? 'Send. ${budget.left} bytes left' : 'Send');
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: GestureDetector(
        key: const Key('composer-send'),
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
        child: SizedBox(
          width: Hit.of(context),
          height: Hit.of(context),
          child: Center(
            child: CustomPaint(
              painter: _RingPainter(fraction: budget.showRing ? budget.fraction : 0, color: ringColor, track: c.outline.withValues(alpha: 0.25)),
              child: Container(
                key: const Key('composer-ring'),
                width: 36,
                height: 36,
                alignment: Alignment.center,
                child: Container(width: 30, height: 30, decoration: BoxDecoration(color: fill, shape: BoxShape.circle), alignment: Alignment.center, child: inner),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final Color color, track;
  _RingPainter({required this.fraction, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    if (fraction <= 0) return;
    final rect = Offset.zero & size;
    final r = rect.deflate(1.5);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * fraction, false, p..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color || old.track != track;
}

/// What replaces the composer while the car is moving.
class _LockedComposer extends StatelessWidget {
  final ChatController controller;
  const _LockedComposer({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // At the largest text sizes the notice is taller than the room under the messages: cap it and let it scroll.
    return Container(
      key: const Key('composer-locked'),
      color: c.surfaceHigh,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
      child: SingleChildScrollView(
        child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppSymbolIcon(AppSymbols.carFill, color: c.textPrimary),
                const SizedBox(width: Gap.m),
                Expanded(child: Text('Typing is off while the car is moving. Messages still arrive here.', style: AppType.callout.copyWith(color: c.textPrimary))),
              ]),
              const SizedBox(height: Gap.s),
              CupertinoButton.filled(
                key: const Key('passenger-button'),
                minimumSize: Size.square(Hit.of(context)),
                onPressed: () => controller.setPassenger(true),
                child: const Text("I'm a passenger"),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
