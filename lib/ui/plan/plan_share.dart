// Share, export and import for the Planner (release 0.38 A11; build plan 4.3 improvements 10 and 18, 4.5 J8).
//
//   showPlanShare   the plan's link (`https://meshsonar.com/share/plan#<code>`, plan_codec.dart) through the system share
//                   sheet or the clipboard, and the exports (KML, GeoJSON, MeshCore setup commands; plan_export.dart) as
//                   files handed to the share sheet, where "Save to Files" keeps them. The position warning: by default
//                   every node that is the person's own or installed is rounded to about 1 km in the link AND the files;
//                   one switch ("Exact positions") turns that off for this share only.
//   showPlanImport  the paste fallback for links (works whether or not universal links are on): paste a plan link
//                   (https or `meshsonar://plan#<code>`), a bare code, a Plan JSON file's text, or a MeshCore contacts /
//                   public repeater list. A plan goes back to the planner as a link (the same path a tapped link takes:
//                   PlannerScreenState.handle -> SavedPlans.import); contacts are previewed, nearest first, and the
//                   picked ones join the open plan as network nodes.
//   readPlanPaste   the pure reader behind it (tested on its own).
// Design kit only: showAppSheet + AppSheetScaffold, state_views, AppSymbols, Hit, showAppToast.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import '../../app/plan_inbox.dart' show isPlanLink;
import '../../core/plan/plan_codec.dart';
import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_export.dart';
import '../../core/plan/plan_model.dart';
import '../../core/plan_contract.dart' show PlanPoint;
import '../app.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/sheet_detents.dart' show formSheetDetents;
import '../design/state_views.dart';
import '../design/tokens.dart';

// ------------------------------------------------------------------------------------------------ seams

/// Test seams: what the share sheet, the file share and the clipboard do (null = the real platform).
class PlanShareSeams {
  static Future<void> Function(String text, String subject)? shareText;
  static Future<void> Function(PlanExportFile file)? shareFile;
  static Future<void> Function(String text)? copy;
  static Future<String?> Function()? paste;

  static void reset() {
    shareText = null;
    shareFile = null;
    copy = null;
    paste = null;
  }
}

Future<void> _shareText(String text, String subject) =>
    PlanShareSeams.shareText?.call(text, subject) ?? SharePlus.instance.share(ShareParams(text: text, subject: subject)).then((_) {});

Future<void> _copy(String text) => PlanShareSeams.copy?.call(text) ?? Clipboard.setData(ClipboardData(text: text));

Future<String?> _paste() async {
  final p = PlanShareSeams.paste;
  if (p != null) return p();
  return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}

Future<void> _shareFile(BuildContext context, PlanExportFile f) async {
  final seam = PlanShareSeams.shareFile;
  if (seam != null) return seam(f);
  final dir = await AppScope.read(context).services.exportDir();
  final file = File('${dir.path}${Platform.pathSeparator}${f.fileName}');
  await file.writeAsString(f.content, flush: true);
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: f.format.mimeType, name: f.fileName)],
    fileNameOverrides: [f.fileName],
    subject: f.fileName,
  ));
}

// ------------------------------------------------------------------------------------------------ share sheet

Future<void> showPlanShare(BuildContext context, Plan plan) => showAppSheet<void>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => PlanShareSheet(plan: plan, scroll: scroll),
    );

class PlanShareSheet extends StatefulWidget {
  final Plan plan;
  final ScrollController scroll;
  const PlanShareSheet({super.key, required this.plan, required this.scroll});
  @override
  State<PlanShareSheet> createState() => _PlanShareSheetState();
}

class _PlanShareSheetState extends State<PlanShareSheet> {
  bool _exact = false;
  PlanExportFormat? _busy;
  bool _sharingLink = false;
  late PlanShareEncoding? _enc;
  Object? _encError;

  @override
  void initState() {
    super.initState();
    _encode();
  }

  void _encode() {
    try {
      _enc = encodePlanShare(widget.plan, exactPositions: _exact);
      _encError = null;
    } catch (e) {
      _enc = null;
      _encError = e;
    }
  }

  int get _sensitive => widget.plan.nodes.where((n) => n.sensitivePosition).length;
  Uri? get _link => _enc == null ? null : planShareUri(_enc!.code);

