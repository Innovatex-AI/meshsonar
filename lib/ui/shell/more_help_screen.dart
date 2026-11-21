// More > Help (build 71): the help rows that used to sit one by one on the More list. How it works (with the tour),
// Method, Colour legend, Report a problem, My reports, Privacy policy. Row keys keep their old `more-*` names.
import 'package:flutter/material.dart';

import '../../core/server_url.dart' show privacyPolicyUrl;
import '../app.dart';
import '../report_problem_screen.dart' show openReportProblem;
import 'more_tab.dart' show MoreRow;

class MoreHelpScreen extends StatelessWidget {
  /// Opens a More page over this one (the More tab's Navigator).
  final void Function(MoreItem) onOpen;
  const MoreHelpScreen({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('more-help-list'),
          children: [
            MoreRow(MoreItem.howItWorks, Icons.explore_outlined, 'How it works', 'From a ping to a coloured hexagon on the map, and a tour of the tabs', onOpen: onOpen),
            MoreRow(MoreItem.method, Icons.menu_book_outlined, 'Method', 'How the figures are made, and what they cannot say', onOpen: onOpen),
            MoreRow(MoreItem.legend, Icons.palette_outlined, 'Colour legend', 'What the map colours mean', onOpen: onOpen),
            ListTile(
              key: const Key('more-report'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report a problem'),
              subtitle: const Text('Send the team what went wrong'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openReportProblem(context),
            ),
            MoreRow(MoreItem.myReports, Icons.report_gmailerrorred_outlined, 'My reports', 'Problem reports you sent and where they stand', onOpen: onOpen),
            ListTile(
              key: const Key('more-privacy-policy'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.policy_outlined),
              title: const Text('Privacy policy'),
              subtitle: const Text('Opens in your browser'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => s.services.openUrl(Uri.parse(privacyPolicyUrl)),
            ),
            const SizedBox(height: Gap.xl),
          ],
        ),
      ),
    );
  }
}
