// The sheets behind the Device settings rows: telemetry sharing, path hash size, auto-add, Bluetooth PIN, encrypted backup,
// restore, factory reset. Each sheet only collects and validates; the screen runs the write through DeviceSettingsTool.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/backup.dart';
import '../../chat/backup_crypto.dart';
import '../../radio/inbound.dart' show ContactPolicy;
import '../../radio/protocol.dart' show TelemetryModes;
import '../../radio/tools/device_settings.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_widgets.dart';
import '../design/tokens.dart';

Widget _help(BuildContext context, String text, {Key? key, bool warn = false}) {
  final t = Theme.of(context);
  final c = warn ? t.colorScheme.error : t.colorScheme.onSurfaceVariant;
  return Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: Gap.m),
    child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: c)),
  );
}

Widget _choice(BuildContext context, {required Key key, required String label, String? sub, required bool selected, required VoidCallback onTap}) {
  final t = Theme.of(context);
  return Semantics(
    button: true,
    selected: selected,
    label: sub == null ? label : '$label. $sub',
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      key: key,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Hit.min),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: t.textTheme.bodyLarge),
                if (sub != null) Text(sub, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
            if (selected) AppSymbolIcon(AppSymbols.checkmark, size: 20, color: t.colorScheme.primary),
          ]),
        ),
      ),
    ),
  );
}

Widget _primary(String label, VoidCallback? onTap, {Key? key, bool destructive = false, bool busy = false}) => Builder(builder: (context) {
      final c = Theme.of(context).colorScheme;
      return FilledButton(
        key: key,
        style: destructive ? FilledButton.styleFrom(backgroundColor: c.error, foregroundColor: c.onError) : null,
        onPressed: busy ? null : onTap,
        child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(label),
      );
    });

// ------------------------------------------------------------------------------------------------ telemetry sharing

Future<TelemetryModes?> showTelemetrySheet(BuildContext context, TelemetryModes current) => showAppSheet<TelemetryModes>(
      context,
      detents: const [0.92],
      builder: (ctx, scroll) => _TelemetrySheet(scroll: scroll, current: current),
    );

class _TelemetrySheet extends StatefulWidget {
  final ScrollController scroll;
  final TelemetryModes current;
  const _TelemetrySheet({required this.scroll, required this.current});
  @override
  State<_TelemetrySheet> createState() => _TelemetrySheetState();
}

class _TelemetrySheetState extends State<_TelemetrySheet> {
  late TelemetryModes m = widget.current;

  Widget _group(String key, String title, int value, ValueChanged<int> set) {
    final t = Theme.of(context);
    const labels = ['Nobody', 'Contacts I allow', 'Everyone'];
    const subs = [null, 'Only contacts with the telemetry permission on this radio.', null];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: Gap.m, bottom: Gap.xs), child: Text(title, style: t.textTheme.titleMedium)),
      for (var i = 0; i < 3; i++) _choice(context, key: Key('tel-$key-$i'), label: labels[i], sub: subs[i], selected: value == i, onTap: () => set(i)),
    ]);
  }

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.scroll,
        title: 'Who can request my telemetry',
        primaryAction: _primary('Save', m == widget.current ? null : () => Navigator.pop(context, m), key: const Key('tel-save')),
        children: [
          _help(context, 'Telemetry is what your radio reports when another node asks: battery and board basics, its position, and sensor readings. '
              'Your radio answers only the way you set here.'),
          _group('base', 'Battery and basics', m.base, (v) => setState(() => m = m.copyWith(base: v))),
          _group('loc', 'Position', m.location, (v) => setState(() => m = m.copyWith(location: v))),
          _group('env', 'Sensors', m.env, (v) => setState(() => m = m.copyWith(env: v))),
        ],
      );
}

// ------------------------------------------------------------------------------------------------ path hash size

Future<int?> showPathHashSheet(BuildContext context, int? current) => showAppSheet<int>(
      context,
      detents: const [0.92],
      builder: (ctx, scroll) => _PathHashSheet(scroll: scroll, current: current),
    );

class _PathHashSheet extends StatefulWidget {
  final ScrollController scroll;
  final int? current;
  const _PathHashSheet({required this.scroll, required this.current});
  @override
  State<_PathHashSheet> createState() => _PathHashSheetState();
}

