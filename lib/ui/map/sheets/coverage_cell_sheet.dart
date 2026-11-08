// The coverage v2 cell inspector (plan section 5, "Cell inspector"): what `/api/coverage/cell/{h3}` says about one res-11 cell.
// Measured: the mean SNR and its band, min / max / spread, replies and fails (reply rate), noise floor, first and last measured,
// sources, and the repeaters that served the cell (keys resolved to names the way cell-links does). Predicted: the estimate,
// its band, the distance to the nearest measured cell and how many cells it came from. "This drive" adds your own pings there.
import 'package:flutter/material.dart';

import '../../../core/coverage_v2.dart';
import '../../../core/hex_cells.dart' show HexCell;
import '../../app.dart' show AppScope;
import '../../design/app_type.dart' show AppType;
import '../../theme.dart';
import '../cell_sheet.dart' show lastSeenText;
import '../coverage_bands.dart';
import '../map_layers.dart' show formatSnrShort;

String _db(double v) => '${formatSnrShort(v)} dB';

/// One line for the panel header.
String coverageCellSummary(CoverageCellInfo? info, CoverageMeta meta, {HexCell? mine, int unplaced = 0}) {
  final m = info?.measured, p = info?.predicted;
  String withMore(String s) => unplaced > 0 ? '$s  ·  $unplaced not on the map' : s;
  if (m != null) {
    final label = meta.labelOf(m.band);
    if (m.band == CoverageBand.noReply) return '${meta.labelOf(0)}  ·  ${m.nFail} ${m.nFail == 1 ? 'ping' : 'pings'}';
    final mean = m.snrMean;
    return withMore('$label${mean == null ? '' : '  ·  mean ${_db(mean)}'}  ·  ${m.attempts} ${m.attempts == 1 ? 'ping' : 'pings'}');
  }
  if (p != null) {
    if (p.band == 0) return 'Predicted: no coverage';
    return 'Predicted ${meta.labelOf(p.band).toLowerCase()}${p.snrEst == null ? '' : '  ·  about ${_db(p.snrEst!)}'}';
  }
  if (mine != null) return 'Your pings here: ${mine.sent}';
  return info == null ? 'Coverage cell' : 'Nothing measured here yet';
}

class CoverageCellSheet extends StatelessWidget {
  final CoverageCellInfo? info;
  final CoverageMeta meta;

  /// This drive's own cell here, when there is one.
  final HexCell? mine;
  final String h3;

