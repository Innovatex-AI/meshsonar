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
import '../../chat/quick_replies.dart';
import '../../chat/send_budget.dart';
import '../alerts/permission_prompt.dart';
import '../design/app_haptics.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
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

  const Composer({super.key, required this.controller, required this.convKey, this.hint = 'Message', this.mentionNames = const [], this.onSent, this.onChannelInfoWhenOffRadio});

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

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: c.service.loadDraft(widget.convKey) ?? '');
    _text.addListener(_onChanged);
    c.addListener(_onController);
    _replies = loadQuickReplies(c.store);
    _level = ByteBudget.of(_text.text, c.service.maxTextBytes(widget.convKey)).level;
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

  void _send() {
    final res = c.send(widget.convKey, _text.text);
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
                bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => canSend ? _send() : null},
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
                    _SendButton(budget: b, enabled: canSend, offline: !c.radioConnected, onTap: _send),
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
  const _SendButton({required this.budget, required this.enabled, required this.offline, required this.onTap});

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
    return Container(
      key: const Key('composer-locked'),
      color: c.surfaceHigh,
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
    );
  }
}
