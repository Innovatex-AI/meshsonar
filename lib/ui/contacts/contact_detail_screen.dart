// Contact detail. (Being built by the detail fork; this is the agreed constructor so the list can link to it.)
import 'package:flutter/material.dart';

import 'contacts_controller.dart';

class ContactDetailScreen extends StatelessWidget {
  final ContactsController controller;
  final String publicKey;
  const ContactDetailScreen({super.key, required this.controller, required this.publicKey});

  @override
  Widget build(BuildContext context) {
    final c = controller.contact(publicKey);
    return Scaffold(appBar: AppBar(title: Text(c?.displayName ?? 'Contact')), body: const SizedBox.shrink());
  }
}
