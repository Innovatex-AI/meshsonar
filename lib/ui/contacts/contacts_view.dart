// The Contacts segment of the Chat tab (plan 4.5): people only, Favourites then A-Z under sticky letter headers, one
// collapsed "New nodes nearby" row, one status banner, swipe actions, and a foot with the contact settings. Repeaters,
// rooms and sensors live in the Network segment. No Scaffold of its own: it sits inside the Chat tab's.
//
// Swipe: leading Message and Favourite, trailing Ping and Remove (action sheet). Tap = the Contact profile, always.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../../radio/caps.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/app_widgets.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../drive/drive_controls.dart' show openConnect;
import '../tools/adverts_screen.dart';
import 'add_contact_screen.dart';
import 'contact_profile_screen.dart';
import 'contact_remove.dart';
import 'contact_widgets.dart';
import 'contacts_controller.dart';
import 'contacts_grouping.dart';
import 'contacts_settings_sheet.dart';
import 'profile_sheets.dart';
import 'profile_tiles.dart';
import 'qr_scan_screen.dart';
import 'radio_list_sheet.dart';

const double kContactAvatar = 52;
const double _kRowMin = 72;
const double _kDividerInset = Layout.screenMargin + kContactAvatar + 12;

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

  ContactsController get _c => widget.controller;
  ContactManager get _m => _c.manager;

  @override
  void initState() {
    super.initState();
    _notices = _m.notices.listen((n) {
      if (mounted) showAppToast(context, n.message, duration: const Duration(seconds: 6));
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

  void _advert() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AdvertsScreen()));

  void _profile(Contact c) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactProfileScreen(controller: _c, publicKey: c.publicKey)));

  void _message(Contact c) => _c.openConversation?.call(context, c);

  void _favourite(Contact c) {
    AppHaptics.selection();
    _m.setFavourite(c.publicKey, !c.favourite);
  }

  Future<void> _ping(Contact c) async {
    final tile = profileTiles(c, connected: _m.connected, caps: RadioCaps.baseline, canMessage: false, canAdmin: false, redesign: true)
        .where((t) => t.id == ProfileTileId.ping)
        .firstOrNull;
    if (tile != null && !tile.enabled) {
      showAppToast(context, tile.reason ?? 'Not available right now.');
      return;
    }
    await showPingSheet(context, c);
  }

  Future<void> _remove(Contact c) => removeContactFlow(context, _c, c);

  void _clearSearch() {
    _search.clear();
    _c.setQuery('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final total = _c.totalContacts;
        final nearby = _c.nearby;
        final connected = _m.connected;
        if (total == 0 && nearby.isEmpty && !connected) return _noRadio(context);
        final people = _c.peopleCount;
        final groups = groupContacts(_c.rows);
        final q = _c.query.trim();
        final now = _c.nowMs();
        return CustomScrollView(
          key: const Key('contacts-list'),
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: () => _m.syncNow(full: true)),
            SliverToBoxAdapter(child: _searchField(people)),
            SliverToBoxAdapter(child: _banner(context, total, connected)),
            if (nearby.isNotEmpty) SliverToBoxAdapter(child: _NearbyRow(count: nearby.length, onTap: () => _showNearby(context))),
            if (people == 0)
              SliverFillRemaining(hasScrollBody: false, child: _empty(context, hasOthers: total > 0))
            else if (groups.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _noMatch(context, q))
            else ...[
              if (groups.favourites.isNotEmpty) _section('Favourites', const Key('title-favourites'), groups.favourites, now, favouriteGroup: true),
              for (final g in groups.letters) _section(g.letter, Key('title-letter-${g.letter}'), g.rows, now),
            ],
            if (people > 0 && !groups.isEmpty) SliverToBoxAdapter(child: _foot(context)),
            const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------------ pieces

  Widget _noRadio(BuildContext context) => AppEmptyView(
        key: const Key('contacts-no-radio'),
        symbol: AppSymbols.person2,
        title: 'Your contacts appear here',
        message: 'Connect your MeshCore radio once. Its contacts are copied to this phone and stay here, even when the radio is off.',
        actionLabel: 'Connect radio',
        onAction: _connect,
      );

  Widget _searchField(int people) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
        child: SizedBox(
          height: Hit.min,
          child: CupertinoSearchTextField(
          key: const Key('contacts-search'),
          controller: _search,
          placeholder: 'Search $people ${people == 1 ? 'contact' : 'contacts'}',
          onChanged: (v) {
            _c.setQuery(v);
            setState(() {});
          },
          onSuffixTap: _clearSearch,
        )),
      );

  /// One banner at a time (failed, then syncing) and one card (table full, else the ask-first offer). Offline is the Chat
  /// tab's own banner above this segment.
  Widget _banner(BuildContext context, int total, bool connected) {
    final s = _m.state;
    final col = AppColors.of(context);
    Widget? banner;
    if (s.phase == SyncPhase.failed) {
      banner = ChatStatusBanner(
        key: const Key('banner-failed'),
        kind: StatusBannerKind.error,
        message: s.error ?? 'The contact list could not be read from the radio.',
        actionLabel: 'Try again',
        onAction: () => _m.syncNow(),
      );
    } else if (s.phase == SyncPhase.syncing) {
      banner = Column(key: const Key('banner-syncing'), children: [
        ChatStatusBanner(
          message: s.total > 0 ? 'Loading contacts from your radio: ${s.received} of ${s.total}' : 'Asking your radio for its contacts',
        ),
        if (s.total > 0)
          LinearProgressIndicator(value: (s.received / s.total).clamp(0, 1).toDouble(), minHeight: 2, color: col.accent, backgroundColor: col.outline.withValues(alpha: 0.3)),
      ]);
    }
    Widget? card;
    if (connected && s.tableFull) {
      card = _Card(
        key: const Key('banner-full'),
        symbol: AppSymbols.exclamationTriangle,
        text: 'Your radio\'s contact list is full${s.radioCount != null && s.capacity != null ? ' (${s.radioCount} of ${s.capacity})' : ''}. It cannot add new nodes until you free space.',
        actions: [_CardButton(const Key('banner-free'), 'Free up space', () => showRadioListSheet(context, _c))],
      );
    } else if (_m.shouldOfferAskFirst) {
      card = _Card(
        key: const Key('ask-first'),
        symbol: AppSymbols.personBadgePlus,
        text: 'Your radio adds every node it hears. That fills its contact list with strangers. Ask me before adding?',
        actions: [
          _CardButton(const Key('ask-keep'), 'Keep automatic', () => _m.answerPolicyPrompt('keep')),
          _CardButton(const Key('ask-yes'), 'Ask me first', () async {
            try {
              await _m.setPolicy(_m.state.policy!.copyWith(askBeforeAdding: true));
              _m.answerPolicyPrompt('ask');
            } catch (_) {
              if (context.mounted) showAppToast(context, 'The radio did not take that. Try again in a moment.', kind: AppToastKind.error);
            }
          }, bold: true),
        ],
      );
    }
    if (banner == null && card == null) return const SizedBox.shrink();
    return Column(children: [?banner, ?card]);
  }

  Widget _empty(BuildContext context, {required bool hasOthers}) {
    final col = AppColors.of(context);
    return Padding(
      key: const Key('contacts-empty'),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        AppSymbolIcon(AppSymbols.person2, size: 40, color: col.accent),
        const SizedBox(height: Gap.m),
        Text('No contacts yet', style: AppType.headline.copyWith(color: col.textPrimary), textAlign: TextAlign.center),
        const SizedBox(height: Gap.xs),
        Text(
          hasOthers
              ? 'People appear when their radio advertises. Repeaters and rooms are under Network.'
              : 'People appear when their radio advertises. You can also add one by QR code, link or key.',
          style: AppType.subhead.copyWith(color: col.textMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Gap.l),
        Wrap(alignment: WrapAlignment.center, spacing: Gap.m, runSpacing: Gap.s, children: [
          _FilledAction(key: const Key('contacts-send-advert'), label: 'Send an advert', onPressed: _advert),
          _FilledAction(key: const Key('contacts-scan-qr'), label: 'Scan a QR code', onPressed: _add, tinted: true),
        ]),
      ]),
    );
  }

  Widget _noMatch(BuildContext context, String q) {
    final col = AppColors.of(context);
    return Padding(
      key: const Key('contacts-no-match'),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text('No contact matches “$q”', style: AppType.headline.copyWith(color: col.textPrimary), textAlign: TextAlign.center),
        const SizedBox(height: Gap.s),
        _FilledAction(key: const Key('contacts-clear-search'), label: 'Clear search', onPressed: _clearSearch, tinted: true),
      ]),
    );
  }

  Widget _section(String title, Key key, List<ContactRow> rows, int now, {bool favouriteGroup = false}) {
    return SliverMainAxisGroup(slivers: [
      SliverPersistentHeader(pinned: true, delegate: _LetterHeader(title, key: key, extent: _headerExtent(context))),
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) => Column(children: [
          _tile(rows[i], now),
          if (i < rows.length - 1) const _Divider(),
        ]),
      ),
    ]);
  }

  double _headerExtent(BuildContext context) => MediaQuery.textScalerOf(context).scale(13) * 1.35 + 14;

  Widget _tile(ContactRow r, int now) {
    final c = r.contact;
    final col = AppColors.of(context);
    final canMessage = _c.openConversation != null;
    void open() => _profile(c);
    final tile = _ContactTile(key: Key('contact-${c.publicKey.substring(0, 8)}'), row: r, nowMs: now, onTap: open, actions: {
      if (canMessage) const CustomSemanticsAction(label: 'Message'): () => _message(c),
      CustomSemanticsAction(label: c.favourite ? 'Remove from favourites' : 'Add to favourites'): () => _favourite(c),
      const CustomSemanticsAction(label: 'Ping'): () => unawaited(_ping(c)),
      const CustomSemanticsAction(label: 'Remove'): () => unawaited(_remove(c)),
    });
    return Slidable(
      key: ValueKey('slide-${c.publicKey}'),
      startActionPane: ActionPane(motion: const DrawerMotion(), extentRatio: canMessage ? 0.5 : 0.28, children: [
        if (canMessage)
          _SwipeAction(key: Key('swipe-message-${c.publicKey.substring(0, 8)}'), color: col.accent, symbol: AppSymbols.message, label: 'Message', onTap: () => _message(c)),
        _SwipeAction(
          key: Key('swipe-favourite-${c.publicKey.substring(0, 8)}'),
          color: col.warning,
          symbol: c.favourite ? AppSymbols.star : AppSymbols.starFill,
          label: c.favourite ? 'Unfavourite' : 'Favourite',
          onTap: () => _favourite(c),
        ),
      ]),
      endActionPane: ActionPane(motion: const DrawerMotion(), extentRatio: 0.5, children: [
        _SwipeAction(key: Key('swipe-ping-${c.publicKey.substring(0, 8)}'), color: col.textMuted, symbol: AppSymbols.antenna, label: 'Ping', onTap: () => unawaited(_ping(c))),
        _SwipeAction(key: Key('swipe-remove-${c.publicKey.substring(0, 8)}'), color: col.danger, symbol: AppSymbols.trash, label: 'Remove', onTap: () => unawaited(_remove(c))),
      ]),
      child: tile,
    );
  }

  Widget _foot(BuildContext context) {
    final s = _m.state;
    final showUsage = _m.connected && s.radioCount != null && s.capacity != null;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _FootRow(key: const Key('contacts-manage'), symbol: AppSymbols.person2, label: 'Manage contacts', onTap: () => showContactsSettings(context, _c)),
        if (showUsage)
          _FootRow(
            key: const Key('contacts-usage'),
            label: '${s.radioCount} of ${s.capacity} on your radio · Manage',
            onTap: () => showRadioListSheet(context, _c),
          ),
      ]),
    );
  }

  Future<void> _showNearby(BuildContext context) => showAppSheet<void>(
        context,
        detents: const [0.5, 0.92],
        builder: (ctx, scroll) => AppSheetScaffold(
          controller: scroll,
          title: 'New nodes nearby',
          children: [NearbyList(controller: _c)],
        ),
      );
}

