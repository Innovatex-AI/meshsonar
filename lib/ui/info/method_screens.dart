// "How it works" and "Method" as readable native pages: the website's /how-it-works and the generic /method (hub-pages.tsx
// HowPage and HubMethodPage), so nothing about how MeshSonar measures needs the browser. Text only, no data, works offline.
// A region's own analysis method (calibration, downloads) is data and lives in the Region tab's Analysis panels. The coverage
// text follows coverage v2 (Nov 8 2026): one fixed H3 res-11 cell, mean SNR of the answered pings, five bands, No reply,
// Predicted (lib/core/coverage_v2.dart, meshsonar-infra docs/planning/coverage-redesign-plan-2026-11-08.md).
import 'package:flutter/material.dart';

import '../theme.dart';

class _Section {
  final String title;
  final List<Object> parts; // String paragraph, List<String> bullets, List<(String, String)> numbered "bold. rest"
  const _Section(this.title, this.parts);
}

const howSteps = <(String, String)>[
  ('Your phone pings.', 'Paired with your MeshCore radio, MeshSonar sends a short ping on the #wardriving channel as you drive.'),
  (
    'Repeaters echo it.',
    'Any repeater that hears the ping repeats it. For about six seconds your radio listens for those echoes and notes which repeater it heard, and how strongly (SNR).',
  ),
  (
    'The app records who heard you.',
    'Each ping becomes a point: where you were and which repeaters answered, or that none did. "Heard nothing" is data too.',
  ),
  (
    'The region\'s map fills in.',
    'Uploaded pings are averaged into small hexagons, about 50 metres across, on the coverage map of the region they were sent from. '
        'Each hexagon is coloured by the average signal of its answered pings, from red (weak) through yellow to green (strong).',
  ),
];

const _howSections = <_Section>[
  _Section('A drive, step by step', [howSteps]),
  _Section('Regions', [
    'A region is a MeshMapper zone, with MeshMapper\'s name and border. Every ping is filed by where it was sent, not where you uploaded it, so a drive '
        'that crosses a border counts in both regions. Each region has its own site with its own map, drives and leaderboard; one sign-in works on all of them. '
        'Neighbouring regions can form a group that shows a combined map.',
    'In the app, the Analyze tab shows the region you are viewing; the switcher at the top changes it.',
  ]),
  _Section('Go deeper', [
    <String>[
      'Method (More > Method): how the figures are made and what they can and cannot say.',
      'Analyze > Region: repeaters, observers, packets, analysis, RF, growth, reports and stats for the region.',
      'More > Become an observer: make your own repeater report to MeshSonar.',
    ],
  ]),
];

