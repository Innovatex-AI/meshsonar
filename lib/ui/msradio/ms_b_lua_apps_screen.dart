// MeshSonar radio > Lua apps (brief C.7): the apps on the radio (icon text, name, version, where it came from) with Run / Stop
// / Remove (Remove asks first; built-in apps cannot be removed); "Browse catalog" (loads it on the radio, polls `/apps` every
// 2 s until it is ok or failed, then Install / Update / Installed per entry); "Upload an app" (`main.lua` from Files with its
// id, name, version, icon, description, memory and internet access; 32 KB at most).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/msradio/msradio.dart';
import '../../platform/file_pick.dart';
import 'ms_b_common.dart';

/// The largest `main.lua` the radio takes.
const int kMsLuaMaxBytes = 32 * 1024;

String msBAppSource(String? s) => switch (s) {
      'builtin' => 'Built in',
      'catalog' => 'From the catalog',
      'upload' => 'Uploaded',
      null => 'Unknown source',
      _ => s,
    };

class MsBLuaAppsScreen extends StatefulWidget {
  final MsRadioController c;
  final FilePick pick;
  const MsBLuaAppsScreen({super.key, required this.c, this.pick = const DeviceFilePick()});
  @override
  State<MsBLuaAppsScreen> createState() => _MsBLuaAppsScreenState();
}

class _MsBLuaAppsScreenState extends State<MsBLuaAppsScreen> {
  MsApps? _apps;
  String? _error, _note;
  bool _loading = true, _acting = false, _browsing = false;
  String? _installing;
  late final MsBPoller _poll = MsBPoller(tick: _load, want: () => mounted && (_waitingCatalog || _waitingInstall));

  MsRadioApi? get _api => widget.c.api;

