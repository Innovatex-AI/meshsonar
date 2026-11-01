// More > Radios and tools > Repeaters and rooms: the repeaters and room servers your radio knows, plus the ones you have
// claimed, each one tap from its admin screen (or the room conversation). Nothing is sent from this list.
import 'package:flutter/material.dart';

import '../drive/drive_controls.dart' show openConnect;

import '../../radio/inbound.dart';
import '../../radio/protocol.dart' show AdvType;
import '../app.dart';
import '../state_widgets.dart';
import 'admin_launcher.dart';

class RepeatersScreen extends StatefulWidget {
  const RepeatersScreen({super.key});
  @override
  State<RepeatersScreen> createState() => _RepeatersScreenState();
}

class _RepeatersScreenState extends State<RepeatersScreen> {
  List<RadioContact>? _contacts;
  String? _error;
  bool _loading = false;
  final _q = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_contacts == null && !_loading && _error == null) _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = AppScope.of(context).radioSession;
    if (s == null || !s.isConnected) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await s.getContacts();
      if (!mounted) return;
      setState(() {
        _contacts = [for (final c in l.contacts) if (c.type == AdvType.repeater || c.type == AdvType.room) c]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Your radio did not give its contact list. Check that it is still connected and try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final why = adminUnavailableReason(context);
    final t = Theme.of(context);
    Widget body;
    if (why != null) {
      body = ErrorState(
        title: app.radioSession == null ? 'Radio not connected' : 'Not available on this connection',
        message: why,
        icon: Icons.bluetooth_disabled,
        onRetry: app.radioSession == null ? () => openConnect(context) : null,
        retryLabel: 'Connect radio',
      );
    } else if (_error != null) {
      body = ErrorState(title: 'Could not read your contacts', message: _error, onRetry: _load);
    } else if (_contacts == null) {
      body = const Center(child: CircularProgressIndicator(key: Key('repeaters-loading')));
    } else {
      final q = _q.text.trim().toLowerCase();
      final all = [for (final c in _contacts!) if (q.isEmpty || c.name.toLowerCase().contains(q) || c.publicKeyHex.startsWith(q)) c];
      final reps = [for (final c in all) if (c.type == AdvType.repeater) c];
      final rooms = [for (final c in all) if (c.type == AdvType.room) c];
      final have = {for (final c in _contacts!) c.publicKeyHex};
      final claimed = [for (final c in app.claims.active) if (!have.contains(c.pubkey) && (c.nodeType.name == 'repeater' || c.nodeType.name == 'room')) c];
      body = ListView(
        key: const Key('repeaters-list'),
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
        children: [
          Text('Pick a repeater to see how it is doing and change its settings. You need its admin password. It is free, and the password never leaves your phone and radio.',
              style: t.textTheme.bodyMedium?.copyWith(height: 1.35)),
          if (_contacts!.length > 8)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: TextField(key: const Key('repeaters-search'), controller: _q, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name')),
            ),
          if (reps.isNotEmpty) ...[
            const SectionLabelPad('Repeaters'),
            for (final c in reps) _tile(context, c.publicKeyHex, c.name, false, c.lastAdvert),
          ],
          if (rooms.isNotEmpty) ...[
            const SectionLabelPad('Room servers'),
            for (final c in rooms) _tile(context, c.publicKeyHex, c.name, true, c.lastAdvert),
          ],
          if (claimed.isNotEmpty) ...[
            const SectionLabelPad('Claimed by you, not on your radio yet'),
            for (final c in claimed) _tile(context, c.pubkey, c.displayName ?? c.nodeName ?? 'Repeater ${c.pubkey.substring(0, 6)}', c.nodeType.name == 'room', 0),
          ],
          if (reps.isEmpty && rooms.isEmpty && claimed.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: Text(
                  _contacts!.isEmpty
                      ? 'Your radio has no repeaters or rooms in its contacts yet. Open a repeater on the map and use "Administer this repeater", or wait until your radio hears one advertise.'
                      : 'Nothing matches that search.',
                  key: const Key('repeaters-empty'),
                  style: t.textTheme.bodyLarge?.copyWith(height: 1.35)),
            ),
        ],
      );
    }
    return Scaffold(
      key: const Key('repeaters-screen'),
      appBar: AppBar(title: const Text('Repeaters and rooms'), actions: [
        if (why == null) IconButton(key: const Key('repeaters-refresh'), tooltip: 'Read the contact list again', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
      ]),
      body: SafeArea(top: false, child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: body))),
    );
  }

  Widget _tile(BuildContext context, String key, String name, bool room, int lastAdvert) {
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final heard = lastAdvert <= 0 ? 'not heard since your radio started' : 'heard ${_ago(nowSecs - lastAdvert)}';
    return ListTile(
      key: Key('rep-$key'),
      minVerticalPadding: Gap.s,
      leading: Icon(room ? Icons.forum_outlined : Icons.cell_tower),
      title: Text(name.isEmpty ? 'Unnamed ${room ? 'room' : 'repeater'}' : name),
      subtitle: Text('${key.substring(0, 8)}...  -  $heard'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => room ? openRoom(context, keyHex: key, name: name) : openRepeaterAdmin(context, keyHex: key, name: name),
    );
  }

  static String _ago(int s) => s < 90 ? '${s < 0 ? 0 : s}s ago' : s < 5400 ? '${(s / 60).round()} min ago' : s < 172800 ? '${(s / 3600).round()} h ago' : '${(s / 86400).round()} days ago';
}

class SectionLabelPad extends StatelessWidget {
  final String text;
  const SectionLabelPad(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.xs),
      child: Semantics(header: true, child: Text(text, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary))),
    );
  }
}