// ------------------------------------------------------------------ rows

class _ContactTile extends StatelessWidget {
  final ContactRow row;
  final int nowMs;
  final VoidCallback onTap;
  final Map<CustomSemanticsAction, VoidCallback> actions;
  const _ContactTile({super.key, required this.row, required this.nowMs, required this.onTap, required this.actions});

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    final c = row.contact;
    final route = routeCaption(c);
    final heard = heardShort(c, nowMs);
    final bars = heardBars(c, nowMs);
    final unread = row.unread;
    final label = '${c.displayName}, ${contactTypeLabel(c.type)}, $route, ${heard == null ? 'not heard yet' : 'heard $heard ago'}${unread > 0 ? ', $unread unread' : ''}';
    return Semantics(
      button: true,
      container: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      customSemanticsActions: actions,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          color: col.bg,
          constraints: const BoxConstraints(minHeight: _kRowMin),
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            ContactAvatar(c, size: kContactAvatar),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.headline.copyWith(color: col.textPrimary)),
                Text('${contactTypeLabel(c.type)} · $route', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.subhead.copyWith(color: col.textMuted)),
              ]),
            ),
            const SizedBox(width: Gap.s),
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              HeardBars(bars: bars),
              if (heard != null) Text(heard, maxLines: 1, style: AppType.footnote.copyWith(color: col.textMuted)),
              if (unread > 0)
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: col.accent, borderRadius: BorderRadius.circular(10)),
                  child: Text('$unread', style: AppType.footnote.copyWith(color: col.onAccent, fontWeight: FontWeight.w600)),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Three small bars: how fresh the last sign of life is (see [heardBars]). Never the only cue: the text beside it says how long.
