// What ContactManager needs from a radio, in chat's own terms (Contact, not the radio layer's frames). The one
// implementation is in session_adapter.dart; tests plug in a fake. The single radio-layer type that appears here is
// ContactPolicy, a plain value class.
import 'dart:typed_data';

import '../radio/inbound.dart' show ContactPolicy;
import 'models.dart';

export '../radio/inbound.dart' show ContactPolicy;

/// The radio refused a contact because its table is full (ERR_CODE_TABLE_FULL, MyMesh.cpp 1346).
class ContactTableFull implements Exception {
  const ContactTableFull();
  @override
  String toString() => 'the radio\'s contact list is full';
}

/// The radio does not answer commands now (link down, timeout). The caller keeps its work and tries again later.
class RadioUnavailable implements Exception {
  final String reason;
  const RadioUnavailable(this.reason);
  @override
  String toString() => 'radio unavailable: $reason';
}

/// A finished GET_CONTACTS.
class ContactDownload {
  /// Contacts the radio holds in total (CONTACTS_START), whatever `since` filtered.
  final int totalOnRadio;

  /// END_OF_CONTACTS: the cursor for the next incremental read; 0 when nothing was sent.
  final int cursor;
  const ContactDownload({required this.totalOnRadio, required this.cursor});
}

abstract interface class ContactRadioPort {
  /// The radio's own public key, 64 hex; null before the session knows it.
  String? get radioId;
  bool get isConnected;

  /// The radio's contact table size (DEVICE_INFO); null on a firmware that does not say.
  int? get capacity;

  /// GET_CONTACTS since [since]. [onContact] is called as each contact arrives, with the count so far and the total the radio
  /// announced; [onContact] must not throw. Throws [RadioUnavailable] when the link drops or stalls.
  Future<ContactDownload> download({required int since, required void Function(Contact contact, int received, int total) onContact});

  /// GET_CONTACT_BY_KEY: the radio's copy, or null when it does not have it.
  Future<Contact?> fetch(String publicKey);

  /// ADD_UPDATE_CONTACT with the phone's copy (including a favourite flag and the saved path). Throws [ContactTableFull].
  Future<void> upload(Contact contact);

  /// REMOVE_CONTACT; false when the radio did not have it.
  Future<bool> remove(String publicKey);

  /// RESET_PATH; false when the radio did not have it.
  Future<bool> resetPath(String publicKey);

  Future<void> importAdvert(Uint8List packet);
  Future<bool> shareZeroHop(String publicKey);

  Future<ContactPolicy> getPolicy();
  Future<void> setPolicy(ContactPolicy policy);
}
