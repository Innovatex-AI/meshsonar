// More > Observers when the server offers ID step 5 (`capabilities.radioProof`): the twin of the website page /me/observers.
// Offers (observers whose login names one of your radios as their owner, waiting for your yes or no), your fixed observers
// (how each was proved, last heard, health, where its position is shown; edit name and position; release) and your phones
// (one entry per phone, the "show my radio's name" switch). Names and position go through the claim calls (one copy of those).
// No key is shown or typed here. The caller gates the row on AppState.radioProofCapable.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/messages.dart';
import '../../core/api.dart' show CmatException;
import '../../core/node_claim.dart';
import '../../core/person_observers.dart';
import '../app.dart';
import '../claims/claim_proof_label.dart';
import '../design/app_surfaces.dart';
import '../settings/confirm_sheet.dart';
import '../widgets.dart';

String _when(DateTime? t) {
  if (t == null) return 'not yet';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

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
      detents: const [0.7],
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
      body: 'You stop managing "${o.name}". Its name and position go back to the defaults. '
          'It keeps feeding data exactly as before, and anyone who proves control can claim it.',
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
                        'The radios that listen for you and the phones that report what they hear. Each one is counted once, and you choose what shows in public.',
                        key: const Key('person-observers-intro'),
                        style: t.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: Gap.m),
                      if (_msg != null) ErrorBanner(_msg!),
                      if (c.error != null) ...[
                        ErrorBanner(c.error!),
                        TextButton(key: const Key('person-observers-retry'), onPressed: c.refresh, child: const Text('Try again')),
                      ],
                      if (c.loading && !c.loadedOnce)
                        const Center(
                          child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator()),
                        ),
                      if (c.offers.isNotEmpty) ...[
                        Text('Needs your answer', style: t.textTheme.titleMedium),
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
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: Gap.m),
                            child: Text(
                              'No observers yet. Connect your radio in the MeshSonar app and the phone shows up here by itself. '
                              'An observer you run on your own radio is added by claiming it under Claimed radios.',
                              key: Key('person-observers-empty'),
                            ),
                          ),
                        for (final o in fixed) _FixedCard(o, onEdit: () => _edit(o), onRelease: () => _release(o)),
                        for (final o in phones)
                          _PhoneCard(o, onShowName: (v) => _guard(() => c.setShowRadioName(o.key, v), 'Saving the setting')),
                      ],
                      const SizedBox(height: Gap.m),
                      Text('What is shown in public', style: t.textTheme.titleMedium),
                      const SizedBox(height: Gap.xs),
                      Text(
                        'A phone is listed under a pseudonym such as "MeshSonar phone 212DE2", never your name. While it is online it appears as a large area '
                        '(several kilometres across), never as a point. You can choose to show the name of your phone\'s radio instead. '
                        'A fixed observer shows its own name, or the name you set, and its position only as you allow it. '
                        'Owning an observer here never changes whether MeshSonar receives or counts what it hears.',
                        key: const Key('person-observers-public'),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: Gap.l),
                      TextButton.icon(
                        key: const Key('person-observers-website'),
                        onPressed: () => s.openWebPage('/me/observers'),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('View this page on the website'),
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
            Text(
              '${o.label}${o.iata == null ? '' : ' (${o.iata})'} says it belongs to you, because its login names your radio ${o.radioLabel} as its owner. Is that observer yours?',
              style: t.textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'Named you since ${_when(o.firstSeenAt)}. Saying yes adds it to your account as a claim with the weakest proof '
              '(the observer\'s own word and your radio); it never takes an observer that someone else holds.',
              style: dim,
            ),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              children: [
                FilledButton(key: Key('offer-accept-${o.key}'), onPressed: () => onAnswer(true), child: const Text('Yes, it is mine')),
                OutlinedButton(key: Key('offer-decline-${o.key}'), onPressed: () => onAnswer(false), child: const Text('No, not mine')),
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
            Text(o.lastHeardAt == null ? 'Not heard yet' : 'Last heard ${_when(o.lastHeardAt)}', key: Key('observer-heard-${o.key}'), style: dim),
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
            Text('${o.blocked ? 'This observer is blocked by an admin. ' : ''}${positionWords(o.position)}', key: Key('observer-position-${o.key}'), style: dim),
            Wrap(
              children: [
                TextButton(key: Key('observer-edit-${o.key}'), onPressed: onEdit, child: const Text('Edit name and position')),
                TextButton(
                  key: Key('observer-release-${o.key}'),
                  onPressed: onRelease,
                  child: Text('Release', style: TextStyle(color: t.colorScheme.error)),
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
    final feeds = o.feeds.map((f) => f == 'phone' ? "the app's upload" : 'the MQTT broker through its radio').join(' and ');
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
            Text(o.lastHeardAt == null ? 'Not heard yet' : 'Last heard ${_when(o.lastHeardAt)}', style: dim),
            Text('Reports through $feeds', style: dim),
            if (o.countedOnce)
              Text(
                '${o.installs > 1 ? 'This phone has had the app installed ${o.installs} times. ' : ''}'
                '${o.feeds.contains('broker') ? 'It also publishes through its radio. ' : ''}It counts as one observer.',
                key: Key('phone-once-${o.key}'),
                style: dim,
              ),
            SwitchListTile(
              key: Key('phone-show-name-${o.key}'),
              contentPadding: EdgeInsets.zero,
              title: Text('Show my radio\'s name in public${can ? ' (${o.radioName})' : ''}'),
              subtitle: Text(can
                  ? 'Off, the phone is listed under the pseudonym above.'
                  : 'Connect your radio in the app once, so MeshSonar knows which radio this phone uses.'),
              value: o.showRadioName,
              onChanged: can ? onShowName : null,
            ),
            if (o.blocked) Text('This observer is blocked by an admin.', style: dim),
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
        title: 'Edit name and position',
        primaryAction: FilledButton(key: const Key('observer-edit-save'), onPressed: () => Navigator.pop(context, _changes()), child: const Text('Save')),
        secondaryAction: TextButton(key: const Key('observer-edit-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        children: [
          TextField(
            key: const Key('observer-edit-name'),
            controller: _name,
            autofocus: true,
            maxLength: 60,
            decoration: InputDecoration(
              labelText: 'Name shown on MeshSonar pages',
              hintText: widget.o.nodeName ?? 'Leave empty to use its own name',
            ),
          ),
          SwitchListTile(
            key: const Key('observer-edit-position'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Show this observer\'s position on the maps and pages'),
            subtitle: const Text('Off, its position is hidden everywhere on MeshSonar. It is still listed and counted.'),
            value: _shown,
            onChanged: (v) => setState(() => _shown = v),
          ),
        ],
      );
}
