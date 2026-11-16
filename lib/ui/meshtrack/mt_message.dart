// "Message" on a friend's row (plan section 1.4): the direct conversation when a contact with exactly that name exists,
// else the group's own channel conversation with `@[name] ` already typed (MeshCore's mention format).
import 'package:flutter/widgets.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
import '../chat/conversation_screen.dart';
import '../design/app_surfaces.dart';

/// Where Message goes for [name] in the group on channel [channelId].
sealed class MtMessageTarget {
  const MtMessageTarget();
}

final class MtMessageDirect extends MtMessageTarget {
  final Contact contact;
  const MtMessageDirect(this.contact);
}

final class MtMessageChannel extends MtMessageTarget {
  final int channelId;
  final String prefill;
  const MtMessageChannel(this.channelId, this.prefill);
}

/// The mention text a channel reply starts with.
String mtMention(String name) => '@[$name] ';

/// Picks the target: a companion contact on this radio whose shown name is exactly [name], else the group channel.
MtMessageTarget mtMessageTarget(ChatController chat, int channelId, String name) {
  final radio = chat.radioId;
  if (radio != null) {
    for (final c in chat.store.contacts.list(radio, type: ContactType.companion)) {
      if (c.displayName == name) return MtMessageDirect(c);
    }
  }
  return MtMessageChannel(channelId, mtMention(name));
}

/// Opens the conversation for Message. A channel draft that already holds text keeps it, with the mention put in front.
Future<void> openMtMessage(BuildContext context, ChatController? chat, int channelId, String name) async {
  if (chat == null) {
    showAppToast(context, 'Connect your radio once first, then you can message them.');
    return;
  }
  switch (mtMessageTarget(chat, channelId, name)) {
    case MtMessageDirect(:final contact):
      await ConversationScreen.open(context, controller: chat, convKey: ConvKey.dm(contact.prefix), title: contact.displayName);
    case MtMessageChannel(:final channelId, :final prefill):
      final key = ConvKey.channel(channelId);
      final draft = chat.service.loadDraft(key) ?? '';
      if (!draft.startsWith(prefill)) chat.service.saveDraft(key, '$prefill$draft');
      await ConversationScreen.open(context, controller: chat, convKey: key);
  }
}
