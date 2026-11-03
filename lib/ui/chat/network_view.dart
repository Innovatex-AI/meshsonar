// The Network segment (plan 4.12), shell version: your radio, then Repeaters, Rooms and Sensors from the contact book. Each
// section shows its five most relevant rows (favourites first, then the most recently heard) and a "Show all N" row. Heard
// nearby, the battery chip and the swipe Login/Ping actions arrive with WP11; nothing here is a dead button.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/conversation_row.dart';
import '../../chat/models.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../radio/radio_screen.dart';
import '../tools/adverts_screen.dart';
import 'chat_navigation.dart';
import 'conversation_tile.dart';

const int kNetworkSectionRows = 5;

class NetworkView extends StatefulWidget {
  final ChatController controller;
  final ChatNavigator navigator;
  final String query;
  final VoidCallback? onConnect;
  const NetworkView({super.key, required this.controller, required this.navigator, this.query = '', this.onConnect});

  @override
  State<NetworkView> createState() => _NetworkViewState();
}

class _NetworkViewState extends State<NetworkView> {
  final Set<ContactType> _expanded = {};

  ChatController get _c => widget.controller;

  List<Contact> _of(ContactType type, String q) {
    final id = _c.radioId;
    if (id == null) return const [];
    final list = _c.store.contacts.list(id, type: type, includeBlocked: false).where((x) => q.isEmpty || x.displayName.toLowerCase().contains(q)).toList()
      ..sort((a, b) {
        if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
        final ta = a.lastHeardMs ?? 0, tb = b.lastHeardMs ?? 0;
        if (ta != tb) return tb.compareTo(ta);
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final q = widget.query.trim().toLowerCase();
        final repeaters = _of(ContactType.repeater, q);
        final rooms = _of(ContactType.room, q);
        final sensors = _of(ContactType.sensor, q);
        final none = repeaters.isEmpty && rooms.isEmpty && sensors.isEmpty;
        return SliverMainAxisGroup(
          slivers: [
            if (q.isEmpty) SliverToBoxAdapter(child: _RadioCard(controller: _c, onConnect: widget.onConnect)),
            if (none)
              SliverToBoxAdapter(
                child: q.isNotEmpty
                    ? AppEmptyView(
                        key: const Key('network-no-results'),
                        symbol: AppSymbols.magnifyingglass,
                        title: 'No matches for “${widget.query.trim()}”',
                        message: 'Nothing on the network has that name.',
                      )
                    : Padding(
                        padding: const EdgeInsets.only(top: Gap.l),
                        child: AppEmptyView(
                          key: const Key('network-empty'),
                          symbol: AppSymbols.antenna,
                          title: 'No repeaters heard yet',
                          message: 'They appear after their next advert. You can send yours so nearby radios know about you.',
                          actionLabel: 'Send an advert',
                          onAction: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AdvertsScreen())),
                        ),
                      ),
              )
            else ...[
              ..._section('Repeaters', ContactType.repeater, repeaters),
              ..._section('Rooms', ContactType.room, rooms),
              ..._section('Sensors', ContactType.sensor, sensors),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
          ],
        );
      },
    );
  }

  List<Widget> _section(String title, ContactType type, List<Contact> items) {
    if (items.isEmpty) return const [];
    final open = _expanded.contains(type);
    final shown = open ? items : items.take(kNetworkSectionRows).toList();
    final more = items.length - shown.length;
    return [
      SliverToBoxAdapter(child: _Header(title)),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) => Column(children: [
          _NodeRow(
            key: Key('network-row-${shown[i].prefix}'),
            contact: shown[i],
            now: _c.now(),
            onTap: () => type == ContactType.room ? widget.navigator.openContact(context, shown[i]) : widget.navigator.openProfile(context, shown[i]),
          ),
          const RowDivider(),
        ]),
      ),
      if (more > 0 || open && items.length > kNetworkSectionRows)
        SliverToBoxAdapter(
          child: _ShowAll(
            key: Key('network-showall-${type.name}'),
            label: open ? 'Show fewer' : 'Show all ${items.length}',
            onTap: () => setState(() => open ? _expanded.remove(type) : _expanded.add(type)),
          ),
        ),
    ];
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.xs),
          child: Text(text.toUpperCase(), style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted, letterSpacing: 0.4)),
        ),
      );
}

String agoText(int? ms, DateTime now) {
  if (ms == null) return 'Not heard yet';
  final s = (now.millisecondsSinceEpoch - ms) ~/ 1000;
  if (s < 90) return 'Heard just now';
  if (s < 5400) return 'Heard ${(s / 60).round()} min ago';
  if (s < 129600) return 'Heard ${(s / 3600).round()} h ago';
  return 'Heard ${(s / 86400).round()} d ago';
}

class _NodeRow extends StatelessWidget {
  final Contact contact;
  final DateTime now;
  final VoidCallback onTap;
  const _NodeRow({super.key, required this.contact, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final kind = switch (contact.type) {
      ContactType.repeater => RowKind.repeater,
      ContactType.room => RowKind.room,
      ContactType.sensor => RowKind.sensor,
      ContactType.companion => RowKind.person,
    };
    final hops = contact.pathHops;
    final route = hops == null ? null : (hops == 0 ? 'Direct' : '$hops ${hops == 1 ? 'hop' : 'hops'}');
    final sub = [agoText(contact.lastHeardMs, now), ?route].join(' · ');
    final avatar = ConversationRow(
      key: contact.prefix,
      convKind: contact.type == ContactType.room ? ConvKind.room : ConvKind.dm,
      kind: kind,
      title: contact.displayName,
      avatarSeed: contact.publicKey,
    );
    return Semantics(
      button: true,
      container: true,
      label: '${contact.displayName}, ${contact.type.name}. $sub',
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
            child: Row(children: [
              ConversationAvatar(row: avatar, size: 44),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(contact.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline),
                  Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.subhead.copyWith(color: c.textMuted)),
                ]),
              ),
              AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ShowAll extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ShowAll({super.key, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          minimumSize: const Size(Hit.min, Hit.min),
          onPressed: onTap,
          child: Text(label),
        ),
      );
}

/// "Your radio": name, connection, and the way into the radio's own screen (or to connect).
class _RadioCard extends StatelessWidget {
  final ChatController controller;
  final VoidCallback? onConnect;
  const _RadioCard({required this.controller, this.onConnect});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final connected = controller.radioConnected;
    final name = controller.selfName;
    final title = connected ? (name == null || name.isEmpty ? 'Your radio' : name) : 'Radio not connected';
    final sub = connected ? 'Connected · settings and tools' : 'Tap to connect over Bluetooth';
    void tap() {
      if (connected) {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RadioScreen()));
      } else {
        onConnect?.call();
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.m, Layout.screenMargin, 0),
      child: Semantics(
        button: true,
        container: true,
        label: 'Your radio. $title. $sub',
        onTap: tap,
        child: ExcludeSemantics(
          child: GestureDetector(
            key: const Key('network-radio-card'),
            behavior: HitTestBehavior.opaque,
            onTap: tap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 68),
              padding: const EdgeInsets.all(Gap.m),
              decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
              child: Row(children: [
                AppSymbolIcon(AppSymbols.antenna, size: 28, color: connected ? c.accent : c.textMuted),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.headline),
                    Text(sub, maxLines: 2, style: AppType.subhead.copyWith(color: c.textMuted)),
                  ]),
                ),
                AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