class HeardBars extends StatelessWidget {
  final int bars;
  const HeardBars({super.key, required this.bars});

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    return ExcludeSemantics(
      child: SizedBox(
        key: ValueKey('heard-bars-$bars'),
        height: 14,
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 4,
              height: 5.0 + i * 4.5,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
              decoration: BoxDecoration(color: i < bars ? col.accent : col.textMuted.withValues(alpha: 0.28), borderRadius: BorderRadius.circular(1.5)),
            ),
        ]),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: _kDividerInset),
      child: SizedBox(height: 0.5, child: ColoredBox(color: col.outline.withValues(alpha: 0.35))),
    );
  }
}

class _LetterHeader extends SliverPersistentHeaderDelegate {
  final String title;
  final Key key;
  final double extent;
  _LetterHeader(this.title, {required this.key, required this.extent});

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final col = AppColors.of(context);
    return Semantics(
      header: true,
      child: Container(
        key: key,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
        color: col.bg,
        child: Text(title.toUpperCase(), style: AppType.footnote.copyWith(color: col.textMuted, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
      ),
    );
  }

  @override
  bool shouldRebuild(_LetterHeader old) => old.title != title || old.extent != extent;
}

class _SwipeAction extends StatelessWidget {
  final Color color;
  final AppSymbol symbol;
  final String label;
  final VoidCallback onTap;
  const _SwipeAction({super.key, required this.color, required this.symbol, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return CustomSlidableAction(
      onPressed: (_) => onTap(),
      backgroundColor: color,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        label: label,
        button: true,
        excludeSemantics: true,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AppSymbolIcon(symbol, size: 22, color: Colors.white),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, style: AppType.footnote.copyWith(color: Colors.white, fontWeight: FontWeight.w600), textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3)),
        ]),
      ),
    );
  }
}

