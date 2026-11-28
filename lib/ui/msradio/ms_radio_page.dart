// Build 78 (builder A): the MeshSonar radio entry on More > Radio and the MeshSonar radio page.
//
// [MsRadioEntryRow] is on More > Radio for a MeshSonar radio only (a stock MeshCore radio gets nothing: no row, no
// controller, no request to any local address). Its chip may run one quiet connect() when More > Radio opens.
// [MsRadioPage]: header (radio name, MeshSonar version, chip), then the sections in MsSection order. A section whose screen
// is not built (msSectionScreen returns null) has no row. Before pairing every section but Pairing says "Pair first"; when
// the radio cannot be reached the page says "Not on Wi-Fi" with Retry.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../design/tokens.dart';
import '../radio/inset_list.dart';
import 'ms_common.dart';
import 'ms_radio_host.dart';
import 'ms_sections.dart';
import 'ms_sections_b.dart' show msBOwnerAvailable;

/// The plain title of each section on the page.
String msSectionTitle(MsSection s) => switch (s) {
      MsSection.pairing => 'Pairing',
      MsSection.overview => 'Overview',
      MsSection.sharing => 'Sharing and wardrive',
      MsSection.log => 'Log and backlog',
      MsSection.mapPack => 'Map pack',
      MsSection.firmware => 'Firmware',
      MsSection.luaApps => 'Lua apps',
      MsSection.screenSounds => 'Radio screen and sounds',
      MsSection.owner => 'Owner link',
      MsSection.rfTools => 'RF tools',
      MsSection.pairedApps => 'Apps paired with this radio',
    };

String _sectionSubtitle(MsSection s) => switch (s) {
      MsSection.pairing => 'Let this app control the radio over Wi-Fi',
      MsSection.overview => 'Battery, clock, Wi-Fi, uplink',
      MsSection.sharing => 'Logging, sharing with MeshSonar, GPS points',
      MsSection.log => 'What the radio logged and has still to send',
      MsSection.mapPack => 'Offline map on the radio',
      MsSection.firmware => 'Updates over Wi-Fi',
      MsSection.luaApps => 'Apps that run on the radio',
      MsSection.screenSounds => 'Name, brightness, sounds, lock',
      MsSection.owner => 'Link the radio to your MeshSonar account',
      MsSection.rfTools => 'Spectrum scan and signal probe',
      MsSection.pairedApps => 'See and remove paired apps',
    };

IconData _sectionIcon(MsSection s) => switch (s) {
      MsSection.pairing => Icons.link_rounded,
      MsSection.overview => Icons.dashboard_outlined,
      MsSection.sharing => Icons.cloud_upload_outlined,
      MsSection.log => Icons.receipt_long_outlined,
      MsSection.mapPack => Icons.map_outlined,
      MsSection.firmware => Icons.system_update_outlined,
      MsSection.luaApps => Icons.apps_outlined,
      MsSection.screenSounds => Icons.volume_up_outlined,
      MsSection.owner => Icons.person_outline,
      MsSection.rfTools => Icons.graphic_eq,
      MsSection.pairedApps => Icons.devices_other_outlined,
    };

/// Opens [screen] over the current page.
Future<void> msOpen(BuildContext context, Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

// ------------------------------------------------------------------------------------------------ entry row
class MsRadioEntryRow extends StatefulWidget {
  const MsRadioEntryRow({super.key});

  @override
  State<MsRadioEntryRow> createState() => _MsRadioEntryRowState();
}

class _MsRadioEntryRowState extends State<MsRadioEntryRow> {
  MsRadioController? _asked;

  @override
  Widget build(BuildContext context) {
    final c = MsRadioHost.instance.of(context);
    if (c == null) return const SizedBox.shrink();
    if (!identical(_asked, c)) {
      _asked = c;
      // One quiet look on Wi-Fi for the chip, once per radio, only when it has not looked yet.
      if (c.state.step == MsLinkStep.idle) scheduleMicrotask(() => c.connect());
    }
    return StreamBuilder<MsLinkState>(
      stream: c.states,
      initialData: c.state,
      builder: (context, snap) {
        final st = c.state;
        return ListTile(
          key: const Key('more-meshsonar-radio'),
          minVerticalPadding: Gap.s,
          leading: const Icon(Icons.wifi_tethering_rounded),
          title: const Text('MeshSonar radio'),
          subtitle: Wrap(
            spacing: Gap.s,
            runSpacing: Gap.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [Text('MeshSonar ${c.fw.msVersion}'), MsChip(st)],
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => msOpen(context, MsRadioPage(controller: c)),
        );
      },
    );
  }
}

// ------------------------------------------------------------------------------------------------ the page
class MsRadioPage extends StatefulWidget {
  final MsRadioController controller;
  const MsRadioPage({super.key, required this.controller});

  @override
  State<MsRadioPage> createState() => _MsRadioPageState();
}

class _MsRadioPageState extends State<MsRadioPage> {
  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (c.state.step == MsLinkStep.idle) unawaited(c.connect());
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      key: const Key('ms-radio-page'),
      appBar: AppBar(title: const Text('MeshSonar radio')),
      body: StreamBuilder<MsLinkState>(
        stream: c.states,
        initialData: c.state,
        builder: (context, _) {
          final st = c.state;
          final t = Theme.of(context);
          final name = st.info?.name;
          final rows = <Widget>[];
          // Owner link only when the server offers radio proof (capabilities.radioProof; brief C.9).
          final ownerOffered = msBOwnerAvailable(context);
          for (final s in MsSection.values) {
            if (s == MsSection.owner && !ownerOffered) continue;
            final screen = msSectionScreen(s, c);
            if (screen == null) continue;
            final enabled = s == MsSection.pairing || st.paired;
            rows.add(_SectionRow(
              key: Key('ms-section-${s.name}'),
              icon: _sectionIcon(s),
              title: msSectionTitle(s),
              subtitle: enabled ? _sectionSubtitle(s) : 'Pair first',
              onTap: enabled ? () => msOpen(context, screen) : null,
            ));
          }
          return MsBody(listKey: const Key('ms-radio-list'), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.xs, 0, Layout.screenMargin + Gap.xs, Gap.l),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  header: true,
                  child: Text(name == null || name.isEmpty ? 'MeshSonar radio' : name, key: const Key('ms-radio-name'), style: t.textTheme.headlineSmall),
                ),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.s, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('MeshSonar ${c.fw.msVersion} on MeshCore ${c.fw.coreVersion}',
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  MsChip(st),
                ]),
              ]),
            ),
            if (st.step == MsLinkStep.notOnWifi || st.step == MsLinkStep.wrongRadio || st.step == MsLinkStep.finding) MsNotReady(c),
            InsetGroup(header: 'Sections', rows: rows),
          ]);
        },
      ),
    );
  }
}

class _SectionRow extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  const _SectionRow({super.key, required this.icon, required this.title, required this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        minVerticalPadding: Gap.s,
        enabled: onTap != null,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}
