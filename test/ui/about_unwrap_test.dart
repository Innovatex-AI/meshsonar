import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/about_screen.dart';

void main() {
  test('licence paragraphs are joined, paragraph breaks kept, every word kept', () {
    final out = unwrapParagraphs(mitLicenseText);
    expect(out, contains('MIT License\n\nCopyright (c)'));
    expect(out, isNot(contains('a copy\nof this')));
    expect(out, contains('a copy of this software'));
    expect(out.split(RegExp(r'\s+')), mitLicenseText.split(RegExp(r'\s+')));
  });
}