/// The ONE collapsed row for new nodes; the details open in a sheet.
class _NearbyRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _NearbyRow({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.xs),
      child: Semantics(
        button: true,
        label: 'New nodes nearby, $count. See all',
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          key: const Key('nearby-row'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: Hit.min),
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
            decoration: BoxDecoration(color: col.surface, borderRadius: BorderRadius.circular(Corners.card)),
            child: Row(children: [
              AppSymbolIcon(AppSymbols.antenna, size: 20, color: col.accent),
              const SizedBox(width: Gap.s),
              Expanded(child: Text('New nodes nearby ($count)', key: const Key('nearby-title'), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.body.copyWith(color: col.textPrimary))),
              // At the largest text sizes the chevron alone says "see all" (the row's label still does).
              if (MediaQuery.textScalerOf(context).scale(17) <= 17 * 1.6) ...[
                const SizedBox(width: Gap.xs),
                Text('See all', key: const Key('nearby-more'), maxLines: 1, style: AppType.body.copyWith(color: col.accent)),
              ],
              const SizedBox(width: 2),
              AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: col.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The nodes the radio heard that are not contacts yet, each with Add and Ignore (inside the "New nodes nearby" sheet).
class NearbyList extends StatelessWidget {
  final ContactsController controller;
  const NearbyList({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final nearby = controller.nearby;
          if (nearby.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Text('Nothing new nearby right now.', key: const Key('nearby-none'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: AppColors.of(context).textMuted)),
            );
          }
          return Column(children: [
            for (final a in nearby) NearbyAdvertRow(key: Key('nearby-${a.publicKey.substring(0, 8)}'), advert: a, controller: controller),
          ]);
        },
      );
}

class NearbyAdvertRow extends StatelessWidget {
  final AdvertSeen advert;
  final ContactsController controller;
  const NearbyAdvertRow({super.key, required this.advert, required this.controller});

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    final a = advert;
    final type = a.type ?? ContactType.companion;
    final hops = (a.pathLen == null || a.pathLen == 0xFF) ? null : a.pathLen! & 63;
    final detail = '${heardText(a.lastTsMs, controller.nowMs()).replaceFirst('Heard ', 'heard ')}${hops == null ? '' : ', $hops ${hops == 1 ? 'hop' : 'hops'}'}';
    final add = CupertinoButton(
      key: Key('nearby-add-${a.publicKey.substring(0, 8)}'),
      minimumSize: const Size(Hit.min, Hit.min),
      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
      onPressed: () async {
        final r = await controller.manager.addNearby(a);
        if (!context.mounted) return;
        showAppToast(context, r.ok ? 'Added ${a.name}.${r.note == null ? '' : ' ${r.note}'}' : (r.error ?? 'That could not be added.'),
            kind: r.ok ? AppToastKind.success : AppToastKind.error);
      },
      child: const Text('Add'),
    );
    final ignore = CupertinoButton(
      key: Key('nearby-ignore-${a.publicKey.substring(0, 8)}'),
      minimumSize: const Size(Hit.min, Hit.min),
      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
      onPressed: () => controller.manager.ignoreNearby(a.publicKey),
      child: Text('Ignore', style: TextStyle(color: col.textMuted)),
    );
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.headline.copyWith(color: col.textPrimary)),
      Text('${contactTypeLabel(type)}, $detail', style: AppType.subhead.copyWith(color: col.textMuted)),
    ]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Semantics(
        container: true,
        label: 'New node ${a.name}, ${contactTypeLabel(type)}, $detail',
        child: LayoutBuilder(builder: (context, box) {
          // Buttons beside the name while there is room; under it at the largest text sizes and on narrow screens.
          final inline = box.maxWidth >= 340 && MediaQuery.textScalerOf(context).scale(14) <= 14 * 1.3;
          final avatar = ExcludeSemantics(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: col.surfaceHigh, shape: BoxShape.circle),
              child: Center(child: AppSymbolIcon(contactTypeSymbol(type), size: 20, color: col.textMuted)),
            ),
          );
          if (inline) {
            return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [avatar, const SizedBox(width: Gap.m), Expanded(child: text), add, ignore]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            avatar,
            const SizedBox(width: Gap.m),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, Wrap(spacing: Gap.s, children: [add, ignore])])),
          ]);
        }),
      ),
    );
  }
}

