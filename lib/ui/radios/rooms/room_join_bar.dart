// Replaces RoomJoinHeader when chatRedesign is on (chat plan 4.2 / 4.9). One thin bar above a room's conversation:
//   not joined -> [Log in to post]  opens the login sheet (the same sheet as a repeater's)
//   joined     -> "Joined" / "Joined as admin" / "Joined, read only" and, for an admin, [Manage]
// A room only pushes its posts to radios that logged in, so the bar says so in one line. Joining is the room login (the room then
// pushes the last unseen posts); the password goes to the radio only, and is never logged.
import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/material.dart';

import '../../../radio/claim_radio.dart';
import '../../../radio/login_outcome.dart';
import '../../../radio/protocol.dart' show AdvType;
import '../../app.dart';
import '../../design/app_symbols.dart';
import '../../design/tokens.dart';
import '../admin_launcher.dart';
import '../repeater_admin/login_sheet.dart';
import 'room_joins.dart';

class RoomJoinBar extends StatelessWidget {
  final String keyHex;
  final String name;

  /// Test seam: builds the model instead of using the connected radio.
  final LoginSheetModel Function(BuildContext context)? modelBuilder;
  const RoomJoinBar({super.key, required this.keyHex, required this.name, this.modelBuilder});

  LoginSheetModel _model(BuildContext context) {
    final s = AppScope.of(context).radioSession;
    final vault = adminVault()..radioId = radioIdOf(s?.selfPublicKey);
    return LoginSheetModel(
      title: name.isEmpty ? 'Room' : name,
      keyHex: keyHex,
      isRoom: true,
      vault: vault,
      attempt: (pw, {required guest, required route}) async {
        if (s == null || !s.isConnected) return const LoginOutcome(LoginKind.notConnected);
        try {
          final password = guest ? (await vault.recall(keyHex, guest: true) ?? 'hello') : pw;
          await s.ensureContact(keyHex, nodeType: AdvType.room, name: name);
          final RemoteLogin r = await s.login(keyHex, password);
          RoomJoins.set(keyHex, r);
          await vault.keep(keyHex, password, guest: !r.isAdmin);
          return LoginOutcome(r.isAdmin ? LoginKind.admin : LoginKind.guest);
        } catch (e) {
          return classifyLoginError(e);
        }
      },
      resetRoute: s == null ? null : () async => s.resetContactPath(keyHex).then((_) {}),
    );
  }

  Future<void> _login(BuildContext context) async {
    final model = (modelBuilder ?? _model)(context);
    await model.load();
    if (!context.mounted) return;
    await showLoginSheet(context, model: model);
    model.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppColors.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: RoomJoins.changes,
      builder: (context, _, _) {
        final joined = RoomJoins.of(keyHex);
        if (joined != null) {
          return Padding(
            key: const Key('room-bar-joined'),
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.s, 0),
            child: Row(children: [
              AppSymbolIcon(AppSymbols.checkmarkCircleFill, size: 18, color: c.ok),
              const SizedBox(width: Gap.s),
              Expanded(child: Text(RoomJoins.label(keyHex)!, key: const Key('room-joined'), style: t.textTheme.bodyMedium)),
              if (joined.isAdmin)
                CupertinoButton(
                  key: const Key('room-manage-chat'),
                  minimumSize: const Size(Hit.min, Hit.min),
                  onPressed: () => openRepeaterAdmin(context, keyHex: keyHex, name: name, isRoom: true),
                  child: const Text('Manage'),
                ),
            ]),
          );
        }
        return Container(
          key: const Key('room-bar-login'),
          margin: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
          padding: const EdgeInsets.symmetric(horizontal: Gap.m),
          decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(Corners.chip)),
          child: Row(children: [
            Expanded(child: Text('A room only sends its posts to radios that logged in.', style: TextStyle(color: t.colorScheme.onSecondaryContainer, fontSize: 13))),
            CupertinoButton(
              key: const Key('room-log-in'),
              minimumSize: const Size(Hit.min, Hit.min),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              onPressed: () => _login(context),
              child: const Text('Log in to post'),
            ),
          ]),
        );
      },
    );
  }
}

/// First 12 hex of the phone's own radio key (the vault's per-radio namespace), or 'unknown'.
String radioIdOf(String? selfPublicKey) => selfPublicKey == null || selfPublicKey.length < 12 ? 'unknown' : selfPublicKey.substring(0, 12).toLowerCase();
