// Shown above a room server's conversation in the Chat tab. A room only pushes its posts to radios that have logged in, so a
// room you have not joined is silent. This header says so, takes the room password, and (for an admin login) offers
// "Manage this room". Posts themselves are the chat layer's job: they arrive through the radio session and are stored like
// any other message (txt_type 2, signed). The password goes only to your radio; it is kept for this app run (and in the
// secure store only if you chose "Remember passwords on this phone").
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../radio/claim_radio.dart';
import '../../../radio/protocol.dart' show AdvType;
import '../../app.dart';
import '../admin_launcher.dart';
import '../repeater_admin/admin_common.dart' show kTarget;

/// Which rooms this app run has joined, and how.
class RoomJoins {
  static final Map<String, RemoteLogin> _joined = {};
  static RemoteLogin? of(String keyHex) => _joined[keyHex.toLowerCase()];
  static void set(String keyHex, RemoteLogin l) => _joined[keyHex.toLowerCase()] = l;
  static void clear() => _joined.clear();
}

class RoomJoinHeader extends StatefulWidget {
  final String keyHex;
  final String name;
  const RoomJoinHeader({super.key, required this.keyHex, required this.name});

  @override
  State<RoomJoinHeader> createState() => _RoomJoinHeaderState();
}

class _RoomJoinHeaderState extends State<RoomJoinHeader> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _open = false;

  @override
  void dispose() {
    _pw.clear();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final app = AppScope.of(context);
    final s = app.radioSession;
    if (s == null || !s.isConnected) {
      setState(() => _error = 'Connect your radio first.');
      return;
    }
    final pw = _pw.text;
    if (pw.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await s.ensureContact(widget.keyHex, nodeType: AdvType.room, name: widget.name);
      final r = await s.login(widget.keyHex, pw);
      RoomJoins.set(widget.keyHex, r);
      await adminVault().keep(widget.keyHex, pw);
      _pw.clear();
      if (mounted) setState(() => _busy = false);
    } on ClaimRadioException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.kind == ClaimRadioError.silent
            ? 'No answer. A wrong password and a room out of reach look the same from here.'
            : e.kind == ClaimRadioError.notConnected
                ? 'Your radio is not connected.'
                : e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final joined = RoomJoins.of(widget.keyHex);
    final app = AppScope.maybeOf(context);
    if (app == null) return const SizedBox.shrink();
    if (joined != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
        child: Row(children: [
          Icon(Icons.check_circle_outline, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
              child: Text(joined.isAdmin ? 'Joined as admin' : (joined.canPost ? 'Joined' : 'Joined as a read-only guest: you can read but not post'),
                  key: const Key('room-joined'), style: t.textTheme.bodyMedium)),
          if (joined.isAdmin)
            TextButton(
              key: const Key('room-manage-chat'),
              style: TextButton.styleFrom(minimumSize: kTarget),
              onPressed: () => openRepeaterAdmin(context, keyHex: widget.keyHex, name: widget.name, isRoom: true),
              child: const Text('Manage'),
            ),
        ]),
      );
    }
    return Container(
      key: const Key('room-join'),
      margin: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('A room only sends its posts to radios that have joined it.', style: TextStyle(color: t.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
        if (!_open)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(key: const Key('room-join-open'), style: TextButton.styleFrom(minimumSize: kTarget), onPressed: () => setState(() => _open = true), child: const Text('Join with the room password')),
          )
        else ...[
          const SizedBox(height: Gap.xs),
          TextField(
            key: const Key('room-join-password'),
            controller: _pw,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 15,
            inputFormatters: [LengthLimitingTextInputFormatter(15)],
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _join(),
            decoration: const InputDecoration(labelText: 'Room password', helperText: 'Goes only to your radio, never to MeshSonar.', filled: true),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(_error!, key: const Key('room-join-error'), style: TextStyle(color: t.colorScheme.error))),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('room-join-go'),
              style: FilledButton.styleFrom(minimumSize: kTarget),
              onPressed: _busy || _pw.text.isEmpty ? null : _join,
              child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Join'),
            ),
          ),
        ],
      ]),
    );
  }
}
