// More > Observers when the server offers ID step 5 (`capabilities.radioProof`): the twin of the website page /me/observers.
// Offers (observers whose login names one of your radios as their owner, waiting for your yes or no), your fixed observers
// (how each was proved, last heard, health, where its position is shown; edit name and position; release) and your phones
// (one entry per phone, the "show my radio's name" switch). Names and position go through the claim calls (one copy of those).
// No key is shown or typed here. The caller gates the row on AppState.radioProofCapable.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/time_format.dart' as tf;
import '../../app/messages.dart';
import '../../core/api.dart' show CmatException;
import '../../core/node_claim.dart';
import '../../core/person_observers.dart';
import '../app.dart';
import '../claims/claim_proof_label.dart';
import '../design/app_surfaces.dart';
import '../settings/confirm_sheet.dart';
import '../widgets.dart';

const _tap = Size(48, 48);

/// How the claim was proved, in the site's words: the one shared wording (lib/ui/claims/claim_proof_label.dart).
String methodWords(ClaimMethod m) => claimProofWords(m);

String positionWords(ObserverPosition p) => switch (p) {
      ObserverPosition.hidden => 'Its position is not shown anywhere.',
      ObserverPosition.rounded1km => 'Its position is shown rounded to about 1 km.',
      ObserverPosition.exact => 'Its position is shown exactly.',
    };

String modeWords(String m) => switch (m) {
      'background' => 'Background',
      'home' => 'Home',
      _ => 'Drive',
    };

const String _ownedText = 'Another owner already holds this observer, so it cannot be added.';

class PersonObserversScreen extends StatefulWidget {
  const PersonObserversScreen({super.key});
  @override
  State<PersonObserversScreen> createState() => _PersonObserversScreenState();
}

