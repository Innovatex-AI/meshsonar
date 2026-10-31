// A room server as a conversation: log in with the room's password, read its posts, post a message. Minimal on purpose; when
// the chat tab's conversation screen is merged this screen can hand its posts to it (RoomController exposes plain posts).
// Posting needs read-and-write (the room password) or admin; a read-only guest sees why the composer is off.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../radio/claim_radio.dart';
import '../../../radio/room_session.dart';
import '../../theme.dart';
import '../repeater_admin/admin_common.dart';
import '../repeater_admin/admin_controller.dart' show AdminNotice;

class RoomController extends ChangeNotifier {
  final RoomSession room;
  final String title;

  /// Contact lookup: name for a key prefix (hex, any length).
  final String? Function(String prefixHex)? nameForPrefix;

  /// Opens the admin screen for this room (null when not available).
  final VoidCallback? onManage;
  RoomController({required this.room, required this.title, this.nameForPrefix, this.onManage}) {
    _sub = room.changes.listen((_) => notifyListeners());
  }

  StreamSubscription<void>? _sub;
  bool connecting = false;
  String? error;
  String? postError;
  bool posting = false;

  bool get loggedIn => room.loggedIn;

  Future<bool> login(String password) async {
    connecting = true;
    error = null;
    notifyListeners();
    try {
      await room.login(password);
      connecting = false;
      notifyListeners();
      return true;
    } on ClaimRadioException catch (e) {
      error = e.kind == ClaimRadioError.silent
          ? 'No answer. A wrong password and a room out of reach look the same from here.'
          : e.kind == ClaimRadioError.notConnected
              ? 'Your radio is not connected.'
              : e.message;
      connecting = false;
      notifyListeners();
      return false;
    }
  }

  Future<RoomPostOutcome> post(String text) async {
    posting = true;
    postError = null;
    notifyListeners();
    final o = await room.post(text);
    posting = false;
    postError = switch (o) {
      RoomPostOutcome.sent => null,
      RoomPostOutcome.notAllowed => 'You are logged in as a read-only guest. Posting needs the room password.',
      RoomPostOutcome.tooLong => 'That is too long for one packet (160 bytes).',
      RoomPostOutcome.notLoggedIn => 'Log in first.',
      RoomPostOutcome.radioBusy => 'Your radio is busy. Try again in a moment.',
      RoomPostOutcome.failed => 'The message could not be sent.',
    };
    notifyListeners();
    return o;
  }

  String authorName(String prefix8) => RoomSession.authorLabel(prefix8, nameForPrefix?.call(prefix8));

  Future<void> leave() async {
    await room.logout();
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    unawaited(room.logout().catchError((Object _) {}));
    room.dispose();
    super.dispose();
  }
}

class RoomScreen extends StatefulWidget {
  final RoomController controller;
  const RoomScreen({super.key, required this.controller});
  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _pw = TextEditingController();
  final _msg = TextEditingController();
  RoomController get c => widget.controller;