// ------------------------------------------------------------------ small parts

class _Card extends StatelessWidget {
  final AppSymbol symbol;
  final String text;
  final List<Widget> actions;
  const _Card({super.key, required this.symbol, required this.text, required this.actions});

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, 0),
      child: Container(
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: col.surface, borderRadius: BorderRadius.circular(Corners.card)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppSymbolIcon(symbol, size: 22, color: col.warning),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(text, style: AppType.subhead.copyWith(color: col.textPrimary))),
          ]),
          Align(alignment: Alignment.centerRight, child: Wrap(spacing: Gap.s, children: actions)),
        ]),
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool bold;
  const _CardButton(Key key, this.label, this.onPressed, {this.bold = false}) : super(key: key);

  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s),
        minimumSize: const Size(Hit.min, Hit.min),
        onPressed: onPressed,
        child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
      );
}

class _FilledAction extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool tinted;
  const _FilledAction({super.key, required this.label, required this.onPressed, this.tinted = false});

  @override
  Widget build(BuildContext context) => tinted
      ? CupertinoButton.tinted(minimumSize: const Size(Hit.min, Hit.min), onPressed: onPressed, child: Text(label))
      : CupertinoButton.filled(minimumSize: const Size(Hit.min, Hit.min), onPressed: onPressed, child: Text(label));
}

class _FootRow extends StatelessWidget {
  final AppSymbol? symbol;
  final String label;
  final VoidCallback onTap;
  const _FootRow({super.key, this.symbol, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: Hit.min),
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
          child: Row(children: [
            if (symbol != null) ...[AppSymbolIcon(symbol!, size: 20, color: col.accent), const SizedBox(width: Gap.m)],
            Expanded(child: Text(label, style: AppType.body.copyWith(color: symbol != null ? col.textPrimary : col.accent))),
            AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: col.textMuted),
          ]),
        ),
      ),
    );
  }
}