class _PersonObserversScreenState extends State<PersonObserversScreen> {
  bool _started = false;
  String? _msg;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(AppScope.read(context).personObservers.refresh());
  }

  Future<void> _guard(Future<void> Function() f, String action, {String? owned}) async {
    try {
      await f();
      if (mounted) setState(() => _msg = null);
    } catch (e) {
      if (!mounted) return;
      final isOwned = e is CmatException && e.status == 409 && e.code == 'owned';
      setState(() => _msg = isOwned && owned != null ? owned : friendlyError(e, action: action));
    }
  }

  Future<void> _edit(FixedObserver o) async {
    final c = AppScope.read(context).personObservers;
    final changes = await showAppSheet<Map<String, Object?>>(
      context,
      detents: [MediaQuery.textScalerOf(context).scale(10) > 13 ? 0.92 : 0.7], // large text needs the room for the switch and both buttons
      builder: (ctx, controller) => _EditSheet(o, controller: controller),
    );
    if (changes == null || changes.isEmpty) return;
    await _guard(() => c.updateFixed(o.key, changes), 'Saving the observer');
  }

  Future<void> _release(FixedObserver o) async {
    final c = AppScope.read(context).personObservers;
    final ok = await showConfirmSheet(
      context,
      sheetKey: const Key('observer-release-sheet'),
      title: 'Release this observer?',
      body: 'You stop managing "${o.name}" and its name and position reset. '
          'It keeps feeding data exactly as before. Anyone who proves control can claim it.',
      confirmLabel: 'Release',
      confirmKey: const Key('observer-release-confirm'),
      cancelKey: const Key('observer-release-cancel'),
      destructive: true,
    );
    if (!ok) return;
    await _guard(() => c.release(o.key), 'Releasing the observer');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = s.personObservers;
    final t = Theme.of(context);
    final fixed = c.observers.whereType<FixedObserver>().toList();
    final phones = c.observers.whereType<PhoneObserver>().toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Observers')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: c.refresh,
          child: ListView(
            key: const Key('person-observers-screen'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Radios and phones that listen for you. You choose what is public.',
                        key: const Key('person-observers-intro'),
                        style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: Gap.m),
                      if (_msg != null) ErrorBanner(_msg!),
                      if (c.error != null) ...[
                        ErrorBanner(c.error!),
                        FilledButton.tonalIcon(
                          key: const Key('person-observers-retry'),
                          style: FilledButton.styleFrom(minimumSize: _tap),
                          onPressed: c.refresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again'),
                        ),
                        const SizedBox(height: Gap.m),
                      ],
                      if (c.loading && !c.loadedOnce)
                        const Center(
                          key: Key('person-observers-loading'),
                          child: Padding(
                            padding: EdgeInsets.all(Gap.l),
                            child: Column(children: [CircularProgressIndicator(), SizedBox(height: Gap.s), Text('Loading your observers…')]),
                          ),
                        ),
                      if (c.offers.isNotEmpty) ...[
                        Text(c.offers.length == 1 ? 'Needs your answer' : 'Needs your answer (${c.offers.length})', style: t.textTheme.titleMedium),
                        for (final o in c.offers)
                          _OfferCard(
                            o,
                            onAnswer: (accept) => _guard(() => c.answerOffer(o.key, accept: accept), 'Answering the offer', owned: _ownedText),
                          ),
                        const SizedBox(height: Gap.m),
                      ],
                      if (c.loadedOnce) ...[
                        Text('Your observers', style: t.textTheme.titleMedium),
                        if (c.observers.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: Gap.m),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text(
                                'No observers yet. Connect your radio and this phone shows up here. '
                                'To add a fixed observer, claim it under Claimed radios.',
                                key: Key('person-observers-empty'),
                              ),
                              TextButton.icon(
                                key: const Key('person-observers-empty-refresh'),
                                style: TextButton.styleFrom(minimumSize: _tap),
                                onPressed: c.refresh,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Check again'),
                              ),
                            ]),
                          ),
                        for (final o in fixed) _FixedCard(o, onEdit: () => _edit(o), onRelease: () => _release(o)),
                        for (final o in phones)
                          _PhoneCard(o, onShowName: (v) => _guard(() => c.setShowRadioName(o.key, v), 'Saving the setting')),
                      ],
                      const SizedBox(height: Gap.m),
                      // Folded: one line says the rule, the detail is a tap away for whoever wants it.
                      ExpansionTile(
                        key: const Key('person-observers-public-toggle'),
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: Gap.s),
                        shape: const Border(),
                        collapsedShape: const Border(),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        title: const Text('What is shown in public'),
                        subtitle: const Text('Never your name. Never a phone\'s exact position.'),
                        children: [
                          Text(
                            'A phone is listed under a pseudonym such as "MeshSonar phone 212DE2" and appears as a large area, never a point. '
                            'You can show your radio\'s name instead.\n'
                            'A fixed observer shows its own name, or the one you set, and its position only as you allow.\n'
                            'Owning an observer never changes whether MeshSonar receives or counts what it hears.',
                            key: const Key('person-observers-public'),
                            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: Gap.s),
                      TextButton.icon(
                        key: const Key('person-observers-website'),
                        style: TextButton.styleFrom(minimumSize: _tap),
                        onPressed: () => s.openWebPage('/me/observers'),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Open on the website'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  final ObserverOffer o;
  final void Function(bool accept) onAnswer;
  const _OfferCard(this.o, {required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      key: Key('offer-${o.key}'),
      margin: const EdgeInsets.only(top: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The question first, in bold; the why underneath in one line.
            Text(
              'Is ${o.label}${o.iata == null ? '' : ' (${o.iata})'} yours?',
              key: Key('offer-question-${o.key}'),
              style: t.textTheme.titleSmall,
            ),
            const SizedBox(height: Gap.xs),
            Text('Its login names your radio ${o.radioLabel} as its owner${o.firstSeenAt == null ? '' : ', since ${tf.dateTime(o.firstSeenAt!)}'}.',
                key: Key('offer-why-${o.key}'), style: t.textTheme.bodyMedium),
            Text('Yes adds it to your account. It never takes an observer someone else holds.', style: dim),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.xs,
              children: [
                FilledButton(
                  key: Key('offer-accept-${o.key}'),
                  style: FilledButton.styleFrom(minimumSize: _tap),
                  onPressed: () => onAnswer(true),
                  child: const Text('Yes, it is mine'),
                ),
                OutlinedButton(
                  key: Key('offer-decline-${o.key}'),
                  style: OutlinedButton.styleFrom(minimumSize: _tap),
                  onPressed: () => onAnswer(false),
                  child: const Text('No, not mine'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FixedCard extends StatelessWidget {
  final FixedObserver o;
  final VoidCallback onEdit, onRelease;
  const _FixedCard(this.o, {required this.onEdit, required this.onRelease});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final h = o.health;
    return Card(
      key: Key('observer-${o.key}'),
      margin: const EdgeInsets.only(top: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cell_tower, size: 18),
                const SizedBox(width: Gap.s),
                Expanded(child: Text(o.name, style: t.textTheme.titleSmall)),
                const Chip(label: Text('Observer'), visualDensity: VisualDensity.compact),
              ],
            ),
            if (o.named) Text('It named you as its owner and you agreed', key: Key('observer-proof-${o.key}'), style: dim),
            KeyedSubtree(key: o.named ? null : Key('observer-proof-${o.key}'), child: ClaimProofLabel(o.method, style: ClaimProofStyle.line)),
            Text(o.iata == null ? 'No area yet' : 'Area ${o.iata}', style: dim),
            Text(o.lastHeardAt == null ? 'Not heard yet' : 'Last heard ${tf.dateTime(o.lastHeardAt!)}', key: Key('observer-heard-${o.key}'), style: dim),
            if (o.nodeName != null && o.nodeName != o.name) Text('It calls itself "${o.nodeName}".', style: dim),
            if (h != null) ...[
              const SizedBox(height: Gap.xs),
              Text(h.words, key: Key('observer-health-${o.key}'), style: t.textTheme.bodySmall?.copyWith(color: h.state == 'deaf' ? t.colorScheme.error : null)),
              if (h.batteryMv != null)
                Text(
                  'Battery ${(h.batteryMv! / 1000).toStringAsFixed(2)} V${h.batteryLow ? ' (low)' : ''}'
                  '${h.batteryTrend == null || h.batteryTrend == 'unknown' ? '' : ', ${h.batteryTrend}'}',
                  style: dim,
                ),
            ],
            const SizedBox(height: Gap.xs),
            if (o.blocked) Text('Blocked by an admin.', key: Key('observer-blocked-${o.key}'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            Text(positionWords(o.position), key: Key('observer-position-${o.key}'), style: dim),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.s,
              children: [
                OutlinedButton.icon(
                  key: Key('observer-edit-${o.key}'),
                  style: OutlinedButton.styleFrom(minimumSize: _tap),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Name and position'),
                ),
                OutlinedButton(
                  key: Key('observer-release-${o.key}'),
                  style: OutlinedButton.styleFrom(minimumSize: _tap, foregroundColor: t.colorScheme.error),
                  onPressed: onRelease,
                  child: const Text('Release'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneCard extends StatelessWidget {
  final PhoneObserver o;
  final ValueChanged<bool> onShowName;
  const _PhoneCard(this.o, {required this.onShowName});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final can = o.canShowRadioName;
    final feeds = o.feeds.map((f) => f == 'phone' ? 'the app' : 'its radio (MQTT)').join(' and ');
    return Card(
      key: Key('phone-${o.key}'),
      margin: const EdgeInsets.only(top: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smartphone, size: 18),
                const SizedBox(width: Gap.s),
                Expanded(child: Text(o.name, style: t.textTheme.titleSmall)),
                const Chip(label: Text('Phone'), visualDensity: VisualDensity.compact),
              ],
            ),
            Text('On ${o.deviceName}', style: dim),
            if (o.mode != null) Text('Mode: ${modeWords(o.mode!)}', key: Key('phone-mode-${o.key}'), style: dim),
            Text(o.lastHeardAt == null ? 'Not heard yet' : 'Last heard ${tf.dateTime(o.lastHeardAt!)}', style: dim),
            Text('Reports through $feeds', style: dim),
            if (o.countedOnce)
              Text(
                '${o.installs > 1 ? 'The app was installed ${o.installs} times. ' : ''}'
                '${o.feeds.contains('broker') ? 'It also publishes through its radio. ' : ''}It counts as one observer.',
                key: Key('phone-once-${o.key}'),
                style: dim,
              ),
            SwitchListTile(
              key: Key('phone-show-name-${o.key}'),
              contentPadding: EdgeInsets.zero,
              title: Text('Show my radio\'s name in public${can ? ' (${o.radioName})' : ''}'),
              subtitle: Text(can ? 'Off: listed as "${o.name}".' : 'Connect your radio in the app once to turn this on.'),
              value: o.showRadioName,
              onChanged: can ? onShowName : null,
            ),
            if (o.blocked) Text('Blocked by an admin.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
          ],
        ),
      ),
    );
  }
}

/// Owns its text controller, so it is disposed with the sheet. Pops the changed claim keys only (empty map = nothing changed).
class _EditSheet extends StatefulWidget {
  final FixedObserver o;
  final ScrollController controller;
  const _EditSheet(this.o, {required this.controller});
  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.o.editableName);
  late bool _shown = widget.o.positionShown;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Map<String, Object?> _changes() {
    final o = widget.o;
    final n = _name.text.trim();
    return {
      if (n != o.editableName) 'displayName': n.isEmpty ? null : n,
      if (_shown != o.positionShown) 'positionPublic': _shown,
    };
  }

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.controller,
        title: 'Name and position',
        primaryAction: FilledButton(key: const Key('observer-edit-save'), onPressed: () => Navigator.pop(context, _changes()), child: const Text('Save')),
        secondaryAction: TextButton(key: const Key('observer-edit-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        children: [
          TextField(
            key: const Key('observer-edit-name'),
            controller: _name,
            // No autofocus: the keyboard would cover the position switch, which is half of what this sheet is for.
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Public name',
              hintText: widget.o.nodeName ?? 'Its own name',
              helperText: 'Empty uses its own name.',
              suffixIcon: IconButton(key: const Key('observer-edit-name-clear'), tooltip: 'Clear', icon: const Icon(Icons.clear), onPressed: _name.clear),
            ),
          ),
          SwitchListTile(
            key: const Key('observer-edit-position'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Show its position in public'),
            subtitle: const Text('Off: hidden everywhere. It is still listed and counted.'),
            value: _shown,
            onChanged: (v) => setState(() => _shown = v),
          ),
        ],
      );
}
