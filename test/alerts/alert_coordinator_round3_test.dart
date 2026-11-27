// Round 3 C-U1 / C-U2 and round 5 A1 / A2: notifications and in-app banners say a preview, never the raw text (a photo's
// address and a private photo's key never reach the lock screen; MeshTrack wire text reads as words), and a friend's
// position update never alerts.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/chat/models.dart';

import '../support/photo_fakes.dart' show privateUrlA, privateKeyA;
import 'alert_coordinator_test.dart' show Rig, chText, dm, settle;

void main() {
  group('alertPreviewText', () {
    test('a photo link reads "Photo", with the rest of the text as its caption', () {
      expect(alertPreviewText('https://meshsonar.com/p/AbCd1234'), 'Photo');
      expect(alertPreviewText('at the trailhead https://meshsonar.com/p/AbCd1234'), 'Photo: at the trailhead');
      expect(alertPreviewText('https://meshsonar.com/p/AbCd1234 https://meshsonar.com/p/XyZw9876'), '2 photos');
    });

    test('a private photo: neither its address nor its key', () {
      final t = alertPreviewText('look $privateUrlA');
      expect(t, 'Photo: look');
      expect(t.contains(privateKeyA), isFalse);
      expect(t.contains('meshsonar.com/e/'), isFalse);
    });

    test('MeshTrack wire text reads as words; plain text is itself', () {
      expect(alertPreviewText('MT1 @86GV429W+H34 s40 c46'), 'Shared their position');
      expect(alertPreviewText('see you at 8'), 'see you at 8');
      expect(alertPreviewText('docs at https://example.com/a'), 'docs at https://example.com/a', reason: 'other links stay');
    });

    test('isPositionUpdate: only a MeshTrack position', () {
      expect(isPositionUpdate('MT1 @86GV429W+H34 s40 c46'), isTrue);
      expect(isPositionUpdate('hello'), isFalse);
    });
  });

  group('the coordinator', () {
    test('C-U1 / A1: a photo DM notifies as "Photo: caption", never its address', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      await r.prefs.setShowText(true);
      r.h.service.handleInbound(dm(100, 'here $privateUrlA'));
      await settle();
      final b = r.n.shown.single.body;
      expect(b, 'Photo: here');
      expect(b.contains(privateKeyA), isFalse);
    });

    test('C-U2 / A2: a friend\'s position update in a channel that is not a group never notifies', () async {
      final r = Rig();
      await r.h.channel(1, 'Ohio', ChannelKind.private);
      await r.start();
      await r.prefs.setShowText(true);
      r.h.service.handleInbound(chText(1, 100, 'Jo N8JO: MT1 @86GV429W+H34 s40 c46'));
      r.h.service.handleInbound(chText(1, 101, 'Jo N8JO: MT1 @86GV429W+H35 s41 c46'));
      await settle();
      expect(r.n.shown, isEmpty);
      r.h.service.handleInbound(chText(1, 102, 'Jo N8JO: on my way'));
      await settle();
      expect(r.n.shown, hasLength(1), reason: 'an ordinary message still alerts');
    });

    test('A1 / A2 in the foreground: the in-app banner says the preview, and a position update raises none', () async {
      final r = Rig();
      r.h.bob();
      await r.h.channel(1, 'Ohio', ChannelKind.private);
      await r.start(foreground: true);
      await r.prefs.setShowText(true);
      final banners = <InAppBanner>[];
      final sub = r.c.banners.listen(banners.add);
      r.h.service.handleInbound(chText(1, 100, 'Jo N8JO: MT1 @86GV429W+H34 s40 c46'));
      r.h.service.handleInbound(dm(101, 'https://meshsonar.com/p/AbCd1234'));
      await settle();
      expect(banners.map((b) => b.body), ['Photo']);
      await sub.cancel();
    });
  });
}
