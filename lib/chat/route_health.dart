// REMOVED in build 77 (decision D3): the "This route may be broken" card and its logic are not in the official MeshCore
// flow. The fallback (reset path, then flood tries) now does that job on every message. This file is only a shim so the
// conversation screen written against build 76 compiles: [routeLooksBroken] is always false, so the card never shows.
// Delete this file together with lib/ui/chat/route_broken_card.dart and its use in conversation_screen.dart.
import 'models.dart';
import 'store.dart';

const int brokenAfter = 3;

/// Always false since build 77.
bool routeLooksBroken(ChatStore store, Contact contact) => false;
