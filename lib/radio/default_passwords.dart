// Factory passwords of MeshCore repeaters and rooms. A repeater ships with admin password "password" and a room/guest login
// of "hello"; anyone in radio range who knows that can log in. The login sheet warns when the password typed (or that just
// worked) is one of these. Pure Dart; the passwords are public firmware defaults, not secrets.

/// What the typed password is a factory default of.
enum FactoryPassword { admin, guest }

const String factoryAdminPassword = 'password';
const String factoryGuestPassword = 'hello';

/// The hint under the empty field: what an unchanged repeater accepts.
const String factoryPasswordHint = 'A new repeater uses "password" for admin and "hello" for guests.';

/// Warning copy for a factory password (one sentence for the cause, one for the fix).
const String factoryPasswordWarning = 'Factory password. Anyone nearby can log in. Change it after you sign in.';

/// Null when [password] is not a factory default. Case-sensitive, as the firmware compares it.
FactoryPassword? detectFactoryPassword(String password) => switch (password) {
      factoryAdminPassword => FactoryPassword.admin,
      factoryGuestPassword => FactoryPassword.guest,
      _ => null,
    };
