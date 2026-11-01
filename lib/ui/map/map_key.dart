// The key on the Drive and full-screen maps: one line for each thing the map is drawing right now, in the colours it is
// drawing them in. It follows the map: change "colour by" (Best SNR, Share heard, Noise floor, Ping age, Noise vs typical),
// the ping colours (Heard / not, or by SNR) or switch a layer off and the key changes with it. The repeater dots carry their
// own line, named as what it is (the age of a repeater's last advert), so it can never be read as a signal scale.
//
// Keys: 'map-key-cells', 'map-key-pings', 'map-key-repeaters' (the line), plus the dense NetworkAgeLegend's own
// 'map-network-legend' and the credit 'map-network-attribution'.
import 'package:flutter/material.dart';

import '../drive/drive_map_model.dart';
import '../theme.dart';
import 'coverage_layer_controls.dart' show coverageLegend, colorByLabel;
import 'coverage_map.dart' show networkLevelColor;
import 'layers/layers_sheet.dart' show NetworkAgeLegend;
import 'layers/repeater_map_source.dart' show kNetworkLayerId;
import 'map_layers.dart' show PingColorMode;

/// What the key has to say for the map's current state. Used for both the widget and the height the overlays above it clear.
class MapKeyParts {
  final bool cells, pings, repeaters;
  const MapKeyParts({required this.cells, required this.pings, required this.repeaters});
  bool get any => cells || pings || repeaters;

  /// A generous estimate of the key's height (a cells line can wrap to two lines on a phone, the repeater credit is a line).
  double get height => !any ? 0 : 10 + (cells ? 34 : 0) + (pings ? 18 : 0) + (repeaters ? 34 : 0);
}

MapKeyParts mapKeyParts(DriveMapModel m) => MapKeyParts(
  cells: m.layers.networkCoverage && m.networkCells.isNotEmpty,
  pings: m.layers.pings && m.visiblePings.isNotEmpty,
  repeaters: m.layerState.isOn(kNetworkLayerId) && m.repeaterSource.globalPoints.length > 0,
);

class MapKey extends StatelessWidget {
  final DriveMapModel model;
  const MapKey({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([model, model.repeaterSource]),
      builder: (context, _) {
        final parts = mapKeyParts(model);
        if (!parts.any) return const SizedBox.shrink();
        final t = Theme.of(context);
        final mc = MeshSonarColors.of(context);
        final small = t.textTheme.labelSmall?.copyWith(fontSize: 11, color: t.colorScheme.onSurfaceVariant);
        final head = small?.copyWith(fontWeight: FontWeight.w700, color: t.colorScheme.onSurface);
        Widget line(Key k, String title, List<(Color, String)> items) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Wrap(
            key: k,
            spacing: 6,
            runSpacing: 1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(title, style: head),
              for (final (c, label) in items)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                  const SizedBox(width: 3),
                  Text(label, style: small),
                ]),
            ],
          ),
        );

        final by = model.colorBy;
        final byResult = model.layers.pingColors == PingColorMode.result;
        final set = model.repeaterSource.feed.global;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parts.cells)
              line(const Key('map-key-cells'), 'Coverage cells · ${colorByLabel(by)}:', [
                for (final (level, label) in coverageLegend(by)) (networkLevelColor(context, level, mode: by), label),
              ]),
            if (parts.pings)
              line(const Key('map-key-pings'), 'Your pings:', byResult
                  ? [(mc.snrStrong, 'heard'), (mc.silent, 'nothing heard')]
                  : [(mc.forPing(heard: true, snr: 10), '+10 dB'), (mc.forPing(heard: true, snr: 0), '0'), (mc.forPing(heard: true, snr: -10), '-10 dB'), (mc.silent, 'nothing heard')]),
            if (parts.repeaters)
              Column(
                key: const Key('map-network-attribution'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    key: const Key('map-key-repeaters'),
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text('Repeater dots · last advert:', style: head),
                      NetworkAgeLegend(set: set, dense: true),
                    ]),
                  ),
                  if (set.attribution != null) Text(set.attribution!, style: small),
                ],
              ),
          ],
        );
      },
    );
  }
}
