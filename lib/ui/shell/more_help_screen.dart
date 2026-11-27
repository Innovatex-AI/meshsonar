// More > Help (build 71): the help rows that used to sit one by one on the More list. How it works, Show the intro again,
// Method, Map legend, Report a problem, My reports, Privacy policy, Terms of service. Row keys keep their old `more-*`
// names. Build 77 (round 5 S7, S12): one name per thing ("Map legend" as in Settings, "Show the intro again" as in How it
// works; the Settings tour row is gone) and the terms beside the privacy policy.
import 'package:flutter/material.dart';

import '../../core/server_url.dart' show privacyPolicyUrl;
import '../app.dart';
import '../onboarding/onboarding_screen.dart';
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
            MoreRow(MoreItem.howItWorks, Icons.explore_outlined, 'How it works', 'What a ping is, and a tour of the tabs', onOpen: onOpen),
            // Build 76: the intro again in one tap (it was two levels down, inside How it works).
            ListTile(
              key: const Key('more-tour'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.slideshow_outlined),
              title: const Text('Show the intro again'),
              subtitle: const Text('Four short pages'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (c2) => OnboardingScreen(replay: true, onFinish: (_) => Navigator.of(c2).pop()),
              )),
            ),
            MoreRow(MoreItem.method, Icons.menu_book_outlined, 'Method', 'How the numbers are worked out', onOpen: onOpen),
            MoreRow(MoreItem.legend, Icons.palette_outlined, 'Map legend', 'What the colours and symbols mean', onOpen: onOpen),
            const Divider(height: Gap.l, indent: Gap.l, endIndent: Gap.l),
            ListTile(
              key: const Key('more-report'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report a problem'),
              subtitle: const Text('Tell us what went wrong'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openReportProblem(context),
            ),
            MoreRow(MoreItem.myReports, Icons.report_gmailerrorred_outlined, 'My reports', 'What you sent, and its status', onOpen: onOpen),
            const Divider(height: Gap.l, indent: Gap.l, endIndent: Gap.l),
            ListTile(
              key: const Key('more-privacy-policy'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.policy_outlined),
              title: const Text('Privacy policy'),
              subtitle: const Text('Opens in your browser'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => s.services.openUrl(Uri.parse(privacyPolicyUrl)),
            ),
            ListTile(
              key: const Key('more-terms'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.description_outlined),
              title: const Text('Terms of service'),
              subtitle: const Text('Opens in your browser'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => s.openWebPage('/terms'),
            ),
            const SizedBox(height: Gap.xl),
          ],
        ),
      ),
    );
  }
}
