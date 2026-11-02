// The message composer: live byte counter, draft autosave, mention helper, and the passenger lock (design 1.3).
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoListTile;
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../alerts/permission_prompt.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../theme.dart';
import 'message_format.dart';

class Composer extends StatefulWidget {
  final ChatController controller;
  final String convKey;
  final String hint;

  /// Names offered by the "@" button (recent senders of a channel). Empty hides the button.
  final List<String> mentionNames;
  final VoidCallback? onSent;

  const Composer({super.key, required this.controller, required this.convKey, this.hint = 'Message', this.mentionNames = const [], this.onSent});

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  String? _error;

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: c.service.loadDraft(widget.convKey) ?? '');
    _text.addListener(_onChanged);
    c.addListener(_onController);
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _onChanged() {
    _error = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _saveDraft);
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
    c.removeListener(_onController);
    try {
      // Straight to the store: no event while the widget tree is being torn down.
      c.store.drafts.save(widget.convKey, _text.text, c.now().millisecondsSinceEpoch);
    } catch (_) {}
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final res = c.send(widget.convKey, _text.text);
    if (res.ok) {
      _text.clear();
      setState(() => _error = null);
      widget.onSent?.call();
      // First message sent: the right moment to explain alerts (once; never at launch).
      unawaited(offerAlertsAfterFirstAction(context));
    } else {
      setState(() => _error = res.error);
    }
  }

  Future<void> _mention() async {
    final name = await showAppSheet<String>(
      context,
      detents: const [0.5],
      builder: (ctx, controller) => AppSheetScaffold(
        controller: controller,
        title: 'Mention someone',
        children: [
          for (final n in widget.mentionNames)
            CupertinoListTile(
              key: Key('mention-$n'),
              leading: const AppSymbolIcon(AppSymbols.person, size: 20),
              title: Text(n),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : _text.text.length;
    final ins = '@[$name] ';
    _text.value = TextEditingValue(text: _text.text.replaceRange(at, sel.isValid ? sel.end : at, ins), selection: TextSelection.collapsed(offset: at + ins.length));
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    if (c.composerLocked) return _LockedComposer(controller: c);

    final max = c.service.maxTextBytes(widget.convKey);
    final used = utf8Len(_text.text.trim());
    final over = used > max;
    final canSend = c.hasRadioIdentity && used > 0 && !over;
    return Material(
      color: cs.surface,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.s, Gap.s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!c.radioConnected)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Text(
                    c.hasRadioIdentity
                        ? 'Radio not connected. Your message waits and goes out when it is back.'
                        : 'Connect your radio once to start chatting.',
                    key: const Key('composer-offline'),
                    style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.mentionNames.isNotEmpty)
                    IconButton(
                      key: const Key('composer-mention'),
                      tooltip: 'Mention someone',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _mention,
                      icon: const Icon(Icons.alternate_email_rounded),
                    ),
                  Expanded(
                    child: TextField(
                      key: const Key('composer-field'),
                      controller: _text,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        constraints: const BoxConstraints(minHeight: 48),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(Corners.card)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
                      ),
                    ),
                  ),
                  IconButton.filled(
                    key: const Key('composer-send'),
                    tooltip: 'Send',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: canSend ? _send : null,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: Gap.xs, top: 2),
                child: Semantics(
                  label: '$used of $max bytes used',
                  child: ExcludeSemantics(
                    child: Text(
                      '$used / $max bytes${over ? ': too long' : ''}',
                      key: const Key('composer-counter'),
                      style: t.textTheme.labelSmall?.copyWith(color: over ? cs.error : cs.onSurfaceVariant, fontWeight: over ? FontWeight.w700 : null),
                    ),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(_error!, key: const Key('composer-error'), style: t.textTheme.bodySmall?.copyWith(color: cs.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What replaces the composer while the car is moving.
class _LockedComposer extends StatelessWidget {
  final ChatController controller;
  const _LockedComposer({required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      key: const Key('composer-locked'),
      color: t.colorScheme.secondaryContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.directions_car_rounded, color: t.colorScheme.onSecondaryContainer),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Text('Typing is off while the car is moving. Messages still arrive here.',
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSecondaryContainer)),
                ),
              ]),
              const SizedBox(height: Gap.s),
              FilledButton(
                key: const Key('passenger-button'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => controller.setPassenger(true),
                child: const Text('I\'m a passenger'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
