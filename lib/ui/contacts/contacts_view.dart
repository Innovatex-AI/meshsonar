// The Contacts half of the Chat tab: search, filters, new nodes nearby, favourites and everyone else, with every state
// (no radio, syncing, failed, full, empty) said in plain words. No Scaffold of its own: it sits inside the Chat tab's.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../drive/drive_controls.dart' show openConnect;
import '../theme.dart';
import '../widgets.dart' show EmptyState;
import 'add_contact_screen.dart';
import 'contact_detail_screen.dart';
import 'contact_widgets.dart';
import 'contacts_controller.dart';
import 'contacts_settings_sheet.dart';
import 'qr_scan_screen.dart';
import 'radio_list_sheet.dart';

class ContactsView extends StatefulWidget {
  final ContactsController controller;

  /// "Connect radio" buttons. Default: the app's connect sheet.
  final void Function(BuildContext context)? onConnect;

  /// Tests inject a fake camera for the Add contact screen.
  final ScannerBuilder? scannerBuilder;
  const ContactsView({super.key, required this.controller, this.onConnect, this.scannerBuilder});

  @override
  State<ContactsView> createState() => _ContactsViewState();
}

class _ContactsViewState extends State<ContactsView> {
  final _search = TextEditingController();
  StreamSubscription<ContactNotice>? _notices;
  bool _allNearby = false;

  ContactsController get _c => widget.controller;
  ContactManager get _m => _c.manager;