class _PathHashSheetState extends State<_PathHashSheet> {
  late int? v = widget.current;
  @override
  Widget build(BuildContext context) {
    const subs = {
      1: 'Compatible with every repeater. Up to 64 hops.',
      2: 'Fewer wrong guesses in busy meshes. Up to 32 hops. Needs repeater firmware 1.14 or newer.',
      3: 'Fewest wrong guesses. Up to 21 hops. Needs repeater firmware 1.14 or newer.',
    };
    return AppSheetScaffold(
      controller: widget.scroll,
      title: 'Path hash size',
      primaryAction: _primary('Apply', v == null || v == widget.current ? null : () => Navigator.pop(context, v), key: const Key('hash-apply')),
      children: [
        _help(context, 'How many bytes of each repeater\'s identity your radio writes into the routes it builds.'),
        _help(context, 'Repeaters older than firmware 1.14 silently drop packets with 2 or 3 byte hashes. Change this only when the repeaters around you were updated.', warn: true, key: const Key('hash-warning')),
        for (final n in [1, 2, 3]) _choice(context, key: Key('hash-$n'), label: '$n byte${n > 1 ? 's' : ''}', sub: subs[n], selected: v == n, onTap: () => setState(() => v = n)),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ auto-add

Future<ContactPolicy?> showAutoAddSheet(BuildContext context, ContactPolicy current, {required bool hopsAndOverwrite}) => showAppSheet<ContactPolicy>(
      context,
      detents: const [0.92],
      builder: (ctx, scroll) => _AutoAddSheet(scroll: scroll, current: current, hopsAndOverwrite: hopsAndOverwrite),
    );

class _AutoAddSheet extends StatefulWidget {
  final ScrollController scroll;
  final ContactPolicy current;
  final bool hopsAndOverwrite;
  const _AutoAddSheet({required this.scroll, required this.current, required this.hopsAndOverwrite});
  @override
  State<_AutoAddSheet> createState() => _AutoAddSheetState();
}

class _AutoAddSheetState extends State<_AutoAddSheet> {
  late ContactPolicy p = widget.current;
  static const hops = <int, String>{0: 'Any distance', 1: 'Direct only', 2: 'Up to 1 repeater', 3: 'Up to 2 repeaters', 4: 'Up to 3 repeaters', 6: 'Up to 5 repeaters'};

  Widget _sw(String key, String title, bool v, ValueChanged<bool> set, {String? sub}) => AppSwitchTile(key: Key(key), title: title, subtitle: sub, value: v, onChanged: set, switchKey: Key('$key-switch'));

  @override
  Widget build(BuildContext context) {
    final changed = p.autoAddChat != widget.current.autoAddChat ||
        p.autoAddRepeaters != widget.current.autoAddRepeaters ||
        p.autoAddRooms != widget.current.autoAddRooms ||
        p.autoAddSensors != widget.current.autoAddSensors ||
        p.overwriteOldest != widget.current.overwriteOldest ||
        p.maxHops != widget.current.maxHops;
    return AppSheetScaffold(
      controller: widget.scroll,
      title: widget.hopsAndOverwrite ? 'Distance and a full list' : 'Add by type',
      primaryAction: _primary('Save', changed ? () => Navigator.pop(context, p) : null, key: const Key('autoadd-save')),
      children: widget.hopsAndOverwrite
          ? [
              _help(context, 'These apply to nodes your radio adds by itself.'),
              _sw('aa-overwrite', 'Replace the oldest when full', p.overwriteOldest, (v) => setState(() => p = p.copyWith(overwriteOldest: v)),
                  sub: 'When the contact list is full, the oldest contact that is not a favourite makes room.'),
              const SizedBox(height: Gap.m),
              Text('Only add nodes that are', style: Theme.of(context).textTheme.titleMedium),
              for (final e in hops.entries)
                _choice(context, key: Key('aa-hops-${e.key}'), label: e.value, selected: p.maxHops == e.key, onTap: () => setState(() => p = p.copyWith(maxHops: e.key))),
            ]
          : [
              _help(context, 'With "Add new contacts myself" on, your radio adds only the kinds you switch on here and offers you the rest.'),
              _sw('aa-chat', 'People', p.autoAddChat, (v) => setState(() => p = p.copyWith(autoAddChat: v))),
              _sw('aa-repeater', 'Repeaters', p.autoAddRepeaters, (v) => setState(() => p = p.copyWith(autoAddRepeaters: v)),
                  sub: 'Repeaters fill the list fast in a busy area.'),
              _sw('aa-room', 'Rooms', p.autoAddRooms, (v) => setState(() => p = p.copyWith(autoAddRooms: v))),
              _sw('aa-sensor', 'Sensors', p.autoAddSensors, (v) => setState(() => p = p.copyWith(autoAddSensors: v))),
            ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ PIN

Future<String?> showPinSheet(BuildContext context) => showAppSheet<String>(
      context,
      detents: const [0.92],
      builder: (ctx, scroll) => _PinSheet(scroll: scroll),
    );

class _PinSheet extends StatefulWidget {
  final ScrollController scroll;
  const _PinSheet({required this.scroll});
  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  final a = TextEditingController(), b = TextEditingController();
  @override
  void dispose() {
    a.dispose();
    b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = PinCheck.problem(a.text, b.text);
    final weak = a.text.length == 6 ? PinCheck.weakness(a.text) : null;
    Widget field(String key, String label, TextEditingController c) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: TextField(
            key: Key(key),
            controller: c,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: label, counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
        );
    return AppSheetScaffold(
      controller: widget.scroll,
      title: 'Bluetooth PIN',
      primaryAction: _primary('Set PIN', problem == null ? () => Navigator.pop(context, a.text) : null, key: const Key('pin-save')),
      children: [
        _help(context, 'The 6 digits your phone asks for when it pairs with this radio. The new PIN applies the next time you pair.'),
        _help(context, 'Write it down. If you forget it you cannot pair a new phone, and the way back is a factory reset.', warn: true, key: const Key('pin-warning')),
        field('pin-a', 'New PIN', a),
        field('pin-b', 'Type it again', b),
        if (a.text.isNotEmpty && b.text.isNotEmpty && problem != null) _help(context, problem, key: const Key('pin-problem'), warn: true),
        if (weak != null) _help(context, weak, key: const Key('pin-weak')),
        _help(context, 'After you change it, forget this radio in iOS Settings > Bluetooth, then pair again with the new PIN.'),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ backup

class BackupExportResult {
  final Uint8List file;
  final String message;
  const BackupExportResult(this.file, this.message);
}

Future<void> showExportBackupSheet(
  BuildContext context, {
  required DeviceSettingsTool tool,
  required Future<void> Function(Uint8List bytes, String name) shareFile,
  required Future<void> Function(String text) copyText,
  required bool identityKnownDisabled,
}) =>
    showAppSheet<void>(
      context,
      detents: const [0.92],
      builder: (ctx, scroll) => _ExportSheet(scroll: scroll, tool: tool, shareFile: shareFile, copyText: copyText, identityKnownDisabled: identityKnownDisabled),
    );

class _ExportSheet extends StatefulWidget {
  final ScrollController scroll;
  final DeviceSettingsTool tool;
  final Future<void> Function(Uint8List, String) shareFile;
  final Future<void> Function(String) copyText;
  final bool identityKnownDisabled;
  const _ExportSheet({required this.scroll, required this.tool, required this.shareFile, required this.copyText, required this.identityKnownDisabled});
  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  final a = TextEditingController(), b = TextEditingController();
  bool busy = false;
  String? message;
  bool failed = false;
  Uint8List? file;

  @override
  void dispose() {
    a.dispose();
    b.dispose();
    super.dispose();
  }

  String? get problem => RadioBackup.passphraseProblem(a.text) ?? (a.text != b.text ? 'The two passphrases are different.' : null);

  Future<void> _make() async {
    setState(() {
      busy = true;
      message = null;
    });
    final r = await widget.tool.exportBackup(a.text);
    if (!mounted) return;
    setState(() {
      busy = false;
      failed = !r.result.ok;
      message = r.result.message;
      file = r.file;
    });
  }

  String get _name => 'meshsonar-radio-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget field(String key, String label, TextEditingController c) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: TextField(key: Key(key), controller: c, obscureText: true, enabled: file == null, decoration: InputDecoration(labelText: label), onChanged: (_) => setState(() {})),
        );
    final disabled = widget.identityKnownDisabled || !widget.tool.available(DeviceFeature.identityKeyExport);
    return AppSheetScaffold(
      controller: widget.scroll,
      title: 'Export backup',
      primaryAction: file == null
          ? _primary('Create encrypted backup', problem == null ? _make : null, key: const Key('backup-create'), busy: busy)
          : _primary('Share the backup file', () => widget.shareFile(file!, _name), key: const Key('backup-share')),
      secondaryAction: file == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: OutlinedButton(key: const Key('backup-copy'), onPressed: () => widget.copyText(String.fromCharCodes(file!)), child: const Text('Copy as text')),
            ),
      children: [
        _help(context, disabled
            ? 'Saves your contacts and channels. This radio\'s firmware does not allow exporting its identity key, so the key is not in the file.'
            : 'Saves your radio\'s identity key, its contacts and its channels in one file. The identity key is what makes this radio YOU on the mesh.', key: const Key('backup-explain')),
        _help(context, 'The file is encrypted with the passphrase below and nothing is uploaded. Without the passphrase it cannot be opened, and MeshSonar cannot recover it for you.'),
        if (file == null) ...[
          field('backup-pass-a', 'Passphrase', a),
          field('backup-pass-b', 'Passphrase again', b),
          if (a.text.isNotEmpty && problem != null) _help(context, problem!, key: const Key('backup-problem'), warn: true),
        ],
        if (message != null)
          Text(message!, key: const Key('backup-message'), style: t.textTheme.bodyMedium?.copyWith(color: failed ? t.colorScheme.error : t.colorScheme.onSurface)),
      ],
    );
  }
}

class RestoreChoice {
  final RadioBackupData data;
  final bool replaceIdentity;
  final String typed;
  const RestoreChoice(this.data, this.replaceIdentity, this.typed);
}

Future<RestoreChoice?> showImportBackupSheet(
  BuildContext context, {
  required DeviceSettingsTool tool,
  required Future<String?> Function() pasteText,
}) =>
    showAppSheet<RestoreChoice>(
      context,
      detents: const [0.92],
      builder: (ctx, scroll) => _ImportSheet(scroll: scroll, tool: tool, pasteText: pasteText),
    );

class _ImportSheet extends StatefulWidget {
  final ScrollController scroll;
  final DeviceSettingsTool tool;
  final Future<String?> Function() pasteText;
  const _ImportSheet({required this.scroll, required this.tool, required this.pasteText});
  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final text = TextEditingController(), pass = TextEditingController(), typed = TextEditingController();
  bool busy = false;
  String? error;
  RadioBackupData? data;
  bool replace = false;

  @override
  void dispose() {
    text.dispose();
    pass.dispose();
    typed.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final s = await widget.pasteText();
    if (s != null && mounted) setState(() => text.text = s);
  }

  Future<void> _open() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final d = await widget.tool.openBackup(Uint8List.fromList(text.text.trim().codeUnits), pass.text);
      if (!mounted) return;
      setState(() {
        data = d;
        busy = false;
      });
    } on BackupWrongPassphrase {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Wrong passphrase, or the file is damaged.';
        });
      }
    } on BackupFormatException catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'That is not a radio backup: ${e.message}.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'That backup could not be opened.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = data;
    final canRestore = d != null && (!replace || TypedConfirm.matches(typed.text, TypedConfirm.replaceIdentity));
    return AppSheetScaffold(
      controller: widget.scroll,
      title: 'Import backup',
      primaryAction: d == null
          ? _primary('Open backup', text.text.trim().isEmpty || pass.text.isEmpty ? null : _open, key: const Key('import-open'), busy: busy)
          : _primary('Restore to this radio', canRestore ? () => Navigator.pop(context, RestoreChoice(d, replace, typed.text)) : null, key: const Key('import-restore'), destructive: replace),
      children: [
        if (d == null) ...[
          _help(context, 'Open a backup made with Export backup. Paste its text, then type the passphrase. Nothing is written to the radio until you press Restore.'),
          OutlinedButton(key: const Key('import-paste'), onPressed: _paste, child: const Text('Paste from clipboard')),
          const SizedBox(height: Gap.m),
          TextField(key: const Key('import-text'), controller: text, maxLines: 4, minLines: 2, decoration: const InputDecoration(labelText: 'Backup text'), onChanged: (_) => setState(() {})),
          const SizedBox(height: Gap.m),
          TextField(key: const Key('import-pass'), controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Passphrase'), onChanged: (_) => setState(() {})),
          if (error != null) Padding(padding: const EdgeInsets.only(top: Gap.m), child: Text(error!, key: const Key('import-error'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error))),
        ] else ...[
          Text(d.radioName.isEmpty ? 'A radio' : d.radioName, key: const Key('import-summary-name'), style: t.textTheme.titleMedium),
          _help(context, '${d.contacts.length} contacts, ${d.channels.length} channels${d.hasIdentity ? ', and the identity key' : ', no identity key'}.${d.skipped > 0 ? ' ${d.skipped} damaged entries were skipped.' : ''}', key: const Key('import-summary')),
          _help(context, 'Contacts and channels are added to what the radio already has. A channel in the same slot is overwritten.'),
          if (d.hasIdentity)
            AppSwitchTile(
              key: const Key('import-replace'),
              title: 'Also replace this radio\'s identity',
              subtitle: 'Makes this radio the radio of the backup.',
              value: replace,
              onChanged: (v) => setState(() => replace = v),
              switchKey: const Key('import-replace-switch'),
            ),
          if (replace) ...[
            const SizedBox(height: Gap.m),
            _help(context, 'This radio will stop being the radio it is now. Its public key changes to the backup\'s, anyone who knows the old key can no longer reach it, and the old identity is gone unless you exported it first. Reboot after restoring.', warn: true, key: const Key('import-replace-warning')),
            TextField(key: const Key('import-typed'), controller: typed, decoration: InputDecoration(labelText: 'Type ${TypedConfirm.replaceIdentity} to confirm'), onChanged: (_) => setState(() {})),
          ],
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ factory reset

Future<bool> showFactoryResetSheet(BuildContext context, {required String radioName, required int? contacts}) async {
  final r = await showAppSheet<bool>(
    context,
    detents: const [0.92],
    builder: (ctx, scroll) => _ResetSheet(scroll: scroll, radioName: radioName, contacts: contacts),
  );
  return r == true;
}

class _ResetSheet extends StatefulWidget {
  final ScrollController scroll;
  final String radioName;
  final int? contacts;
  const _ResetSheet({required this.scroll, required this.radioName, required this.contacts});
  @override
  State<_ResetSheet> createState() => _ResetSheetState();
}

class _ResetSheetState extends State<_ResetSheet> {
  final typed = TextEditingController();
  @override
  void dispose() {
    typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final lost = <String>[
      'Its identity key. The radio gets a NEW public key, so it becomes a different node on the mesh.',
      'Its name, "${widget.radioName}", and every radio setting.',
      widget.contacts == null ? 'Every contact stored on it.' : 'All ${widget.contacts} contacts stored on it.',
      'Every channel, including the Public channel setup.',
      'The Bluetooth bond: forget the radio in iOS Settings > Bluetooth and pair again.',
    ];
    return AppSheetScaffold(
      controller: widget.scroll,
      title: 'Factory reset',
      primaryAction: _primary('Erase this radio', TypedConfirm.matches(typed.text, TypedConfirm.factoryReset) ? () => Navigator.pop(context, true) : null,
          key: const Key('reset-confirm'), destructive: true),
      children: [
        Text('This erases the radio and cannot be undone.', key: const Key('reset-headline'), style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.error)),
        const SizedBox(height: Gap.s),
        Text('What is lost', style: t.textTheme.titleSmall),
        for (final l in lost)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: Text(l, style: t.textTheme.bodyMedium))]),
          ),
        const SizedBox(height: Gap.m),
        _help(context, 'Your messages and drives on this phone stay. If you want to keep this radio\'s identity, close this sheet and use Export backup first.', key: const Key('reset-backup-hint')),
        TextField(key: const Key('reset-typed'), controller: typed, autocorrect: false, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: 'Type ${TypedConfirm.factoryReset} to confirm'), onChanged: (_) => setState(() {})),
      ],
    );
  }
}
