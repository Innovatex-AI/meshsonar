// Opens the repeater admin or room screens for a key, from Chat > Radio, the node actions (ui/nodes/node_actions.dart:
// "Administer" on every repeater and room surface) or a contact profile. Builds the session
// over the connected radio, the contact lookups, and the password vault. Says plainly why it cannot when there is no radio.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../chat/secret_store.dart' show SecretStore;
import '../../platform/secure_storage.dart' show KeychainSecretStore;
import '../../radio/admin_password_vault.dart';
import '../../radio/inbound.dart';
import '../../radio/protocol.dart' show AdvType;
import '../../radio/radio_session_impl.dart';
import '../../radio/repeater_admin.dart';
import '../../app/chat_wiring.dart' show ChatWiring;
import '../../platform/biometric_gate.dart';
import '../app.dart';
import '../chat/conversation_screen.dart' show ConversationScreen;
import '../../chat/models.dart' show ConvKey;
import '../design/app_surfaces.dart';
import 'repeater_admin/admin_controller.dart';
import 'repeater_admin/repeater_dashboard_screen.dart';
import 'rooms/room_join_bar.dart';

/// The one vault of the app run: passwords in memory, and in the Keychain only if the person opts in.
AdminPasswordVault? _vault;
AdminPasswordVault adminVault() {
  if (_vault != null) return _vault!;
  SecretStore? store;
  try {
    if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) store = KeychainSecretStore();
  } catch (_) {
    store = null;
  }
  return _vault = AdminPasswordVault(store: store, authenticate: authenticateWithDevice);
}

/// For tests: replace the vault.
void setAdminVaultForTest(AdminPasswordVault? v) => _vault = v;

class _Lookup {
  final List<RadioContact> contacts;
  const _Lookup(this.contacts);

  String? name(String prefixHex) {
    final p = prefixHex.toLowerCase();
    final hits = [for (final c in contacts) if (c.publicKeyHex.startsWith(p)) c];
    return hits.length == 1 ? hits.single.name : null;
  }

  String? fullKey(String prefixHex) {
    final p = prefixHex.toLowerCase();
    final hits = [for (final c in contacts) if (c.publicKeyHex.startsWith(p)) c];
    return hits.length == 1 ? hits.single.publicKeyHex : null;
  }
}

Future<_Lookup> _contacts(LinkRadioSession s) async {
  try {
    final l = await s.getContacts();
    return _Lookup(l.contacts);
  } catch (_) {
    return const _Lookup([]);
  }
}

/// Why admin cannot start, or null when it can.
String? adminUnavailableReason(BuildContext context) {
  final s = AppScope.maybeOf(context)?.radioSession;
  if (s == null || !s.isConnected) return 'Connect your radio first. Repeaters are administered through it.';
  if (!s.supportsRepeaterAdmin) return 'This radio connection cannot administer repeaters (the built-in Simulator has no repeaters).';
  return null;
}

Future<void> openRepeaterAdmin(BuildContext context, {required String keyHex, required String name, bool isRoom = false}) async {
  final app = AppScope.of(context);
  final why = adminUnavailableReason(context);
  if (why != null) {
    showAppToast(context, why, kind: AppToastKind.error);
    return;
  }
  final session = app.radioSession!;
  final lookup = await _contacts(session);
  final contact = [for (final c in lookup.contacts) if (c.publicKeyHex == keyHex.toLowerCase()) c].firstOrNull;
  if (!context.mounted) return;
  final controller = RepeaterAdminController(
    session: RepeaterAdminSession(radio: session, keyHex: keyHex, nodeType: isRoom ? AdvType.room : AdvType.repeater, contactName: name),
    title: name,
    isRoom: isRoom,
    regionPreset: app.viewingPreset,
    nameForPrefix: lookup.name,
    fullKeyForPrefix: lookup.fullKey,
    lastAdvertEpoch: contact?.lastAdvert,
    vault: adminVault()..radioId = radioIdOf(session.selfPublicKey),
    historyRepo: ChatWiring.controller.value?.store.statsHistory,
    gateByFirmware: true,
  );
  final key = keyHex.toLowerCase();
  final len = contact?.outPathLen;
  final hops = len == null || len < 0 || len == 0xFF ? null : len & 63;
  final route = hops == null ? null : (hops == 0 ? 'Direct' : 'Via $hops');
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RepeaterDashboardScreen(controller: controller, keyHex: key, routeLine: route)));
}

/// A room is a conversation: opens it with the join bar (log in to post) above it. The old stand-alone room screen is gone.
Future<void> openRoom(BuildContext context, {required String keyHex, required String name}) async {
  final chat = ChatWiring.controller.value;
  if (chat == null) {
    showAppToast(context, 'Chat is not ready yet. Try again in a moment.', kind: AppToastKind.error);
    return;
  }
  await ConversationScreen.open(
    context,
    controller: chat,
    convKey: ConvKey.room(keyHex.toLowerCase().substring(0, 12)),
    title: name,
    header: RoomJoinBar(keyHex: keyHex, name: name),
  );
}
