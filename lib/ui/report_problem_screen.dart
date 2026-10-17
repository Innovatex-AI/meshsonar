// "Report a problem": the person describes it, reviews the exact text that will be sent (keys removed, locations
// rounded), and sends it to the server in Settings with their driver key. A report that can't be sent stays saved on
// the phone, with its form, until they send or discard it; nothing is ever sent without the Send tap on the review
// screen.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import '../core/report_body.dart';
import 'app.dart';
import 'onboarding/ui_prefs.dart';
import 'settings_screen.dart' show DriverKeyScreen;
import 'widgets.dart';

/// Opens the report form; [driveId] pre-selects that drive to attach.
void openReportProblem(BuildContext context, {String? driveId}) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReportProblemScreen(driveId: driveId)));
}

const Map<String, String> _categoryLabels = {
  'bug': 'Bug',
  'radio': 'Radio',
  'gps': 'GPS',
  'upload': 'Upload',
  'map': 'Map',
  'idea': 'Idea',
  'other': 'Other',
};

/// 4000 → "4,000".
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

class ReportProblemScreen extends StatefulWidget {
  final String? driveId;
  const ReportProblemScreen({super.key, this.driveId});
  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _description = TextEditingController();
  String? _category;
  bool _includeLog = true;
  late String? _driveId = widget.driveId;
  bool _building = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // A report that wasn't sent comes back as it was written (a drive chosen on the way in still wins).
    final form = AppScope.read(context).savedReport?.form;
    if (form == null) return;
    _category = form.category;
    _description.text = form.description;
    _includeLog = form.includeLog;
    _driveId = widget.driveId ?? form.driveId;
  }

  ReportForm get _form =>
      ReportForm(category: _category!, description: _description.text, includeLog: _includeLog, driveId: _driveId);

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _review(AppState s) async {
    setState(() => _building = true);
    final report = await s.previewProblemReport(
      category: _category!,
      description: _description.text,
      includeLog: _includeLog,
      driveId: _driveId,
    );
    if (!mounted) return;
    setState(() => _building = false);
    await _openPreview(report, _form);
  }

  /// The review screen pops true when the report is finished with (sent or discarded), and the form closes too.
  Future<void> _openPreview(ProblemReport report, ReportForm form) async {
    final nav = Navigator.of(context);
    final done = await nav.push<bool>(
      MaterialPageRoute(
        builder: (_) => ReportPreviewScreen(report: report, form: form),
      ),
    );
    if (done == true && mounted) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final length = _description.text.trim().length;
    final tooLong = length > problemReportMaxDescription;
    final canReview = s.canReport && _category != null && length > 0 && !tooLong && !_building;
    final saved = s.savedReport;
    return Scaffold(
      key: const Key('report-screen'),
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        // Not a lazy list: the form is short, and every field stays reachable (e.g. by a screen reader).
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (saved != null) _SavedReport(onSend: () => _openPreview(saved.report, saved.form)),
              if (!s.canReport) _NeedsKey(status: s.hasKey ? s.settings.keyStatus : DriverKeyStatus.none),
              Text('What kind of problem?', style: t.textTheme.titleMedium),
              const SizedBox(height: Gap.s),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  for (final c in problemReportCategories)
                    ChoiceChip(
                      key: ValueKey('report-category-$c'),
                      label: Text(_categoryLabels[c]!),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                ],
              ),
              const SizedBox(height: Gap.l),
              TextField(
                key: const Key('report-description'),
                controller: _description,
                minLines: 4,
                maxLines: 10,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'What happened?',
                  hintText: 'What you were doing, what you expected, and what happened instead.',
                  alignLabelWithHint: true,
                  errorText: tooLong
                      ? 'Keep it to ${_thousands(problemReportMaxDescription)} characters or fewer.'
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Gap.xs),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${_thousands(length)} / ${_thousands(problemReportMaxDescription)}',
                  key: const Key('report-counter'),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: tooLong ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              SwitchListTile(
                key: const Key('report-include-log'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Include app log'),
                subtitle: const Text('Recent app events and your settings, with keys removed and locations rounded.'),
                value: _includeLog,
                onChanged: (v) => setState(() => _includeLog = v),
              ),
              const SizedBox(height: Gap.s),
              _DrivePicker(state: s, value: _driveId, onChanged: (v) => setState(() => _driveId = v)),
              const SizedBox(height: Gap.m),
              Text(
                'Also sent: the app version, your phone\'s system and language, and the connected radio\'s settings. '
                'You see everything before it is sent.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.l),
              FilledButton.icon(
                key: const Key('report-review'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: canReview ? () => _review(s) : null,
                icon: const Icon(Icons.preview_outlined),
                label: const Text('Review report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The report saved on the phone after it couldn't be sent: send it (after seeing it again) or discard it.
class _SavedReport extends StatelessWidget {
  final VoidCallback onSend;
  const _SavedReport({required this.onSend});

  Future<void> _discard(BuildContext context) async {
    final s = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard the saved report?'),
        content: const Text('It hasn\'t been sent, and it will be deleted from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            key: const Key('report-discard-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok == true) await s.discardSavedReport();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.l),
      color: t.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('A report hasn\'t been sent yet', style: t.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              'It is saved on this phone. Send it when you have signal, or discard it.',
              style: t.textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.m),
            FilledButton.icon(
              key: const Key('report-send-saved'),
              onPressed: onSend,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send saved report'),
            ),
            TextButton(
              key: const Key('report-discard-saved'),
              onPressed: () => _discard(context),
              child: const Text('Discard'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Why this phone can't report yet, with a way to the driver key settings.
class _NeedsKey extends StatelessWidget {
  final DriverKeyStatus status;
  const _NeedsKey({required this.status});

  @override
  Widget build(BuildContext context) {
    final why = switch (status) {
      DriverKeyStatus.none =>
        'Problem reports are sent with your driver key, and this phone doesn\'t have one yet. '
            'Request a key, or paste one from the website, in Settings.',
      DriverKeyStatus.rejected || DriverKeyStatus.revoked =>
        'Your driver key was ${status.name}, so the server won\'t take reports from it. Check the key in Settings.',
      _ =>
        'The server doesn\'t recognise this driver key, so it won\'t take reports from it. Check the key in Settings.',
    };
    return Padding(
      key: const Key('report-needs-key'),
      padding: const EdgeInsets.only(bottom: Gap.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ErrorBanner(why),
          TextButton.icon(
            key: const Key('report-key-settings'),
            // The key settings open over this form, so what was typed is still here on the way back.
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DriverKeyScreen())),
            icon: const Icon(Icons.vpn_key_outlined),
            label: const Text('Open driver key settings'),
          ),
        ],
      ),
    );
  }
}

/// "Attach a drive": none, or one of the recent drives (only its id is sent).
class _DrivePicker extends StatelessWidget {
  final AppState state;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _DrivePicker({required this.state, required this.value, required this.onChanged});

  static const _recent = 20;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final drives = s.sessions.take(_recent).map((x) => x.session).toList();
    String label(String id, DateTime startedAt, String? recorded) {
      final name = driveLabel(s, id, recorded);
      return name == null ? formatDateTime(startedAt) : '$name, ${formatDateTime(startedAt)}';
    }

    return DropdownButtonFormField<String?>(
      key: const Key('report-attach-drive'),
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Attach a drive',
        helperText: 'Sends only the drive\'s ID, never its pings.',
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('None')),
        for (final d in drives)
          DropdownMenuItem<String?>(
            value: d.id,
            child: Text(label(d.id, d.startedAt, d.label), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        if (value != null && drives.every((d) => d.id != value))
          DropdownMenuItem<String?>(value: value, child: const Text('This drive')),
      ],
      onChanged: onChanged,
    );
  }
}

/// The exact report that will be sent, with its size and what was removed. The only Send button is here.
class ReportPreviewScreen extends StatefulWidget {
  final ProblemReport report;

  /// The form [report] was built from; kept with it on the phone until the server takes it.
  final ReportForm form;
  const ReportPreviewScreen({super.key, required this.report, required this.form});
  @override
  State<ReportPreviewScreen> createState() => _ReportPreviewScreenState();
}

class _ReportPreviewScreenState extends State<ReportPreviewScreen> {
  bool _sending = false;
  ProblemReportOutcome? _outcome;

  static String _size(int bytes) => '${(bytes / 1000000).toStringAsFixed(1)} MB of 5 MB';

  static String _plural(int n, String one) => '$n $one${n == 1 ? '' : 's'}';

  Future<void> _send(AppState s) async {
    final saved = s.savedReport;
    if (saved != null && saved.report.body != widget.report.body && !await _confirmReplace()) return;
    setState(() => _sending = true);
    final outcome = await s.sendProblemReport(widget.report, form: widget.form);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _outcome = outcome;
    });
  }

  Future<void> _discard(AppState s) async {
    final nav = Navigator.of(context);
    await s.discardSavedReport();
    nav.pop(true);
  }

  Future<bool> _confirmReplace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace the saved report?'),
        content: const Text(
          'A report saved on this phone hasn\'t been sent. If this one can\'t be sent either, it '
          'replaces the saved one.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('report-replace-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send this one'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final r = widget.report;
    final outcome = _outcome;
    final sent = outcome?.sent ?? false;
    final rejected = outcome?.rejected ?? false;
    final host = Uri.tryParse(s.settings.serverUrl)?.host ?? s.settings.serverUrl;
    final note = t.textTheme.bodyMedium;
    return Scaffold(
      key: const Key('report-preview'),
      appBar: AppBar(title: const Text('Check your report')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('This is exactly what will be sent to $host.', style: t.textTheme.titleMedium),
                    const SizedBox(height: Gap.xs),
                    Text(_size(r.bytes), style: note),
                    Text(
                      'We removed ${_plural(r.removedKeys, 'key')} and rounded ${_plural(r.roundedLocations, 'location')}.',
                      style: note,
                    ),
                    if (r.logShortened) Text('Log shortened to fit 5 MB.', style: note),
                    if (r.tooLarge) const ErrorBanner('Description too long'),
                    const SizedBox(height: Gap.m),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(Corners.chip),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.m),
                        child: SelectableText(
                          r.body,
                          key: const Key('report-preview-body'),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (outcome != null)
                    Semantics(
                      liveRegion: true,
                      child: sent
                          ? Padding(
                              key: const Key('report-result'),
                              padding: const EdgeInsets.symmetric(vertical: Gap.s),
                              child: Text(outcome.message, style: t.textTheme.titleMedium),
                            )
                          : ErrorBanner(outcome.message, key: const Key('report-result')),
                    ),
                  if (rejected) ...[
                    FilledButton.icon(
                      key: const Key('report-edit'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit report'),
                    ),
                    TextButton(
                      key: const Key('report-discard'),
                      onPressed: () => _discard(s),
                      child: const Text('Discard'),
                    ),
                  ] else if (sent)
                    FilledButton(
                      key: const Key('report-done'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Done'),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('report-send'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: r.tooLarge || _sending ? null : () => _send(s),
                      icon: _sending
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_outlined),
                      label: const Text('Send report'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