  @override
  void initState() {
    super.initState();
    _notices = _m.notices.listen((n) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(n.message), duration: const Duration(seconds: 6)));
    });
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    _search.dispose();
    super.dispose();
  }

  void _connect() => (widget.onConnect ?? openConnect)(context);

  void _add() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddContactScreen(controller: _c, scannerBuilder: widget.scannerBuilder)));

  void _details(Contact c) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactDetailScreen(controller: _c, publicKey: c.publicKey)));

  /// A person opens their conversation (the thing you came here to do); everything else, and anyone when no conversation
  /// screen is wired, opens the details. People get an info button for the details.
  bool _converses(Contact c) => _c.openConversation != null && c.type == ContactType.companion;
  void _open(Contact c) => _converses(c) ? _c.openConversation!(context, c) : _details(c);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final total = _c.totalContacts;
        final nearby = _c.nearby;
        final connected = _m.connected;
        if (total == 0 && nearby.isEmpty && !connected) return _noRadio(context);
        final items = <Widget>[
          _header(context),
          ..._banners(context, total, connected),
          if (_m.shouldOfferAskFirst) _askFirst(context),
          if (nearby.isNotEmpty) ..._nearbySection(context, nearby),
          ..._contactSections(context, total, connected),
        ];
        return RefreshIndicator(
          onRefresh: () => _m.syncNow(full: true),
          child: ListView.builder(
            key: const Key('contacts-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: Gap.xl),
            itemCount: items.length,
            itemBuilder: (_, i) => items[i],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ pieces

  Widget _noRadio(BuildContext context) => EmptyState(
        key: const Key('contacts-no-radio'),
        icon: Icons.people_outline_rounded,
        title: 'Your contacts appear here',
        body: 'Connect your MeshCore radio once. Its contacts are copied to this phone and stay here, even when the radio is off.',
        action: FilledButton.icon(
          key: const Key('contacts-connect'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _connect,
          icon: const Icon(Icons.bluetooth_searching_rounded),
          label: const Text('Connect radio'),
        ),
      );

  Widget _header(BuildContext context) {
    final s = _m.state;
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const Key('contacts-search'),
          controller: _search,
          onChanged: _c.setQuery,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search contacts',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    key: const Key('contacts-search-clear'),
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: _clearSearch,
                  ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(Corners.chip)),
            isDense: false,
          ),
        ),
        const SizedBox(height: Gap.s),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: const Key('contacts-add'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Add contact'),
            ),
          ),
          const SizedBox(width: Gap.s),
          IconButton.outlined(
            key: const Key('contacts-settings'),
            tooltip: 'Contact settings',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => showContactsSettings(context, _c),
          ),
        ]),
        const SizedBox(height: Gap.s),
        SingleChildScrollView(
          key: const Key('contacts-filters'),
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in ContactFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: Gap.s),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: ChoiceChip(
                    key: Key('filter-${f.name}'),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    label: Text(f.label),
                    selected: _c.filter == f,
                    onSelected: (_) => _c.setFilter(f),
                  ),
                ),
              ),
          ]),
        ),
        if (_m.connected && s.radioCount != null && s.capacity != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('contacts-usage'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48), padding: EdgeInsets.zero),
              onPressed: () => showRadioListSheet(context, _c),
              child: Text('On your radio: ${s.radioCount} of ${s.capacity} contacts', style: t.textTheme.bodyMedium),
            ),
          ),
      ]),
    );
  }

  void _clearSearch() {
    _search.clear();
    _c.setQuery('');
    setState(() {});
  }

  Widget _banner(BuildContext context, {required Key key, required IconData icon, required String text, Color? color, Widget? action, Widget? extra}) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
      child: Card(
        key: key,
        color: color ?? t.colorScheme.surfaceContainerHigh,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 22),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
            ]),
            if (extra != null) ...[const SizedBox(height: Gap.s), extra],
            if (action != null) Align(alignment: Alignment.centerRight, child: action),
          ]),
        ),
      ),
    );
  }

  List<Widget> _banners(BuildContext context, int total, bool connected) {
    final s = _m.state;
    final t = Theme.of(context);
    return [
      if (!connected)
        _banner(context,
            key: const Key('banner-offline'),
            icon: Icons.bluetooth_disabled_rounded,
            text: 'Radio not connected. Showing the contacts saved on this phone. Messages wait and send when it is back.',
            action: TextButton(key: const Key('banner-connect'), style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: _connect, child: const Text('Connect radio'))),
      if (s.phase == SyncPhase.syncing)
        _banner(context,
            key: const Key('banner-syncing'),
            icon: Icons.sync_rounded,
            text: s.total > 0 ? 'Loading contacts from your radio: ${s.received} of ${s.total}' : 'Asking your radio for its contacts',
            extra: LinearProgressIndicator(value: s.total > 0 ? (s.received / s.total).clamp(0, 1).toDouble() : null)),
      if (s.phase == SyncPhase.failed)
        _banner(context,
            key: const Key('banner-failed'),
            icon: Icons.error_outline_rounded,
            color: t.colorScheme.errorContainer,
            text: s.error ?? 'The contact list could not be read from the radio.',
            action: FilledButton.tonal(key: const Key('banner-retry'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => _m.syncNow(), child: const Text('Try again'))),
      if (connected && s.tableFull)
        _banner(context,
            key: const Key('banner-full'),
            icon: Icons.inventory_2_outlined,
            color: t.colorScheme.errorContainer,
            text: 'Your radio\'s contact list is full${s.radioCount != null && s.capacity != null ? ' (${s.radioCount} of ${s.capacity})' : ''}. It cannot add new nodes until you free space.',
            action: FilledButton.tonal(key: const Key('banner-free'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => showRadioListSheet(context, _c), child: const Text('Free up space'))),
    ];
  }

  Widget _askFirst(BuildContext context) => _banner(context,
      key: const Key('ask-first'),
      icon: Icons.person_search_rounded,
      text: 'Your radio adds every node it hears. That fills its contact list with strangers. Ask me before adding?',
      action: Wrap(spacing: Gap.s, children: [
        TextButton(key: const Key('ask-keep'), style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => _m.answerPolicyPrompt('keep'), child: const Text('Keep automatic')),
        FilledButton(
          key: const Key('ask-yes'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            try {
              await _m.setPolicy(_m.state.policy!.copyWith(askBeforeAdding: true));
              _m.answerPolicyPrompt('ask');
            } catch (_) {
              messenger?.showSnackBar(const SnackBar(content: Text('The radio did not take that. Try again in a moment.')));
            }
          },
          child: const Text('Ask me first'),
        ),
      ]));

  // ------------------------------------------------------------------ new nodes nearby

  List<Widget> _nearbySection(BuildContext context, List<AdvertSeen> nearby) {
    final t = Theme.of(context);
    final shown = _allNearby ? nearby : nearby.take(3).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
        child: Semantics(header: true, child: Text('New nodes nearby', key: const Key('nearby-title'), style: t.textTheme.titleMedium)),
      ),
      for (final a in shown) _NearbyRow(key: Key('nearby-${a.publicKey.substring(0, 8)}'), advert: a, controller: _c),
      if (nearby.length > 3)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('nearby-more'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => setState(() => _allNearby = !_allNearby),
              child: Text(_allNearby ? 'Show fewer' : 'See all ${nearby.length}'),
            ),
          ),
        ),
    ];
  }

  // ------------------------------------------------------------------ contacts

  List<Widget> _contactSections(BuildContext context, int total, bool connected) {
    final rows = _c.rows;
    final t = Theme.of(context);
    if (total == 0) {
      final s = _m.state;
      if (s.phase == SyncPhase.syncing || s.phase == SyncPhase.failed || _c.nearby.isNotEmpty) return const [];
      return [
        Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(key: const Key('contacts-empty'), children: [
            Icon(Icons.people_outline_rounded, size: 40, color: t.colorScheme.primary),
            const SizedBox(height: Gap.m),
            Text('No contacts yet', style: t.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(
              'Nodes your radio hears will show under New nodes nearby. You can also add one by QR code, link or key.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ]),
        ),
      ];
    }
    if (rows.isEmpty) {
      final q = _c.query.trim();
      return [
        Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(key: const Key('contacts-no-match'), children: [
            Text(q.isNotEmpty ? 'No contact matches \'$q\'' : 'No contacts in ${_c.filter.label}', style: t.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: Gap.s),
            OutlinedButton(
              key: const Key('contacts-clear-filters'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                _clearSearch();
                _c.setFilter(ContactFilter.all);
              },
              child: Text(q.isNotEmpty ? 'Clear search' : 'Show all contacts'),
            ),
          ]),
        ),
      ];
    }
    final plain = _c.filter != ContactFilter.all && _c.filter != ContactFilter.people && _c.filter != ContactFilter.repeaters && _c.filter != ContactFilter.rooms && _c.filter != ContactFilter.sensors;
    final favs = plain ? const <ContactRow>[] : rows.where((r) => r.contact.favourite).toList();
    final rest = plain ? rows : rows.where((r) => !r.contact.favourite).toList();
    Widget title(String s, Key k) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
          child: Semantics(header: true, child: Text(s, key: k, style: t.textTheme.titleMedium)),
        );
    return [
      if (favs.isNotEmpty) ...[title('Favourites', const Key('title-favourites')), for (final r in favs) _tile(r)],
      if (rest.isNotEmpty) ...[
        if (!plain) title(favs.isEmpty ? 'Contacts' : 'All contacts', const Key('title-all')),
        for (final r in rest) _tile(r),
      ],
    ];
  }

  Widget _tile(ContactRow r) => ContactTile(
      key: Key('contact-${r.contact.publicKey.substring(0, 8)}'),
      row: r,
      nowMs: _c.nowMs(),
      onTap: () => _open(r.contact),
      onDetails: _converses(r.contact) ? () => _details(r.contact) : null);
}