  @override
  void dispose() {
    _pw.clear();
    _pw.dispose();
    _msg.dispose();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        key: const Key('room-screen'),
        appBar: AppBar(
          title: Text(c.title, overflow: TextOverflow.ellipsis),
          actions: [
            if (c.loggedIn && c.room.isAdmin && c.onManage != null)
              IconButton(key: const Key('room-manage'), tooltip: 'Manage this room', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.settings_outlined), onPressed: c.onManage),
          ],
        ),
        body: SafeArea(child: c.loggedIn ? _conversation(context) : _login(context)),
      ),
    );
  }

  Widget _login(BuildContext context) {
    final t = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          key: const Key('room-login'),
          padding: const EdgeInsets.all(Gap.l),
          children: [
            Text('Join ${c.title}', style: t.textTheme.titleLarge),
            const SizedBox(height: Gap.s),
            Text('Enter the room\'s password to read and post, or its admin password to manage it. If the room allows guests you can read without posting.',
                style: t.textTheme.bodyLarge?.copyWith(height: 1.35)),
            const SizedBox(height: Gap.m),
            Container(
              padding: const EdgeInsets.all(Gap.m),
              decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(Corners.chip)),
              child: Text('The password goes from this phone to your own radio and over the air to the room. It is never sent to MeshSonar.', style: TextStyle(color: t.colorScheme.onSecondaryContainer, height: 1.3)),
            ),
            const SizedBox(height: Gap.l),
            TextField(
              key: const Key('room-password'),
              controller: _pw,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 15,
              inputFormatters: [LengthLimitingTextInputFormatter(15)],
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _go(),
              decoration: const InputDecoration(labelText: 'Room password'),
            ),
            if (c.error != null) NoticeBanner(AdminNotice(c.error!), bannerKey: const Key('room-login-error')),
            const SizedBox(height: Gap.m),
            FilledButton(
              key: const Key('room-login-go'),
              style: FilledButton.styleFrom(minimumSize: kTarget),
              onPressed: c.connecting || _pw.text.isEmpty ? null : _go,
              child: c.connecting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _go() async {
    final ok = await c.login(_pw.text);
    if (ok) _pw.clear();
  }

  Widget _conversation(BuildContext context) {
    final t = Theme.of(context);
    final posts = c.room.posts;
    if (c.room.unread > 0) WidgetsBinding.instance.addPostFrameCallback((_) => c.room.markRead());
    return Column(children: [
      Expanded(
        child: posts.isEmpty
            ? Center(child: Padding(padding: const EdgeInsets.all(Gap.xl), child: Text('No posts yet. The room sends what it has a moment after you join.', key: const Key('room-empty'), textAlign: TextAlign.center, style: t.textTheme.bodyLarge)))
            : ListView.builder(
                key: const Key('room-posts'),
                reverse: true,
                padding: const EdgeInsets.all(Gap.l),
                itemCount: posts.length,
                itemBuilder: (_, i) {
                  final p = posts[posts.length - 1 - i];
                  final mine = p.mine;
                  final who = mine ? 'You' : c.authorName(p.authorPrefixHex);
                  final when = DateTime.fromMillisecondsSinceEpoch(p.timestamp * 1000, isUtc: true).toLocal();
                  return Semantics(
                    container: true,
                    label: '$who, ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}: ${p.text}',
                    excludeSemantics: true,
                    child: Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        key: Key('post-${p.dedupeKey}'),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(Gap.m),
                        constraints: const BoxConstraints(maxWidth: 520),
                        decoration: BoxDecoration(color: mine ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.card)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('$who  ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}', style: t.textTheme.labelMedium?.copyWith(color: mine ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurfaceVariant)),
                          Text(p.text, style: t.textTheme.bodyLarge?.copyWith(color: mine ? t.colorScheme.onPrimaryContainer : null)),
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
      if (c.postError != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: NoticeBanner(AdminNotice(c.postError!), bannerKey: const Key('room-post-error'))),
      if (!c.room.canPost)
        Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Text('You are reading as a guest. Posting needs the room password.', key: const Key('room-readonly'), style: t.textTheme.bodyMedium),
        )
      else
        Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Row(children: [
            Expanded(
              child: TextField(
                key: const Key('room-compose'),
                controller: _msg,
                maxLength: 150,
                inputFormatters: [LengthLimitingTextInputFormatter(150)],
                decoration: const InputDecoration(hintText: 'Post to the room', counterText: ''),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: Gap.s),
            IconButton.filled(
              key: const Key('room-send'),
              tooltip: 'Post',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: c.posting ? null : _send,
              icon: c.posting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
            ),
          ]),
        ),
    ]);
  }

  Future<void> _send() async {
    final text = _msg.text.trim();
    if (text.isEmpty) return;
    final o = await c.post(text);
    if (o == RoomPostOutcome.sent) _msg.clear();
  }
}
