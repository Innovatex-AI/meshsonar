import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/default_passwords.dart';
import 'package:meshsonar/radio/login_outcome.dart';
import 'package:meshsonar/radio/repeater_admin.dart';

void main() {
  test('factory passwords are detected case-sensitively', () {
    expect(detectFactoryPassword('password'), FactoryPassword.admin);
    expect(detectFactoryPassword('hello'), FactoryPassword.guest);
    expect(detectFactoryPassword('Password'), isNull);
    expect(detectFactoryPassword('hello1'), isNull);
    expect(detectFactoryPassword(''), isNull);
  });

  test('the warning copy names the risk and the fix', () {
    expect(factoryPasswordWarning, contains('Anyone nearby can log in'));
    expect(factoryPasswordWarning, contains('Change it'));
    expect(factoryPasswordHint, allOf(contains('"password"'), contains('"hello"')));
  });

  test('wrong password and no reply classify differently', () {
    expect(classifyLoginError(const AdminException(AdminErrorKind.wrongPassword, 'That password was not accepted.')).kind, LoginKind.wrongPassword);
    expect(classifyLoginError(const AdminException(AdminErrorKind.silent, 'No answer.'), waitedSecs: 24).kind, LoginKind.noReply);
    expect(classifyLoginError(const AdminException(AdminErrorKind.silent, 'No answer.'), waitedSecs: 24).waitedSecs, 24);
    expect(classifyLoginError(const ClaimRadioException(ClaimRadioError.radio, loginRefusedMessage)).kind, LoginKind.wrongPassword);
    expect(classifyLoginError(const ClaimRadioException(ClaimRadioError.silent, 'x')).kind, LoginKind.noReply);
    expect(classifyLoginError(const ClaimRadioException(ClaimRadioError.notConnected, 'x')).kind, LoginKind.notConnected);
    expect(classifyLoginError(const AdminException(AdminErrorKind.busy, 'busy')).kind, LoginKind.busy);
    expect(classifyLoginError(StateError('boom')).kind, LoginKind.other);
  });
}