  /// Name of a repeater key (a prefix of the full key); null = not resolvable, the key is shown.
  final String? Function(String key)? repeaterName;
  const CoverageCellSheet({super.key, required this.info, required this.meta, required this.h3, this.mine, this.repeaterName});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bands = CoverageBandColors.of(MeshSonarColors.of(context).palette, t.brightness);
    final sf = presetSf(info?.preset ?? meta.defaultPreset);
    final muted = t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    Widget stat(String label, String value, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: muted)),
          const SizedBox(width: Gap.s),
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppType.tabular)),
          ),
        ],
      ),
    );
    Widget header(String text) => Padding(
      padding: const EdgeInsets.only(top: Gap.s, bottom: 2),
      child: Text(text, style: t.textTheme.titleSmall),
    );
    Widget bandRow(int band, {bool predicted = false}) {
      final range = meta.rangeText(band, sf: sf);
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(
          children: [
            CoverageBandSwatch(band: band, colors: bands, predicted: predicted, size: 16),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Text(
                '${meta.labelOf(band)}${range == null ? '' : '  ($range)'}',
                key: const Key('coverage-cell-band'),
                style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }

    final m = info?.measured, p = info?.predicted, my = mine;
    final rows = <Widget>[];
    if (m != null) {
      rows
        ..add(bandRow(m.band))
        ..add(stat('Mean SNR', m.snrMean == null ? '-' : _db(m.snrMean!), key: const Key('coverage-cell-mean')))
        ..add(stat('Lowest / highest', m.snrMin == null || m.snrMax == null ? '-' : '${_db(m.snrMin!)} / ${_db(m.snrMax!)}'))
        ..add(stat('Spread (SD)', m.snrSd == null ? '-' : '${m.snrSd!.toStringAsFixed(1)} dB'))
        ..add(stat(
          'Replies',
          '${m.nOk} of ${m.attempts}${m.replyRate == null ? '' : ' (${(100 * m.replyRate!).round()}%)'}',
          key: const Key('coverage-cell-replies'),
        ));
      if (m.attempts < meta.faintBelow) rows.add(Text('Drawn faint: under ${meta.faintBelow} pings here.', style: muted));
      rows
        ..add(stat('Noise floor', m.noiseFloor == null ? '-' : '${m.noiseFloor!.round()} dBm'))
        ..add(stat('First measured', m.firstAt == null ? '-' : lastSeenText(m.firstAt!)))
        ..add(stat('Last measured', m.lastAt == null ? '-' : lastSeenText(m.lastAt!)));
      final src = [for (final e in m.sources.entries) if (e.value > 0) '${e.key == 'meshsonar' ? 'MeshSonar' : (e.key == 'meshmapper' ? 'MeshMapper' : e.key)} ${e.value}'];
      if (src.isNotEmpty) rows.add(stat('Sources', src.join(', ')));
      if (m.repeaters.isNotEmpty) {
        rows.add(header('Served by'));
        for (final r in m.repeaters) {
          final name = repeaterName?.call(r.key);
          rows.add(stat(
            name ?? r.key,
            '${r.n} ${r.n == 1 ? 'ping' : 'pings'}${r.snrMean == null ? '' : '  ·  ${_db(r.snrMean!)}'}',
            key: Key('coverage-cell-repeater-${r.key}'),
          ));
        }
      }
    } else if (p != null) {
      rows
        ..add(bandRow(p.band, predicted: true))
        ..add(stat('Estimated SNR', p.snrEst == null ? '-' : _db(p.snrEst!), key: const Key('coverage-cell-estimate')))
        ..add(stat('Nearest measured cell', p.dNearestM == null ? '-' : AppScope.unitsOf(context).distance(p.dNearestM!)))
        ..add(stat('Estimated from', '${p.contributors} measured ${p.contributors == 1 ? 'cell' : 'cells'}'))
        ..add(Text('An estimate from nearby drives, not a measurement. Drive here to measure it.', style: muted));
    } else if (info != null) {
      rows.add(Text('Nothing measured or predicted here yet.', style: muted));
    }
    if (my != null) {
      rows
        ..add(header('This drive'))
        ..add(stat('Your pings here', '${my.sent}', key: const Key('coverage-cell-mine')))
        ..add(stat('Heard', '${my.heard} of ${my.sent}'))
        ..add(stat('Your mean SNR', my.snrMeanDb == null ? '-' : _db(my.snrMeanDb!)));
    }
    return Padding(
      key: const Key('coverage-cell-sheet'),
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}

/// A legend / inspector swatch for one band: the measured look (No reply = quiet grey with the red outline), or, with
/// [predicted], the hatched look.
class CoverageBandSwatch extends StatelessWidget {
  final int band;
  final CoverageBandColors colors;
  final bool predicted;
  final bool faint;
  final double size;
  const CoverageBandSwatch({super.key, required this.band, required this.colors, this.predicted = false, this.faint = false, this.size = 18});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: _SwatchPainter(band, colors, predicted, faint)),
  );
}

class _SwatchPainter extends CustomPainter {
  final int band;
  final CoverageBandColors c;
  final bool predicted, faint;
  _SwatchPainter(this.band, this.c, this.predicted, this.faint);

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * 0.2));
    final path = Path()..addRRect(r);
    if (predicted) {
      // The legend shows a mid opacity (o = 0.6, the nearest predicted cells).
      const o = 0.6;
      final k = PredictedOpacity.of(c);
      if (band != 0) canvas.drawPath(path, Paint()..color = c[band].withValues(alpha: o * k.fill));
      canvas.save();
      canvas.clipPath(path);
      final paint = Paint()
        ..color = band == 0 ? c.noReplyPoint.withValues(alpha: o * k.noneHatch) : c[band].withValues(alpha: o * k.hatch)
        ..strokeWidth = band == 0 ? 1 : 2;
      for (var k = -2; k < 6; k++) {
        final x = k * 6.0;
        canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
      }
      canvas.restore();
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = c.noReplyPoint.withValues(alpha: 0.5));
      return;
    }
    if (band == CoverageBand.noReply) {
      canvas.drawPath(path, Paint()..color = c[0].withValues(alpha: faint ? 0.35 : 0.6));
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = c.noReplyOutline.withValues(alpha: faint ? 0.55 : 0.9));
      return;
    }
    canvas.drawPath(path, Paint()..color = c[band].withValues(alpha: faint ? 0.55 : 0.85));
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.band != band || old.c != c || old.predicted != predicted || old.faint != faint;
}