  bool get _waitingCatalog => _browsing && (_apps?.catalog?.state != MsCatalogState.ok && _apps?.catalog?.state != MsCatalogState.error);
  bool get _waitingInstall => _installing != null || (_apps?.installing ?? false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) return;
    MsApps? a;
    final err = await msBTry(() async => a = await api.apps());
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (a != null) {
        _apps = a;
        // an install the app started is done once the radio no longer says it is installing
        if (_installing != null && !a!.installing) _installing = null;
        final cs = a!.catalog?.state;
        if (_browsing && cs == MsCatalogState.error) _error = a!.catalog?.note ?? 'The catalog could not be loaded.';
      }
      if (err != null) _error = err;
    });
    _poll.kick();
  }

  Future<void> _act(Future<Object?> Function(MsRadioApi api) job, {String? note}) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _acting = true;
      _error = null;
      _note = null;
    });
    final err = await msBTry(() => job(api));
    if (!mounted) return;
    setState(() {
      _acting = false;
      _error = err;
      if (err == null) _note = note;
    });
    await _load();
  }

  Future<void> _remove(MsLuaApp a) async {
    final ok = await msBConfirm(context,
        key: 'remove-app',
        title: 'Remove ${a.name}?',
        body: 'The app and what it saved on the radio are deleted. You can install it again later.',
        confirmLabel: 'Remove',
        destructive: true);
    if (!ok || !mounted) return;
    await _act((api) => api.removeApp(a.id), note: '${a.name} was removed.');
  }

  Future<void> _browse() async {
    setState(() => _browsing = true);
    await _act((api) => api.loadCatalog());
  }

  Future<void> _install(MsCatalogEntry e) async {
    setState(() => _installing = e.id);
    await _act((api) => api.installApp(e.id));
    if (_error != null && mounted) setState(() => _installing = null);
  }

  Future<void> _upload() async {
    final api = _api;
    if (api == null) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => MsBLuaUploadScreen(c: widget.c, pick: widget.pick)));
    if (done == true && mounted) {
      setState(() => _note = 'The app was uploaded.');
      await _load();
    }
  }

  Widget _icon(BuildContext context, String? icon, String name) {
    final cs = Theme.of(context).colorScheme;
    final text = (icon != null && icon.trim().isNotEmpty ? icon.trim() : (name.isEmpty ? '?' : name.substring(0, 1))).toUpperCase();
    return ExcludeSemantics(
      child: Container(
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        padding: const EdgeInsets.all(4),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSecondaryContainer, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _appRow(BuildContext context, MsLuaApp a, MsApps apps) {
    final t = Theme.of(context);
    final running = apps.running == a.id;
    final failed = apps.failed == a.id;
    final line = [if (a.version != null) 'Version ${a.version}', msBAppSource(a.source), if (a.http) 'Uses the internet', if (running) 'Running on the radio'].join(' · ');
    return Padding(
      key: Key('msb-app-${a.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _icon(context, a.icon, a.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name, style: t.textTheme.bodyLarge),
              Text(line, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              if (a.desc != null) Text(a.desc!, style: t.textTheme.bodySmall),
              if (failed && apps.error != null) Text('It stopped: ${apps.error}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (running)
            OutlinedButton(
              key: Key('msb-app-stop-${a.id}'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
              onPressed: _acting ? null : () => _act((api) => api.stopApp(), note: '${a.name} was closed on the radio.'),
              child: const Text('Stop'),
            )
          else
            FilledButton.tonal(
              key: Key('msb-app-run-${a.id}'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
              onPressed: _acting ? null : () => _act((api) => api.runApp(a.id), note: '${a.name} is open on the radio.'),
              child: const Text('Run'),
            ),
          if (!a.isBuiltin)
            TextButton(
              key: Key('msb-app-remove-${a.id}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 44), foregroundColor: t.colorScheme.error),
              onPressed: _acting ? null : () => _remove(a),
              child: const Text('Remove'),
            ),
        ]),
      ]),
    );
  }

  Widget _entryRow(BuildContext context, MsCatalogEntry e, MsApps apps) {
    final t = Theme.of(context);
    final installingThis = (_installing == e.id) || (apps.installing && apps.installingId == e.id);
    final line = [if (e.version != null) 'Version ${e.version}', if (e.installed) 'On the radio: ${e.installedVersion}', if (e.http) 'Uses the internet'].join(' · ');
    final Widget action;
    if (installingThis) {
      action = const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)));
    } else if (e.updateAvailable) {
      action = FilledButton.tonal(
          key: Key('msb-cat-update-${e.id}'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
          onPressed: _acting || _waitingInstall ? null : () => _install(e),
          child: const Text('Update'));
    } else if (e.installed) {
      action = OutlinedButton(key: Key('msb-cat-installed-${e.id}'), style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)), onPressed: null, child: const Text('Installed'));
    } else {
      action = FilledButton(
          key: Key('msb-cat-install-${e.id}'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
          onPressed: _acting || _waitingInstall ? null : () => _install(e),
          child: const Text('Install'));
    }
    return Padding(
      key: Key('msb-cat-${e.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _icon(context, e.icon, e.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.name, style: t.textTheme.bodyLarge),
              if (line.isNotEmpty) Text(line, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              if (e.desc != null) Text(e.desc!, style: t.textTheme.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        action,
      ]),
    );
  }

  List<Widget> _rows(BuildContext context) {
    final a = _apps;
    if (_loading && a == null) return [const MsBBlock(child: Center(child: CircularProgressIndicator()))];
    final cat = a?.catalog;
    return [
      MsBError(_error),
      if (_note != null) MsBBlock(child: NoteCard(_note!, key: const Key('msb-apps-note'))),
      if (a != null) ...[
        if (a.installed.isEmpty)
          const MsBBlock(child: NoteCard('There are no apps on the radio yet.', key: Key('msb-apps-empty')))
        else
          InsetGroup(header: 'On the radio', groupKey: const Key('msb-apps-installed'), rows: [for (final x in a.installed) _appRow(context, x, a)]),
        if (a.installNote != null) MsBBlock(child: NoteCard(a.installNote!, key: const Key('msb-apps-install-note'))),
        if (_waitingInstall) const MsBProgress('Installing the app on the radio', key: Key('msb-apps-installing')),
        MsBButtons([
          FilledButton.tonalIcon(
            key: const Key('msb-apps-browse'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _acting || _waitingCatalog ? null : _browse,
            icon: const Icon(Icons.storefront_outlined),
            label: Text(cat?.state == MsCatalogState.ok ? 'Load the catalog again' : 'Browse catalog'),
          ),
          OutlinedButton.icon(
            key: const Key('msb-apps-upload'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _acting ? null : _upload,
            icon: const Icon(Icons.upload_file),
            label: const Text('Upload an app'),
          ),
        ]),
        if (_waitingCatalog) const MsBProgress('The radio is loading the catalog', key: Key('msb-cat-loading')),
        if (cat != null && cat.state == MsCatalogState.ok)
          cat.entries.isEmpty
              ? const MsBBlock(child: NoteCard('The catalog has no apps for this radio.', key: Key('msb-cat-empty')))
              : InsetGroup(header: 'Catalog', groupKey: const Key('msb-cat'), rows: [for (final e in cat.entries) _entryRow(context, e, a)]),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) => MsBPage(c: widget.c, id: 'apps', title: 'Lua apps', onRefresh: _load, builder: _rows);
}

// ---------------------------------------------------------------- upload

/// "Upload an app": pick `main.lua`, fill in the fields, send it. Pops true when the radio took it.
class MsBLuaUploadScreen extends StatefulWidget {
  final MsRadioController c;
  final FilePick pick;
  const MsBLuaUploadScreen({super.key, required this.c, this.pick = const DeviceFilePick()});
  @override
  State<MsBLuaUploadScreen> createState() => _MsBLuaUploadScreenState();
}

class _MsBLuaUploadScreenState extends State<MsBLuaUploadScreen> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController(), _name = TextEditingController(), _version = TextEditingController(text: '1.0.0');
  final _icon = TextEditingController(), _desc = TextEditingController();
  int _memoryKb = 64;
  bool _internet = false, _sending = false;
  PickedFile? _file;
  String? _error;
  int _sent = 0;

  static const List<int> memoryChoices = [16, 32, 48, 64, 80, 96];

  @override
  void dispose() {
    for (final c in [_id, _name, _version, _icon, _desc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    PickedFile? f;
    final err = await msBTry(() async => f = await widget.pick.pickFile(extensions: const ['lua']));
    if (!mounted) return;
    setState(() {
      _error = err;
      if (f != null) {
        if (f!.size > kMsLuaMaxBytes) {
          _file = null;
          _error = 'main.lua can be at most 32 KB. This file is ${msBBytes(f!.size)}.';
        } else {
          _file = f;
        }
      }
    });
  }

  Future<void> _send() async {
    final api = widget.c.api;
    final f = _file;
    if (api == null) return;
    if (f == null) {
      setState(() => _error = 'Pick main.lua first.');
      return;
    }
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _sending = true;
      _error = null;
      _sent = 0;
    });
    final err = await msBTry(() => api.uploadApp(
          f.upload,
          id: _id.text.trim(),
          name: _name.text.trim(),
          version: _version.text.trim().isEmpty ? '1.0.0' : _version.text.trim(),
          icon: _icon.text.trim(),
          desc: _desc.text.trim(),
          internet: _internet,
          memoryKb: _memoryKb,
          onProgress: (done, _) {
            if (mounted) setState(() => _sent = done);
          },
        ));
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = err;
    });
    if (err == null) Navigator.of(context).pop(true);
  }

  static String? _checkId(String? v) {
    final s = (v ?? '').trim();
    if (!RegExp(r'^[a-z0-9_]{1,10}$').hasMatch(s)) return '1 to 10 characters: a-z, 0-9 or _.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _file;
    InputDecoration deco(String label, {String? hint, String? helper}) =>
        InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3, border: const OutlineInputBorder());
    return Scaffold(
      key: const Key('msb-apps-upload-screen'),
      appBar: AppBar(title: const Text('Upload an app')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_error != null) ...[NoteCard(_error!, key: const Key('msb-upload-error'), kind: NoteKind.problem), const SizedBox(height: 12)],
                    Text(f == null ? 'No file picked yet.' : '${f.name}, ${msBBytes(f.size)}', key: const Key('msb-upload-file'), style: t.textTheme.bodyLarge),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('msb-upload-pick'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _sending ? null : _pick,
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Pick main.lua'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('msb-upload-id'),
                      controller: _id,
                      decoration: deco('Id', helper: 'The app\'s folder on the radio: 1 to 10 characters, a-z, 0-9 or _.'),
                      autocorrect: false,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_]')), LengthLimitingTextInputFormatter(10)],
                      validator: _checkId,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('msb-upload-name'),
                      controller: _name,
                      decoration: deco('Name'),
                      inputFormatters: [LengthLimitingTextInputFormatter(31)],
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Give the app a name.' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(key: const Key('msb-upload-version'), controller: _version, decoration: deco('Version', hint: '1.0.0'), inputFormatters: [LengthLimitingTextInputFormatter(20)]),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('msb-upload-icon'),
                      controller: _icon,
                      decoration: deco('Icon', helper: '1 to 3 characters shown on the app\'s tile.'),
                      inputFormatters: [LengthLimitingTextInputFormatter(3)],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('msb-upload-desc'),
                      controller: _desc,
                      decoration: deco('Description', helper: 'One line shown in the radio\'s app list.'),
                      inputFormatters: [LengthLimitingTextInputFormatter(120)],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      key: const Key('msb-upload-memory'),
                      initialValue: _memoryKb,
                      isExpanded: true,
                      decoration: deco('Memory'),
                      items: [for (final m in memoryChoices) DropdownMenuItem(value: m, child: Text('$m KB'))],
                      onChanged: _sending ? null : (v) => setState(() => _memoryKb = v ?? 64),
                    ),
                    SwitchListTile.adaptive(
                      key: const Key('msb-upload-internet'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Internet access'),
                      subtitle: const Text('Lets the app fetch web pages through the radio\'s Wi-Fi.'),
                      value: _internet,
                      onChanged: _sending ? null : (v) => setState(() => _internet = v),
                    ),
                    if (_sending) ...[
                      const SizedBox(height: 8),
                      Text('Sending: ${msBBytes(_sent)} of ${msBBytes(f?.size)}'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: f == null || f.size == 0 ? null : (_sent / f.size).clamp(0.0, 1.0)),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const Key('msb-upload-send'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _sending ? null : _send,
                      icon: const Icon(Icons.upload),
                      label: const Text('Upload to the radio'),
                    ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
