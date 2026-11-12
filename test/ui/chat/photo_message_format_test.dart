// Photo links in message text (contract v1 regex): what becomes a photo part and what stays an ordinary link.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/ui/chat/message_format.dart';

const photoUrlX = 'https://meshsonar.com/p/Zz00Aa11';

List<(PartKind, String)> parts(String s) => [for (final p in splitMessage(s)) (p.kind, p.text)];

const privId = 'k3Xq9TzA';
const privKey = 'AAECAwQFBgcICQoLDA0ODw';
const privUrl = 'https://meshsonar.com/e/$privId#$privKey';

void main() {
  group('splitMessage private photo parts', () {
    test('a bare private link is one photoPrivate part carrying the whole link', () {
      expect(parts(privUrl), [(PartKind.photoPrivate, privUrl)]);
    });

    test('text around it; trailing punctuation is not part of the link', () {
      expect(parts('for you $privUrl please'), [(PartKind.text, 'for you '), (PartKind.photoPrivate, privUrl), (PartKind.text, ' please')]);
      for (final tail in ['.', ',', '!', '?', ')', ':', ';']) {
        expect(parts('see $privUrl$tail'), [(PartKind.text, 'see '), (PartKind.photoPrivate, privUrl), (PartKind.text, tail)], reason: tail);
      }
    });

    test('a plain and a private link in one message keep their own kinds', () {
      expect(parts('$photoUrlX $privUrl').map((e) => e.$1).toList(), [PartKind.photo, PartKind.text, PartKind.photoPrivate]);
    });

    test('a link without a valid 22-character key stays an ordinary url', () {
      for (final u in [
        'https://meshsonar.com/e/$privId', // no key at all
        'https://meshsonar.com/e/$privId#',
        'https://meshsonar.com/e/$privId#AAECAwQFBgcICQoLDA0OD', // 21
        'https://meshsonar.com/e/$privId#${privKey}A', // 23
        'https://meshsonar.com/e/$privId#AAECAwQFBgcICQoLDA0O+w', // not url-safe
        'https://meshsonar.com/e/k3Xq9Tz#$privKey', // 7-character id
        'https://meshsonar.com/e/k3Xq9TzAB#$privKey', // 9
        'https://meshsonar.com/e/$privId/full#$privKey',
        'https://meshsonar.com/e/$privId#$privKey/x',
      ]) {
        expect(parts(u), [(PartKind.url, u)], reason: u);
      }
    });

    test('a private link is not a plain photo and a plain link is not private', () {
      expect(photoIdOf(privUrl), isNull);
      expect(anyPhotoIdOf(privUrl), privId);
      expect(anyPhotoIdOf('https://meshsonar.com/p/k3Xq9TzA'), 'k3Xq9TzA');
      expect(anyPhotoIdOf('https://example.com/'), isNull);
    });

    test('photoLinksOf, textWithoutPhotos and photoPreview treat it as a photo', () {
      expect(photoLinksOf('hi $privUrl'), [privUrl]);
      expect(textWithoutPhotos('hi $privUrl'), 'hi');
      expect(photoPreview(privUrl), 'Photo');
      expect(photoPreview('hi $privUrl'), 'Photo: hi');
      expect(photoPreview('$privUrl $photoUrlX'), '2 photos');
      expect(photoPreview('hi $privUrl'), isNot(contains(privKey)));
    });
  });

  group('splitMessage photo parts', () {
    test('a bare photo link is one photo part', () {
      expect(parts('https://meshsonar.com/p/k3Xq9TzA'), [(PartKind.photo, 'https://meshsonar.com/p/k3Xq9TzA')]);
    });

    test('text before and after a photo link', () {
      expect(parts('look at this https://meshsonar.com/p/k3Xq9TzA nice view'), [
        (PartKind.text, 'look at this '),
        (PartKind.photo, 'https://meshsonar.com/p/k3Xq9TzA'),
        (PartKind.text, ' nice view'),
      ]);
    });

    test('trailing punctuation is not part of the photo link', () {
      for (final tail in ['.', ',', '!', '?', ')', '...', ':', ';']) {
        expect(parts('see https://meshsonar.com/p/k3Xq9TzA$tail'), [
          (PartKind.text, 'see '),
          (PartKind.photo, 'https://meshsonar.com/p/k3Xq9TzA'),
          (PartKind.text, tail),
        ], reason: tail);
      }
    });

    test('a photo link right before a newline', () {
      expect(parts('https://meshsonar.com/p/k3Xq9TzA\nhi').first, (PartKind.photo, 'https://meshsonar.com/p/k3Xq9TzA'));
    });

    test('other meshsonar.com links stay plain links', () {
      for (final u in [
        'https://meshsonar.com/',
        'https://meshsonar.com/map',
        'https://meshsonar.com/p/k3Xq9TzA/full', // the image itself, not the message link
        'https://meshsonar.com/p/k3Xq9TzA/thumb',
        'https://meshsonar.com/p/k3Xq9Tz', // 7 characters
        'https://meshsonar.com/p/k3Xq9TzAB', // 9 characters
        'https://meshsonar.com/p/k3Xq-TzA', // not base62
        'http://meshsonar.com/p/k3Xq9TzA', // not https
        'https://cmh.meshsonar.com/p/k3Xq9TzA', // a region host
        'https://meshsonar.com.evil.example/p/k3Xq9TzA',
        'https://meshsonar.com/p/k3Xq9TzA?x=1',
      ]) {
        expect(parts(u).first.$1, PartKind.url, reason: u);
      }
    });

    test('other urls and meshcore links are unchanged', () {
      expect(parts('https://example.com/p/k3Xq9TzA').single.$1, PartKind.url);
      expect(parts('meshcore://channel/add?name=x').single.$1, PartKind.meshLink);
      expect(parts('@[Bob] https://meshsonar.com/p/k3Xq9TzA').map((e) => e.$1), [PartKind.mention, PartKind.text, PartKind.photo]);
    });

    test('two photos in one message', () {
      expect(photoLinksOf('a https://meshsonar.com/p/k3Xq9TzA b https://meshsonar.com/p/Zz00Aa11'),
          ['https://meshsonar.com/p/k3Xq9TzA', 'https://meshsonar.com/p/Zz00Aa11']);
    });
  });

  group('helpers', () {
    test('photoIdOf takes only exact links', () {
      expect(photoIdOf('https://meshsonar.com/p/k3Xq9TzA'), 'k3Xq9TzA');
      expect(photoIdOf('https://meshsonar.com/p/k3Xq9TzA/full'), isNull);
      expect(photoIdOf(' https://meshsonar.com/p/k3Xq9TzA'), isNull);
    });

    test('textWithoutPhotos keeps the words and drops the link', () {
      expect(textWithoutPhotos('summit https://meshsonar.com/p/k3Xq9TzA'), 'summit');
      expect(textWithoutPhotos('a https://meshsonar.com/p/k3Xq9TzA b'), 'a b');
      expect(textWithoutPhotos('https://meshsonar.com/p/k3Xq9TzA'), '');
      expect(textWithoutPhotos('see https://meshsonar.com/p/k3Xq9TzA.'), 'see .');
    });

    test('list preview says Photo', () {
      expect(photoPreview('https://meshsonar.com/p/k3Xq9TzA'), 'Photo');
      expect(photoPreview('summit view https://meshsonar.com/p/k3Xq9TzA'), 'Photo: summit view');
      expect(photoPreview('no photo https://example.com'), 'no photo https://example.com');
    });

    test('the link is 32 bytes, as the plan budgets', () {
      expect(utf8Len('https://meshsonar.com/p/k3Xq9TzA'), 32);
    });
  });
}
