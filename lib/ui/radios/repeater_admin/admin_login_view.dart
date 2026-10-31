// Log in to a repeater or room: explains where the password goes (nowhere but your radio), remembers nothing by default.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';

/// The promise, in one place so the screen and its tests agree.
const String adminPasswordPromise =
    'Your password goes from this phone to your own radio and over the air to the repeater. It is never sent to MeshSonar or anyone else, '
    'and this app forgets it when you close it.';

class AdminLoginView extends StatefulWidget {
  final RepeaterAdminController controller;
  final String what; // "repeater" | "room"
  const AdminLoginView({super.key, required this.controller, this.what = 'repeater'});

  @override
  State<AdminLoginView> createState() => _AdminLoginViewState();
}

class _AdminLoginViewState extends State<AdminLoginView> {
  final _pw = TextEditingController();
  bool _show = false;

  RepeaterAdminController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.checkVault().then((_) async {
      final saved = await c.savedPassword();
      if (saved != null && mounted && _pw.text.isEmpty) setState(() => _pw.text = saved);
    });
  }

  @override
  void dispose() {
    _pw.clear();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final pw = _pw.text;
    if (pw.isEmpty) return;
    final ok = await c.login(pw);
    if (ok) _pw.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = c.stage == AdminStage.connecting;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            key: const Key('admin-login'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Row(children: [
                Icon(Icons.lock_outline, color: t.colorScheme.primary),
                const SizedBox(width: Gap.s),
                Expanded(child: Semantics(header: true, child: Text('Log in to ${c.title}', style: t.textTheme.titleLarge))),
              ]),
              const SizedBox(height: Gap.m),
              Text(
                widget.what == 'room'
                    ? 'Use the room\'s password to read and post, or its admin password to manage it.'
                    : 'Use this repeater\'s admin password to manage it. A guest password lets you read its status.',
                style: t.textTheme.bodyLarge?.copyWith(height: 1.35),
              ),
              const SizedBox(height: Gap.m),
              Container(
                key: const Key('admin-promise'),
                padding: const EdgeInsets.all(Gap.m),
                decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(Corners.chip)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.shield_outlined, color: t.colorScheme.onSecondaryContainer),
                  const SizedBox(width: Gap.s),
                  Expanded(child: Text(adminPasswordPromise, style: TextStyle(color: t.colorScheme.onSecondaryContainer, height: 1.3))),
                ]),
              ),
              const SizedBox(height: Gap.l),
              TextField(
                key: const Key('admin-password'),
                controller: _pw,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !busy,
                maxLength: 15,
                inputFormatters: [LengthLimitingTextInputFormatter(15)],
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _go(),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: widget.what == 'room' ? 'Room or admin password' : 'Admin password',
                  helperText: 'Up to 15 characters: a radio cuts longer passwords.',
                  suffixIcon: IconButton(
                    key: const Key('admin-password-show'),
                    tooltip: _show ? 'Hide password' : 'Show password',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              if (c.rememberOffered)
                SwitchListTile(
                  key: const Key('admin-remember'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Remember passwords on this phone'),
                  subtitle: const Text('Off by default. When on, passwords are kept in this phone\'s secure storage, only on this phone. Turning it off deletes them.'),
                  value: c.rememberOn,
                  onChanged: busy ? null : (v) => c.setRemember(v),
                ),
              if (c.loginError != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: NoticeBanner(AdminNotice(c.loginError!, error: true), bannerKey: const Key('admin-login-error')),
                ),
              const SizedBox(height: Gap.l),
              FilledButton(
                key: const Key('admin-login-go'),
                style: FilledButton.styleFrom(minimumSize: kTarget),
                onPressed: busy || _pw.text.isEmpty ? null : _go,
                child: busy
                    ? Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: const [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: Gap.s),
                        Flexible(child: Text('Waiting for the repeater', textAlign: TextAlign.center)),
                      ])
                    : const Text('Log in'),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: Text('A wrong password and a repeater out of reach both get no answer. This can take up to 15 seconds.',
                      key: const Key('admin-login-wait'), style: t.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
