// Edit the quick replies (chat plan 4.3): the six chips above the composer. Stored in the chat settings (`quick_replies`).
import 'package:flutter/cupertino.dart';

import '../../chat/quick_replies.dart';
import '../../chat/store.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';

Future<void> showQuickRepliesSheet(BuildContext context, {required ChatStore store}) {
  return showAppSheet<void>(
    context,
    detents: const [0.6, 0.92],
    builder: (ctx, scroll) => _QuickRepliesBody(store: store, controller: scroll),
  );
}

class _QuickRepliesBody extends StatefulWidget {
  final ChatStore store;
  final ScrollController controller;
  const _QuickRepliesBody({required this.store, required this.controller});
  @override
  State<_QuickRepliesBody> createState() => _QuickRepliesBodyState();
}

class _QuickRepliesBodyState extends State<_QuickRepliesBody> {
  late List<String> _items = List.of(loadQuickReplies(widget.store));
  final _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  void _save() => saveQuickReplies(widget.store, _items);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppSheetScaffold(
      controller: widget.controller,
      title: 'Quick replies',
      secondaryAction: CupertinoButton(
        key: const Key('quick-reset'),
        onPressed: () => setState(() {
          _items = List.of(defaultQuickReplies);
          _save();
        }),
        child: const Text('Reset to the standard six'),
      ),
      children: [
        for (var i = 0; i < _items.length; i++)
          Container(
            key: Key('quick-row-$i'),
            constraints: BoxConstraints(minHeight: Hit.of(context)),
            child: Row(children: [
              Expanded(child: Text(_items[i], style: AppType.body.copyWith(color: c.textPrimary))),
              CupertinoButton(
                key: Key('quick-delete-$i'),
                padding: EdgeInsets.zero,
                minimumSize: Size.square(Hit.of(context)),
                onPressed: () => setState(() {
                  _items.removeAt(i);
                  _save();
                }),
                child: Semantics(label: 'Remove ${_items[i]}', child: AppSymbolIcon(AppSymbols.xmarkCircleFill, color: c.textMuted)),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s),
          child: CupertinoTextField(
            key: const Key('quick-add-field'),
            controller: _add,
            placeholder: 'Add a quick reply',
            maxLength: 60,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) {
              final t = v.trim();
              if (t.isEmpty) return;
              setState(() {
                _items.add(t);
                _add.clear();
                _save();
              });
            },
          ),
        ),
      ],
    );
  }
}
