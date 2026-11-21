// The header of a page shown IN PLACE inside a Network section (a link opened an analytics tab, a site page or a tool):
// 48 pt, a back arrow to the section's list, the title, and the page's own actions. The page sits under it inside the
// section, so the section strip and the bottom tab bar stay usable and a later link to another section is not hidden
// under a pushed page.
import 'package:flutter/material.dart';

class InPlaceHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  /// What the back arrow says to a screen reader ("Back to Tools").
  final String backLabel;
  final List<Widget> actions;
  const InPlaceHeader({super.key, required this.title, required this.onBack, this.backLabel = 'Back to the list', this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(children: [
          IconButton(
            key: const Key('in-place-back'),
            tooltip: backLabel,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(child: Semantics(header: true, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium))),
          ...actions,
        ]),
      ),
    );
  }
}

/// A native tool page in either form: its own screen (app bar, pushed over the tab) when [onClose] is null, or in place
/// inside a section under an [InPlaceHeader] when it is given.
class ToolFrame extends StatelessWidget {
  final Key? frameKey;
  final String title;
  final VoidCallback? onClose;
  final String backLabel;
  final Widget body;
  const ToolFrame({super.key, this.frameKey, required this.title, required this.body, this.onClose, this.backLabel = 'Back to Tools'});

  @override
  Widget build(BuildContext context) {
    final close = onClose;
    if (close == null) return Scaffold(key: frameKey, appBar: AppBar(title: Text(title)), body: SafeArea(child: body));
    return Material(
      key: frameKey,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(children: [InPlaceHeader(title: title, onBack: close, backLabel: backLabel), Expanded(child: body)]),
    );
  }
}
