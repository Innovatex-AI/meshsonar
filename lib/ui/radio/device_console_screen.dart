// Console: the radio's own command line (RUN_CLI_COMMAND 66, firmware 1.18+). Type a line, see the reply; tap a past line to
// put it back in the box. Lines that reboot, erase or reveal the key never leave the phone (blockedCliReason).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../radio/tools/device_settings.dart';
import '../design/app_surfaces.dart' show showAppToast;
import '../design/tokens.dart';
import '../theme.dart' show numberStyle;

class DeviceConsoleScreen extends StatefulWidget {
  final DeviceSettingsTool tool;
  const DeviceConsoleScreen({super.key, required this.tool});
  @override
  State<DeviceConsoleScreen> createState() => _DeviceConsoleScreenState();
}

class _Entry {
  final String line;
  String? reply;
  bool error = false;
  _Entry(this.line);
}

class _DeviceConsoleScreenState extends State<DeviceConsoleScreen> {
  final _c = TextEditingController();
  final _entries = <_Entry>[];
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Commands that only read, offered as one-tap chips (build 76): nobody should have to know what to type first.
  static const quick = ['ver', 'get name'];

  Future<void> _run([String? preset]) async {
    final line = (preset ?? _c.text).trim();
    if (line.isEmpty || _busy) return;
    final e = _Entry(line);
    setState(() {
      _entries.add(e);
      _busy = true;
      _c.clear();
    });
    final r = await widget.tool.runCli(line);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.failure != null) {
        e.reply = r.failure!.message;
        e.error = true;
      } else {
        e.reply = r.reply!.isEmpty ? '(no output)' : r.reply;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final mono = numberStyle(context, size: 14);
    return Scaffold(
      key: const Key('device-console'),
      appBar: AppBar(title: const Text('Console')),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Layout.screenMargin),
                    child: Text('Type a command for this radio, or tap one below. Commands that restart or erase it, or show its key, are never sent.',
                        key: const Key('console-empty'), style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                  )
                : ListView.builder(
                    key: const Key('console-list'),
                    reverse: true,
                    padding: const EdgeInsets.all(Layout.screenMargin),
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[_entries.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: Gap.m),
                        child: InkWell(
                          onTap: () => setState(() => _c.text = e.line),
                          // Press and hold copies the reply (build 76): it could not be selected or shared before.
                          onLongPress: e.reply == null
                              ? null
                              : () async {
                                  await Clipboard.setData(ClipboardData(text: e.reply!));
                                  if (context.mounted) showAppToast(context, 'Reply copied.');
                                },
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('> ${e.line}', style: mono.copyWith(color: c.primary)),
                            if (e.reply == null) Text('...', style: mono) else Text(e.reply!, style: mono.copyWith(color: e.error ? c.error : c.onSurface)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(
            height: Hit.min + Gap.s,
            child: ListView(
              key: const Key('console-quick'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
              children: [
                for (final q in quick)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.s),
                    child: Center(child: ActionChip(key: Key('console-q-$q'), label: Text(q, style: mono), onPressed: _busy ? null : () => _run(q))),
                  ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.outlineVariant))),
            padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Gap.s, Gap.s),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('console-input'),
                  controller: _c,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(hintText: 'Command', border: InputBorder.none),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _run(),
                ),
              ),
              // Off while the box is empty or a command is running, so a tap never looks like it did nothing.
              IconButton.filled(
                key: const Key('console-send'),
                constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
                onPressed: _busy || _c.text.trim().isEmpty ? null : () => _run(),
                icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward),
                tooltip: 'Send',
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