  Future<void> _shareLink() async {
    final link = _link;
    if (link == null) return;
    setState(() => _sharingLink = true);
    try {
      await _shareText('$link', 'MeshSonar plan: ${widget.plan.name}');
    } catch (_) {
      if (mounted) showAppToast(context, 'The share sheet did not open. Copy the link instead.', kind: AppToastKind.error);
    } finally {
      if (mounted) setState(() => _sharingLink = false);
    }
  }

  Future<void> _copyLink() async {
    final link = _link;
    if (link == null) return;
    await _copy('$link');
    if (mounted) showAppToast(context, 'Link copied. Anyone who opens it gets a copy of this plan.', kind: AppToastKind.success);
  }

  Future<void> _export(PlanExportFormat f) async {
    setState(() => _busy = f);
    try {
      final file = exportPlan(widget.plan, f, exactPositions: _exact);
      await _shareFile(context, file);
    } catch (_) {
      if (mounted) showAppToast(context, 'The ${f.label} file could not be made. Try again.', kind: AppToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _copyCommands() async {
    await _copy(meshcoreSetupText(widget.plan, exactPositions: _exact));
    if (mounted) showAppToast(context, 'Setup commands copied. Send only the lines without #.', kind: AppToastKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final plan = widget.plan;
    if (plan.nodes.isEmpty) {
      return AppSheetScaffold(
        key: const Key('plan-share'),
        controller: widget.scroll,
        title: 'Share the plan',
        children: const [
          SizedBox(height: Gap.l),
          AppEmptyView(
            key: Key('plan-share-empty'),
            symbol: AppSymbols.squareAndArrowUp,
            title: 'Nothing to share yet',
            message: 'Add a node first: long-press the map, or add a repeater from the list.',
          ),
        ],
      );
    }
    final link = _link;
    final cliCount = plan.nodes.where(cliCovers).length;
    final busy = _busy != null || _sharingLink;
    return AppSheetScaffold(
      key: const Key('plan-share'),
      controller: widget.scroll,
      title: 'Share the plan',
      primaryAction: FilledButton.icon(
        key: const Key('plan-share-link'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
        onPressed: link == null || busy ? null : _shareLink,
        icon: const AppSymbolIcon(AppSymbols.squareAndArrowUp, size: 20),
        label: const Text('Share link'),
      ),
      secondaryAction: TextButton.icon(
        key: const Key('plan-share-copy'),
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min)),
        onPressed: link == null ? null : _copyLink,
        icon: const AppSymbolIcon(AppSymbols.docOnDoc, size: 20),
        label: const Text('Copy link'),
      ),
      children: [
        Text(
          '${plan.name}: ${plan.nodes.length} ${plan.nodes.length == 1 ? 'node' : 'nodes'}. The person who opens the link gets their own copy; '
          'nothing is stored on a server (the plan rides after the # in the link).',
          style: t.textTheme.bodyMedium,
        ),
        const SizedBox(height: Gap.m),
        if (_encError != null)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 160),
            child: AppErrorView(
              key: const Key('plan-share-error'),
              title: 'The link could not be made',
              message: 'Try again. The plan is still saved on this phone.',
              onRetry: () => setState(_encode),
            ),
          ),
        if (_sensitive > 0) ...[
          _Warning(
            key: const Key('plan-share-warning'),
            text: _exact
                ? 'Exact positions are on: anyone with this link or these files sees exactly where your own and installed radios are.'
                : encodePlanShare(plan).warning!,
            strong: _exact,
          ),
          SwitchListTile(
            key: const Key('plan-share-exact'),
            contentPadding: EdgeInsets.zero,
            secondary: const AppSymbolIcon(AppSymbols.location),
            title: const Text('Exact positions'),
            subtitle: Text('For $_sensitive of your own or installed ${_sensitive == 1 ? 'radio' : 'radios'}, in the link and the files'),
            value: _exact,
            onChanged: (v) => setState(() {
              _exact = v;
              _encode();
            }),
          ),
        ],
        if (link != null)
          Semantics(
            label: 'Plan link',
            value: link.toString().length > 60 ? '${link.toString().substring(0, 60)}…' : link.toString(),
            excludeSemantics: true,
            child: Container(
              key: const Key('plan-share-preview'),
              padding: const EdgeInsets.all(Gap.m),
              decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.card / 2)),
              child: Text(link.toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
            ),
          ),
        const SizedBox(height: Gap.l),
        Semantics(header: true, child: Text('Export', style: t.textTheme.titleSmall)),
        Text('Files open in the share sheet; choose Save to Files to keep one.', style: t.textTheme.bodySmall),
        _ExportRow(
          key: const Key('plan-export-kml'),
          symbol: AppSymbols.globe,
          title: 'KML',
          subtitle: 'Google Earth and most map apps',
          busy: _busy == PlanExportFormat.kml,
          onTap: busy ? null : () => _export(PlanExportFormat.kml),
        ),
        _ExportRow(
          key: const Key('plan-export-geojson'),
          symbol: AppSymbols.map,
          title: 'GeoJSON',
          subtitle: 'GIS tools and websites',
          busy: _busy == PlanExportFormat.geojson,
          onTap: busy ? null : () => _export(PlanExportFormat.geojson),
        ),
        _ExportRow(
          key: const Key('plan-export-cli'),
          symbol: AppSymbols.antenna,
          title: 'MeshCore setup commands',
          subtitle: cliCount == 0
              ? 'Only for your own repeaters and planned sites: this plan has none'
              : 'For $cliCount ${cliCount == 1 ? 'repeater' : 'repeaters'}: name, position, radio, TX delay',
          busy: _busy == PlanExportFormat.cli,
          onTap: busy || cliCount == 0 ? null : () => _export(PlanExportFormat.cli),
        ),
        if (cliCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('plan-export-cli-copy'),
              style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
              onPressed: _copyCommands,
              icon: const AppSymbolIcon(AppSymbols.docOnDoc, size: 18),
              label: const Text('Copy setup commands'),
            ),
          ),
        const SizedBox(height: Gap.l),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  final String text;
  final bool strong;
  const _Warning({super.key, required this.text, this.strong = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppColors.of(context);
    final tint = strong ? t.colorScheme.error : c.warning;
    return Semantics(
      container: true,
      label: 'Privacy',
      child: Container(
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(border: Border.all(color: tint), borderRadius: BorderRadius.circular(Corners.card / 2)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSymbolIcon(strong ? AppSymbols.exclamationTriangle : AppSymbols.lock, color: tint),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

class _ExportRow extends StatelessWidget {
  final AppSymbol symbol;
  final String title, subtitle;
  final bool busy;
  final VoidCallback? onTap;
  const _ExportRow({super.key, required this.symbol, required this.title, required this.subtitle, required this.busy, required this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: Hit.min + 8,
        enabled: onTap != null || busy,
        leading: AppSymbolIcon(symbol),
        title: Text(title),
        subtitle: Text(busy ? 'Preparing the file…' : subtitle),
        trailing: busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2)) : const AppSymbolIcon(AppSymbols.squareAndArrowUp, size: 20),
        onTap: busy ? null : onTap,
      );
}

// ------------------------------------------------------------------------------------------------ paste reader

sealed class PlanPaste {
  const PlanPaste();
}

/// A plan: open it through the link path.
class PlanPasteLink extends PlanPaste {
  final Uri uri;
  const PlanPasteLink(this.uri);
}

/// A contacts / repeater list.
class PlanPasteNodes extends PlanPaste {
  final NodeImport nodes;
  const PlanPasteNodes(this.nodes);
}

/// Not usable; [message] says why and what to do.
class PlanPasteError extends PlanPaste {
  final String message;
  const PlanPasteError(this.message);
}

const String _damaged = 'This plan link is damaged or was cut short. Ask the sender to share it again.';
final RegExp _linkToken = RegExp(r'''(meshsonar://[^\s<>"']+|https?://[^\s<>"']+)''', caseSensitive: false);
final RegExp _bareCode = RegExp(r'^[A-Za-z0-9_-]{8,}={0,2}$');

/// What the person pasted: a plan link anywhere in the text (a message that contains one counts), a bare plan code, a Plan
/// JSON document, or a contacts / public repeater list.
PlanPaste readPlanPaste(String text) {
  final t = text.trim();
  if (t.isEmpty) return const PlanPasteError('Paste a plan link, a plan code or a contacts list first.');
  if (t.startsWith('{') || t.startsWith('[')) {
    Object? j;
    try {
      j = jsonDecode(t);
    } on FormatException {
      return const PlanPasteError('This looks like JSON but it is cut short or damaged. Copy it again.');
    }
    if (j is Map && j['v'] == Plan.version && j['nodes'] is List) {
      try {
        final plan = Plan.fromJson(j);
        return PlanPasteLink(planShareUri(encodePlanShare(plan, exactPositions: true).code));
      } on FormatException {
        return const PlanPasteError('This plan file could not be read.');
      }
    }
    try {
      return PlanPasteNodes(parseNodeImport(t));
    } on FormatException catch (e) {
      return PlanPasteError(e.message);
    }
  }
  var sawLink = false;
  for (final m in _linkToken.allMatches(t)) {
    final raw = m.group(0)!.replaceFirst(RegExp(r'[).,;:!?\]]+$'), '');
    final u = Uri.tryParse(raw);
    if (u == null) continue;
    sawLink = true;
    final uri = u.scheme.toLowerCase() == 'http' ? u.replace(scheme: 'https') : u;
    if (!isPlanLink(uri)) continue;
    if (planCodeFrom(uri) == null) return const PlanPasteError('This link has no plan in it. Ask the sender to share the plan again.');
    try {
      decodePlanUri(uri);
    } on FormatException {
      return const PlanPasteError(_damaged);
    }
    return PlanPasteLink(uri);
  }
  if (sawLink) return const PlanPasteError('That link is not a MeshSonar plan link.');
  final code = t.startsWith('#') ? t.substring(1) : t;
  if (_bareCode.hasMatch(code)) {
    try {
      decodePlanShare(code);
      return PlanPasteLink(planShareUri(code.replaceAll('=', '')));
    } on FormatException {
      return const PlanPasteError(_damaged);
    }
  }
  return const PlanPasteError('This is not a plan link, a plan code or a contacts list.');
}

// ------------------------------------------------------------------------------------------------ import sheet

/// What the import sheet did.
sealed class PlanImportOutcome {
  const PlanImportOutcome();
}

/// Open this plan link (the planner keeps it as a new saved plan).
class PlanImportOpen extends PlanImportOutcome {
  final Uri link;
  const PlanImportOpen(this.link);
}

/// [count] nodes joined the open plan (each one undo step).
class PlanImportAdded extends PlanImportOutcome {
  final int count;
  const PlanImportAdded(this.count);
}

/// [near]: the map centre (contacts nearest it come first); [claimed]: the person's claimed public keys (those nodes are
/// marked as theirs).
Future<PlanImportOutcome?> showPlanImport(BuildContext context, {required PlanController controller, PlanPoint? near, Set<String> claimed = const {}}) =>
    showAppSheet<PlanImportOutcome>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => PlanImportSheet(controller: controller, near: near, claimed: claimed, scroll: scroll),
    );

class PlanImportSheet extends StatefulWidget {
  final PlanController controller;
  final PlanPoint? near;
  final Set<String> claimed;
  final ScrollController scroll;
  const PlanImportSheet({super.key, required this.controller, this.near, this.claimed = const {}, required this.scroll});
  @override
  State<PlanImportSheet> createState() => _PlanImportSheetState();
}

class _PlanImportSheetState extends State<PlanImportSheet> {
  final TextEditingController _field = TextEditingController();
  String? _error;
  NodeImport? _nodes;
  List<ImportedNode> _rows = const [];
  final Set<int> _picked = {};

  int get _room => Plan.maxNodes - widget.controller.nodes.length;
  Set<String> get _inPlan => {for (final n in widget.controller.nodes) ?n.existingKey};

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _pasteIn() async {
    String? s;
    try {
      s = await _paste();
    } catch (_) {
      s = null;
    }
    if (!mounted) return;
    if (s == null || s.trim().isEmpty) {
      setState(() => _error = 'The clipboard is empty. Copy a plan link or a contacts list first.');
      return;
    }
    _field.text = s;
    _go();
  }

  void _go() {
    final r = readPlanPaste(_field.text);
    switch (r) {
      case PlanPasteLink(:final uri):
        Navigator.of(context).pop(PlanImportOpen(uri));
      case PlanPasteError(:final message):
        setState(() => _error = message);
      case PlanPasteNodes(:final nodes):
        final rows = nodes.nearest(widget.near);
        final have = _inPlan;
        _picked.clear();
        for (var i = 0; i < rows.length && _picked.length < _room; i++) {
          if (rows[i].key == null || !have.contains(rows[i].key)) _picked.add(i);
        }
        setState(() {
          _error = null;
          _nodes = nodes;
          _rows = rows;
        });
    }
  }

  void _add() {
    final c = widget.controller;
    var added = 0;
    for (final i in _picked.toList()..sort()) {
      final n = _rows[i];
      try {
        final before = c.nodes.length;
        c.addNode(
          name: n.name,
          lat: n.lat,
          lon: n.lon,
          status: PlanNodeStatus.existing,
          existingKey: n.key,
          role: n.role,
          mine: n.key != null && widget.claimed.contains(n.key),
        );
        if (c.nodes.length > before) added++;
      } on PlanFullException {
        break;
      }
    }
    Navigator.of(context).pop(PlanImportAdded(added));
  }

  @override
  Widget build(BuildContext context) => _nodes == null ? _input(context) : _preview(context);

  Widget _input(BuildContext context) {
    final t = Theme.of(context);
    return AppSheetScaffold(
      key: const Key('plan-import'),
      controller: widget.scroll,
      title: 'Import',
      primaryAction: FilledButton(
        key: const Key('plan-import-go'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
        onPressed: _go,
        child: const Text('Continue'),
      ),
      secondaryAction: TextButton.icon(
        key: const Key('plan-import-paste'),
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min)),
        onPressed: _pasteIn,
        icon: const AppSymbolIcon(AppSymbols.docOnDoc, size: 20),
        label: const Text('Paste from the clipboard'),
      ),
      children: [
        Text(
          'Paste a plan link someone sent you (or just its code), or a MeshCore contacts export or public repeater list to add those '
          'radios to this plan.',
          style: t.textTheme.bodyMedium,
        ),
        const SizedBox(height: Gap.m),
        TextField(
          key: const Key('plan-import-field'),
          controller: _field,
          minLines: 3,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: 'Link, code or contacts JSON',
            border: const OutlineInputBorder(),
            errorText: _error,
            errorMaxLines: 4,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: Gap.l),
      ],
    );
  }

  Widget _preview(BuildContext context) {
    final t = Theme.of(context);
    final nodes = _nodes!;
    final have = _inPlan;
    final room = _room;
    final full = _picked.length >= room;
    return AppSheetScaffold(
      key: const Key('plan-import-preview'),
      controller: widget.scroll,
      title: 'Add to the plan',
      primaryAction: FilledButton(
        key: const Key('plan-import-add'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
        onPressed: _picked.isEmpty ? null : _add,
        child: Text(_picked.isEmpty ? 'Pick at least one' : 'Add ${_picked.length} to the plan'),
      ),
      secondaryAction: TextButton(
        key: const Key('plan-import-back'),
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min)),
        onPressed: () => setState(() {
          _nodes = null;
          _picked.clear();
        }),
        child: const Text('Paste something else'),
      ),
      children: [
        Text(nodes.summary, key: const Key('plan-import-summary'), style: t.textTheme.bodyMedium),
        Text(
          room <= 0 ? 'This plan is full (${Plan.maxNodes} nodes). Remove a node first.' : 'Room for $room more ${room == 1 ? 'node' : 'nodes'}${widget.near == null ? '' : '; nearest to the map first'}.',
          style: t.textTheme.bodySmall,
        ),
        if (_rows.isEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 180),
            child: const AppEmptyView(symbol: AppSymbols.location, title: 'Nothing to add', message: 'None of these radios has a position it shares.'),
          ),
        for (var i = 0; i < _rows.length; i++)
          (() {
            final n = _rows[i];
            final already = n.key != null && have.contains(n.key);
            final on = _picked.contains(i);
            return CheckboxListTile(
              key: Key('plan-import-row-$i'),
              contentPadding: EdgeInsets.zero,
              value: already || on,
              onChanged: already || (!on && full)
                  ? null
                  : (v) => setState(() => v == true ? _picked.add(i) : _picked.remove(i)),
              secondary: AppSymbolIcon(n.role == PlanNodeRole.handheld ? AppSymbols.person : AppSymbols.antenna),
              title: Text(n.name),
              subtitle: Text([
                n.role == PlanNodeRole.handheld ? 'Handheld' : 'Repeater',
                if (widget.near != null) kmText(widget.near!, n.point),
                if (already) 'already in the plan',
              ].join(' · ')),
            );
          })(),
        const SizedBox(height: Gap.l),
      ],
    );
  }
}