/// One contact in the list.
class ContactTile extends StatelessWidget {
  final ContactRow row;
  final int nowMs;
  final VoidCallback onTap;

  /// Shown as an info button after the row when tapping the row does something other than open the details.
  final VoidCallback? onDetails;
  const ContactTile({super.key, required this.row, required this.nowMs, required this.onTap, this.onDetails});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = row.contact;
    final status = (row.preview != null && row.preview!.isNotEmpty) ? row.preview! : heardText(c.lastHeardMs ?? (c.lastAdvertTs == null ? null : c.lastAdvertTs! * 1000), nowMs);
    final route = !c.hasPath ? 'no route yet' : ((c.pathHops ?? 0) == 0 ? 'direct' : 'direct, ${c.pathHops} ${c.pathHops == 1 ? 'hop' : 'hops'}');
    final unread = row.unread;
    final label = '${c.displayName}, ${contactTypeLabel(c.type)}, $status${unread > 0 ? ', $unread unread' : ''}';
    final small = MediaQuery.textScalerOf(context).scale(14) < 14 * 1.6;
    final main = Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: EdgeInsets.fromLTRB(Gap.l, Gap.s, onDetails == null ? Gap.l : Gap.xs, Gap.s),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              ContactAvatar(c),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(c.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall)),
                    if (c.favourite) const Padding(padding: EdgeInsets.only(left: Gap.xs), child: Icon(Icons.star_rounded, size: 16)),
                  ]),
                  Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  if (small)
                    Text('${contactTypeLabel(c.type)} · $route', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant))
                  else
                    Text(contactTypeLabel(c.type), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
              if (unread > 0)
                Container(
                  margin: const EdgeInsets.only(left: Gap.s),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: t.colorScheme.primary, borderRadius: BorderRadius.circular(12)),
                  child: Text('$unread', style: TextStyle(color: t.colorScheme.onPrimary, fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
        ),
      ),
    );
    if (onDetails == null) return main;
    return Row(children: [
      Expanded(child: main),
      IconButton(
        key: Key('contact-details-${c.publicKey.substring(0, 8)}'),
        tooltip: 'Details of ${c.displayName}',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: const Icon(Icons.info_outline_rounded),
        onPressed: onDetails,
      ),
      const SizedBox(width: Gap.xs),
    ]);
  }
}

class _NearbyRow extends StatelessWidget {
  final AdvertSeen advert;
  final ContactsController controller;
  const _NearbyRow({super.key, required this.advert, required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = advert;
    final type = a.type ?? ContactType.companion;
    final hops = (a.pathLen == null || a.pathLen == 0xFF) ? null : a.pathLen! & 63;
    final detail = '${heardText(a.lastTsMs, controller.nowMs()).replaceFirst('Heard ', 'heard ')}${hops == null ? '' : ', $hops ${hops == 1 ? 'hop' : 'hops'}'}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
      child: Semantics(
        container: true,
        label: 'New node ${a.name}, ${contactTypeLabel(type)}, $detail',
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          ExcludeSemantics(child: CircleAvatar(radius: 20, child: Icon(contactTypeIcon(type), size: 20))),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
              Text('${contactTypeLabel(type)}, $detail', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              Wrap(spacing: Gap.s, children: [
                TextButton(
                  key: Key('nearby-add-${a.publicKey.substring(0, 8)}'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () async {
                    final r = await controller.manager.addNearby(a);
                    if (!context.mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                        content: Text(r.ok ? 'Added ${a.name}.${r.note == null ? '' : ' ${r.note}'}' : (r.error ?? 'That could not be added.'))));
                  },
                  child: const Text('Add'),
                ),
                TextButton(
                  key: Key('nearby-ignore-${a.publicKey.substring(0, 8)}'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => controller.manager.ignoreNearby(a.publicKey),
                  child: const Text('Ignore'),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
