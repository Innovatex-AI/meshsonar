// Console for people who know the CLI. Read-only commands run at once. A command that changes something becomes the same
// review-and-confirm sheet as the settings form. Anything MeshSonar does not know, or that is dangerous, is refused with the
// reason and never sent. Replies are shown with secrets removed.
import 'package:flutter/material.dart';

import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_settings.dart' show Confirmation;
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';
import 'setting_editor_sheet.dart';

class _Line {
  final String text;
  final _Kind kind;
  const _Line(this.text, this.kind);
}

enum _Kind { you, reply, refused }

class AdminConsoleView extends StatefulWidget {
  final RepeaterAdminController controller;
  const AdminConsoleView({super.key, required this.controller});
  @override
  State<AdminConsoleView> createState() => _AdminConsoleViewState();
}

class _AdminConsoleViewState extends State<AdminConsoleView> {
  final _in = TextEditingController();
  final _scroll = ScrollController();
  final List<_Line> _lines = [];
  bool _busy = false;

  RepeaterAdminController get c => widget.controller;

  @override
  void dispose() {
    _in.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _add(String text, _Kind k) {
    setState(() => _lines.add(_Line(text, k)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send([String? preset]) async {
    final line = (preset ?? _in.text).trim();
    if (line.isEmpty || _busy) return;
    _in.clear();
    _add('> ${redactCommandForShow(line)}', _Kind.you);
    setState(() => _busy = true);
    try {
      final r = await c.session.console(line);
      if (!mounted) return;
      switch (r) {
        case ConsoleReply():
          _add(r.text.isEmpty ? '(empty reply)' : r.text, _Kind.reply);
        case ConsoleRefused():
          _add('Not sent: ${r.reason}', _Kind.refused);
        case ConsolePlan():
          _add('This changes a setting. Review it to go on.', _Kind.reply);
          await showSettingEditor(context, c, r.plan.def, startAtReview: r.plan);
        case ConsoleAction():
          final ok = await confirmAction(context, title: 'Send "${r.command}"?', body: r.consequence, confirmLabel: 'Send', confirmKey: const Key('console-action-confirm'));
          if (ok && mounted) {
            try {
              final res = await c.session.runConsoleAction(r, Confirmation.yes);
              _add(res.message, res.ok ? _Kind.reply : _Kind.refused);
            } on AdminException catch (e) {
              _add(e.message, _Kind.refused);
            }
          } else {
            _add('Cancelled.', _Kind.reply);
          }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A typed `password ...` or `set ...password ...` is shown masked in the history too.
  static String redactCommandForShow(String l) {
    final parts = l.split(' ');
    if (parts.isNotEmpty && parts[0] == 'password') return 'password ••••';
    if (parts.length >= 3 && parts[0] == 'set' && parts[1].contains('password')) return 'set ${parts[1]} ••••';
    return l;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (!c.isAdmin) {
      return const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: Text('The console needs the admin password.', key: Key('console-guest'), textAlign: TextAlign.center)));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          key: const Key('admin-console'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
              child: Text(
                  'Read-only commands run at once. Anything that changes a setting asks you to confirm first. The repeater answers in up to 160 characters, and each command uses airtime.',
                  style: t.textTheme.bodyMedium?.copyWith(height: 1.3)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
              child: Wrap(spacing: Gap.s, runSpacing: 0, children: [
                for (final q in const ['ver', 'board', 'clock', 'get radio', 'get tx', 'neighbors', 'region'])
                  ActionChip(key: Key('console-q-$q'), label: Text(q), onPressed: _busy ? null : () => _send(q)),
              ]),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: Gap.l),
                padding: const EdgeInsets.all(Gap.m),
                decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.chip)),
                child: _lines.isEmpty
                    ? Text('Nothing yet. Try "ver" or "get radio".', style: t.textTheme.bodyMedium)
                    : ListView.builder(
                        key: const Key('console-history'),
                        controller: _scroll,
                        itemCount: _lines.length,
                        itemBuilder: (_, i) {
                          final l = _lines[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: SelectableText(l.text,
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 14,
                                    height: 1.3,
                                    fontWeight: l.kind == _Kind.you ? FontWeight.w700 : FontWeight.w400,
                                    color: l.kind == _Kind.refused ? t.colorScheme.error : t.colorScheme.onSurface)),
                          );
                        },
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('console-input'),
                    controller: _in,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Command, for example get radio'),
                  ),
                ),
                const SizedBox(width: Gap.s),
                IconButton.filled(
                  key: const Key('console-send'),
                  tooltip: 'Send',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: _busy ? null : _send,
                  icon: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
