// Console: the radio's own command line (RUN_CLI_COMMAND 66, firmware 1.18+). Type a line, see the reply; tap a past line to
// put it back in the box. Lines that reboot, erase or reveal the key never leave the phone (blockedCliReason).
import 'package:flutter/material.dart';

import '../../radio/tools/device_settings.dart';
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

  Future<void> _run() async {
    final line = _c.text.trim();
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
                    child: Text('Commands run on this radio itself. Try ver or get name. Commands that reboot or erase the radio, or show its key, are not sent from here.',
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
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('> ${e.line}', style: mono.copyWith(color: c.primary)),
                            if (e.reply == null) Text('...', style: mono) else Text(e.reply!, style: mono.copyWith(color: e.error ? c.error : c.onSurface)),
                          ]),
                        ),
                      );
                    },
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
                  onSubmitted: (_) => _run(),
                ),
              ),
              IconButton(key: const Key('console-send'), onPressed: _busy ? null : _run, icon: const Icon(Icons.arrow_upward), tooltip: 'Send'),
            ]),
          ),
        ]),
      ),
    );
  }
}