const _methodSections = <_Section>[
  _Section('What is measured', [
    'A ping is a short message sent from a phone-paired radio at a known place and time. A ping is heard when at least one repeater echoes it back to the radio. '
        'Only repeaters that answered directly (one hop) count. The app also records the signal-to-noise ratio of each echo. A ping nobody answered is kept: it is how a dead zone shows.',
  ]),
  _Section('Cells', [
    'Public maps do not show pings. They show cells: hexagons about 50 metres across (H3 resolution 11), the same size at every zoom; zoomed out, each '
        'cell is drawn as a dot. Pings from the last 365 days count.',
    'A cell\'s colour is the average signal-to-noise ratio (SNR) of the pings in it that a repeater answered. It is shown in five bands, red through '
        'yellow to green: Edge, Weak, Fair, Good and Excellent, by the margin over the weakest signal LoRa can decode at the region\'s radio setting '
        '(-7.5 dB at SF7; each band is 5 dB wide). Pings nobody answered do not pull the average down: a cell where pings were sent and no repeater '
        'answered any of them is shown as No reply. A cell with answers but no signal reading is shown as heard, without a band. A cell with fewer '
        'than 3 pings is drawn faint.',
  ]),
  _Section('Predicted coverage', [
    'Predicted coverage fills the gaps between measured cells with an estimate made from the measured cells around them (within about a kilometre, at least '
        'two of them, nearer cells counting more). It is drawn hatched, under the measured cells, and fades with distance. It is a guess from real '
        'drives, never a measurement: drive there to replace it with one.',
  ]),
  _Section('What it cannot say', [
    <String>[
      'A cell with no pings is unmeasured, not dead. Coverage depends on the phone\'s antenna and radio, so one drive is one sample.',
      'GPS error and the radio\'s listening window mean a ping can land in a neighbouring cell.',
      'Pings are not weighted by time: inside the 365-day window a ping from last year counts the same as one from yesterday.',
    ],
  ]),
  _Section('Privacy rules applied before anything is public', [
    <String>[
      'The start and end of every drive are trimmed (500 metres unless the driver chooses another distance).',
      'Pings inside a driver\'s privacy zones are removed.',
      'Drive times are rounded down to the hour; no raw tracks are published.',
      'Drives under review, hidden by their owner or from a banned driver are left out.',
      'A callsign is shown only for drivers who opted in to the leaderboard and are not anonymous.',
    ],
  ]),
  _Section('Channels and pings', [
    'Pings go out on the #wardriving channel, an open channel that anyone can join. A ping\'s text is MS: and ten random characters, with no position in it. '
        'MeshSonar keeps its pings under 2% of the time in any 10 minutes, skips a ping rather than sending it late, and never delays a chat message for one.',
  ]),
  _Section('Claiming a radio', [
    'Claim means manage, never required to feed data. Repeaters, observers and drivers count whether or not anyone has claimed them. An owner who proves control of a '
        'radio (a signature from the radio, or a one-time code that an observer hears it advertise) can set the name shown for it and hide its position. We never ask for '
        'or see a radio\'s admin password, and a claim, or a moderator ending one, never changes what is collected or counted.',
  ]),
  _Section('Open data and code', [
    'The upload format and the public API are documented on the MeshSonar website, and the app and the site are open source.',
  ]),
];

class _InfoPage extends StatelessWidget {
  final String title, lead;
  final List<_Section> sections;
  final List<Widget> footer;
  final String keyPrefix;
  const _InfoPage({required this.title, required this.lead, required this.sections, required this.keyPrefix, this.footer = const []});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        top: false,
        child: ListView(
          key: Key('$keyPrefix-list'),
          padding: const EdgeInsets.all(Gap.l),
          children: [
            Text(lead, style: t.textTheme.bodyLarge?.copyWith(color: m.textMuted)),
            for (final s in sections)
              Padding(
                padding: const EdgeInsets.only(top: Gap.l),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(s.title, style: t.textTheme.titleMedium)),
                  const SizedBox(height: Gap.xs),
                  for (final p in s.parts) _part(context, p),
                ]),
              ),
            ...footer,
            const SizedBox(height: Gap.xl),
          ],
        ),
      ),
    );
  }

  Widget _part(BuildContext context, Object p) {
    final t = Theme.of(context);
    if (p is String) return Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text(p, style: t.textTheme.bodyMedium));
    if (p is List<String>) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final b in p)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: Text(b, style: t.textTheme.bodyMedium))]),
          ),
      ]);
    }
    if (p is List<(String, String)>) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (i, s) in p.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${s.$1} ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: s.$2),
                ]), style: t.textTheme.bodyMedium),
              ),
            ]),
          ),
      ]);
    }
    return const SizedBox.shrink();
  }
}

class HowItWorksScreen extends StatelessWidget {
  /// Replays the first-run tour of the tabs (null = no button).
  final VoidCallback? onReplayTour;
  const HowItWorksScreen({super.key, this.onReplayTour});

  @override
  Widget build(BuildContext context) => _InfoPage(
        title: 'How it works',
        keyPrefix: 'howitworks',
        lead: 'From a phone in a car to a coloured hexagon on the map, in four steps.',
        sections: _howSections,
        footer: [
          if (onReplayTour != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.l),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(key: const Key('howitworks-tour'), onPressed: onReplayTour, icon: const Icon(Icons.explore_outlined), label: const Text('Replay the tour of the tabs')),
              ),
            ),
        ],
      );
}

class MethodScreen extends StatelessWidget {
  const MethodScreen({super.key});

  @override
  Widget build(BuildContext context) => const _InfoPage(
        title: 'Method',
        keyPrefix: 'method',
        lead: 'How MeshSonar turns pings into a coverage map, and the limits of what it shows. The same method applies in every region.',
        sections: _methodSections,
      );
}
