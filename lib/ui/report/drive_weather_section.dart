// Drive report: the weather the server looked up for this drive (stream 7 WP6, `GET drive-env`, Open-Meteo). Shown only
// when the server says it does this (`capabilities.driveEnv`), the driver key is approved, the weather category is on
// and the drive has been uploaded. The phone never contacts a weather service and never sends a coordinate; the server
// answers one value set per UTC hour for a cell of about 5 km. Every state is explicit (pending, off, nothing to look
// up, offline, failed, unknown drive, rate limit) and nothing is invented. The licence line sits directly under any
// values. All quantities go through Units; the phone barometer is compared with the model's station pressure.
import 'package:flutter/material.dart';

import '../../app/drive_context_hook.dart' show contextLedgerOf;
import '../../core/api.dart';
import '../../core/drive_context_report.dart' show TimeValue;
import '../../core/drive_env_cache.dart';
import '../../core/drive_env_summary.dart';
import '../../core/model.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../../core/units.dart';
import '../app.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../widgets.dart';
import 'drive_context_section.dart' show AppStateLike, loadDriveContextReport;

/// Where the licence line links to.
final Uri openMeteoUrl = Uri.parse('https://open-meteo.com');

const _minLine = 3;
String _hm(DateTime t) => formatTime(t).substring(0, 5);

/// What the section loaded: the answer, plus the phone barometer series to compare with.
class _Loaded {
  final DriveEnvResult result;
  final List<TimeValue> phonePressure;
  final int unsynced;
  const _Loaded(this.result, this.phonePressure, this.unsynced);
}

class DriveWeatherSection extends StatefulWidget {
  final String sessionId;
  final List<DrivePing> pings;
  const DriveWeatherSection({
    super.key,
    required this.sessionId,
    required this.pings,
  });

  @override
  State<DriveWeatherSection> createState() => _DriveWeatherSectionState();
}

class _DriveWeatherSectionState extends State<DriveWeatherSection> {
  /// Null = the drive turned out not to be uploaded (the section stays hidden).
  Future<_Loaded?>? _load;

  Future<_Loaded?> _run() async {
    final s = AppScope.read(context);
    final unsynced = (await s.services.store.unsyncedPings(widget.sessionId))
        .length;
    if (widget.pings.length - unsynced <= 0)
      return null; // nothing confirmed by the server: it cannot know the drive
    final r = await s.driveWeather(widget.sessionId);
    var phone = const <TimeValue>[];
    if (r.env.snapshots.any((e) => e.pressureHpa != null)) {
      try {
        phone =
            (await loadDriveContextReport(
              AppStateLike(contextLedgerOf(s.services)),
              widget.sessionId,
              widget.pings,
            ))?.pressureHpa ??
            const [];
      } catch (_) {} // the comparison is optional
    }
    return _Loaded(r, phone, unsynced);
  }

  void _retry() => setState(() {
        _load = _run();
      });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (!s.driveWeatherEnabled) return const SizedBox.shrink();
    _load ??= _run();
    final t = Theme.of(context);
    return FutureBuilder<_Loaded?>(
      future: _load,
      builder: (context, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(8),
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        } else if (snap.hasError) {
          body = _Failure(error: snap.error!, onRetry: _retry);
        } else if (snap.data == null) {
          return const SizedBox.shrink(); // not uploaded: no block at all
        } else {
          body = _WeatherBody(loaded: snap.data!);
        }
        return Column(
          key: const Key('report-weather'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_outlined,
                    size: 18,
                    color: t.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'WEATHER',
                    style: t.textTheme.labelLarge?.copyWith(
                      color: t.colorScheme.primary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.colorScheme.surface,
                borderRadius: BorderRadius.circular(Corners.card),
                border: Border.all(color: t.colorScheme.outlineVariant),
              ),
              child: body,
            ),
          ],
        );
      },
    );
  }
}

/// The text of a failed ask (also used by tests): offline, rate limit, key, unknown drive or a server error.
({String text, bool retry}) weatherFailureText(Object error) {
  if (error is CmatException) {
    return switch (error.status) {
      404 => (
        text:
            'The server doesn\'t know this drive. It may have been removed from the server, or it has not '
            'finished uploading.',
        retry: false,
      ),
      429 => (
        text: 'The server asked for a pause (too many requests). Try again in a minute.',
        retry: true,
      ),
      401 || 403 => (
        text: 'The server did not accept your driver key, so weather can\'t be loaded. Check the key in Settings.',
        retry: true,
      ),
      null => (
        text: 'Couldn\'t reach the server, so there is no weather to show. You may be offline.',
        retry: true,
      ),
      final c => (
        text:
            'The server answered with an error ($c), so there is no weather to show.',
        retry: true,
      ),
    };
  }
  return (text: 'Couldn\'t load the weather for this drive.', retry: true);
}

class _Failure extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _Failure({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final f = weatherFailureText(error);
    final status = error is CmatException
        ? (error as CmatException).status
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          f.text,
          key: Key('weather-error-${status ?? 'offline'}'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (f.retry) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('weather-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ],
    );
  }
}

class _WeatherBody extends StatelessWidget {
  final _Loaded loaded;
  const _WeatherBody({required this.loaded});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final env = loaded.result.env;
    final snaps = env.snapshots;
    final s = AppScope.of(context);
    final asOf = asOfLabel(
      loaded.result.fetchedAt,
      s.services.clock(),
      offline: loaded.result.offline,
    );
    final parts = <Widget>[];
    final String? note = switch (env.status) {
      DriveEnvStatus.disabled =>
        'Weather is off for this drive, so the server did not look it up.',
      DriveEnvStatus.unavailable =>
        'No weather for this drive. Either nothing was publicly visible to look up (the start and end of a drive are '
            'trimmed for privacy, so a short drive can end up with nothing) or the drive is older than 60 days.',
      DriveEnvStatus.pending =>
        snaps.isEmpty
            ? 'Not looked up yet. The server checks every 30 minutes after a drive has been quiet for 2 hours.'
            : 'Only part of this drive has been looked up so far. The server checks every 30 minutes after a drive has '
                  'been quiet for 2 hours, so more hours may follow.',
      DriveEnvStatus.ready =>
        snaps.isEmpty
            ? 'The server has no weather hours for this drive.'
            : null,
    };
    final noteKey = switch (env.status) {
      DriveEnvStatus.disabled => 'weather-disabled',
      DriveEnvStatus.unavailable => 'weather-unavailable',
      DriveEnvStatus.pending =>
        snaps.isEmpty ? 'weather-pending' : 'weather-partial',
      DriveEnvStatus.ready => 'weather-empty',
    };
    if (note != null)
      parts.add(Text(note, key: Key(noteKey), style: t.textTheme.bodyMedium));

    if (snaps.isNotEmpty) parts.addAll(_values(context));
    if (loaded.unsynced > 0) {
      parts.addAll([
        const SizedBox(height: 10),
        Text(
          'Part of this drive has not uploaded yet. The weather covers what the server has.',
          key: const Key('weather-partial-upload'),
          style: t.textTheme.bodySmall,
        ),
      ]);
    }
    parts.add(const SizedBox(height: 10));
    if (loaded.result.offline) {
      parts.add(
        Text(
          snaps.isEmpty
              ? 'Offline. Last asked the server: $asOf.'
              : '$asOf. The server could not be reached.',
          key: const Key('weather-offline'),
          style: t.textTheme.bodySmall,
        ),
      );
    } else if (env.status != DriveEnvStatus.ready) {
      parts.add(
        Text(
          'Last asked the server: $asOf.',
          key: const Key('weather-asof'),
          style: t.textTheme.bodySmall,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts,
    );
  }

  List<Widget> _values(BuildContext context) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final pal = chartPalette(context);
    final snaps = loaded.result.env.snapshots;
    final sum = summarizeWeather(snaps)!;
    final out = <Widget>[];
    void add(Widget w) => out.addAll([const SizedBox(height: 16), w]);

    out.add(
      Text(
        'Looked up by the server for a cell of about 5 km around where you drove: a model value, not a measurement '
        'at your position. One value per hour, shown in your phone\'s local time.',
        style: t.textTheme.bodySmall,
      ),
    );

    final tiles = <(String, String, String)>[
      if (sum.tempMinC != null)
        (
          'Temperature',
          '${u.temperature(sum.tempMinC!)} to ${u.temperature(sum.tempMaxC!)}',
          'weather-tile-temp',
        ),
      if (sum.dewPointMinC != null)
        (
          'Dew point',
          '${u.temperature(sum.dewPointMinC!)} to ${u.temperature(sum.dewPointMaxC!)}',
          'weather-tile-dew',
        ),
      if (sum.humidityMinPct != null)
        (
          'Humidity',
          '${sum.humidityMinPct!.round()}% to ${sum.humidityMaxPct!.round()}%',
          'weather-tile-humidity',
        ),
      if (sum.windMeanMs != null)
        (
          'Wind',
          'about ${u.speed(sum.windMeanMs!)}, up to ${u.speed(sum.windMaxMs!)}'
              '${sum.windMeanDirDeg == null ? '' : ', from ${compassPoint(sum.windMeanDirDeg!)}'}',
          'weather-tile-wind',
        ),
      if (sum.precipTotalMm != null)
        (
          'Precipitation',
          u.precipitation(sum.precipTotalMm!),
          'weather-tile-precip',
        ),
      if (sum.cloudMeanPct != null)
        (
          'Cloud cover',
          '${sum.cloudMeanPct!.round()}% on average',
          'weather-tile-cloud',
        ),
      if (sum.pressureMinHpa != null)
        (
          'Station pressure',
          u.pressure(sum.pressureMinHpa!) == u.pressure(sum.pressureMaxHpa!)
              ? u.pressure(sum.pressureMinHpa!)
              : '${u.pressure(sum.pressureMinHpa!)} to ${u.pressure(sum.pressureMaxHpa!)}',
          'weather-tile-pressure',
        ),
    ];
    if (tiles.isNotEmpty) {
      add(
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value, key) in tiles)
              Container(
                constraints: const BoxConstraints(minWidth: 140),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: t.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(Corners.chip),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: t.textTheme.labelMedium),
                    const SizedBox(height: 2),
                    Text(value, key: Key(key), style: t.textTheme.titleMedium),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    DateTime local(WeatherSnapshot e) => e.at.toLocal();
    // Temperature and dew point.
    final temps = [
      for (final e in snaps)
        if (e.temperatureC != null) (local(e), e.temperatureC!),
    ];
    final dews = [
      for (final e in snaps)
        if (e.dewPointC != null) (local(e), e.dewPointC!),
    ];
    if (temps.isNotEmpty) {
      add(
        ChartFrame(
          id: 'weather-temp',
          title: 'Temperature (${u.temperatureUnit})',
          summary:
              '${temps.length} hour${temps.length == 1 ? '' : 's'}, temperature from ${u.temperature(sum.tempMinC!)} to '
              '${u.temperature(sum.tempMaxC!)}; first ${u.temperature(temps.first.$2)}, last ${u.temperature(temps.last.$2)}.'
              '${sum.dewPointMinC == null ? '' : ' Dew point from ${u.temperature(sum.dewPointMinC!)} to ${u.temperature(sum.dewPointMaxC!)}.'}',
          caption: 'Air temperature and dew point two metres above ground, model value for about a 5 km cell. Hourly.',
          startWithTable: temps.length < _minLine,
          table: ChartTable(
            head: ['Time', 'Temperature', 'Dew point'],
            rows: [
              for (final e in snaps)
                if (e.temperatureC != null || e.dewPointC != null)
                  [
                    _hm(local(e)),
                    e.temperatureC == null
                        ? '—'
                        : u.temperature(e.temperatureC!),
                    e.dewPointC == null ? '—' : u.temperature(e.dewPointC!),
                  ],
            ],
          ),
          chart: TimeLineChart(
            series: [
              ChartSeries(
                name: 'Temperature',
                points: [
                  for (final p in temps) (p.$1, u.temperatureValue(p.$2)),
                ],
                color: pal[2],
              ),
              if (dews.isNotEmpty)
                ChartSeries(
                  name: 'Dew point',
                  points: [
                    for (final p in dews) (p.$1, u.temperatureValue(p.$2)),
                  ],
                  color: pal[0],
                ),
            ],
            yLabel: u.temperatureUnit,
            legend: dews.isNotEmpty,
            breakGap: const Duration(hours: 2),
            dotColor: (_) => pal[2],
            xFormat: _hm,
          ),
        ),
      );
    }

    // Wind.
    final winds = [
      for (final e in snaps)
        if (e.windMs != null) (local(e), e.windMs!),
    ];
    if (winds.isNotEmpty) {
      String dir(WeatherSnapshot e) => e.windDirDeg == null
          ? ''
          : ' from ${compassPoint(e.windDirDeg!)} (${e.windDirDeg!.round()}°)';
      add(
        ChartFrame(
          id: 'weather-wind',
          title: 'Wind speed (${u.speedUnit})',
          summary:
              '${winds.length} hour${winds.length == 1 ? '' : 's'}, average ${u.speed(sum.windMeanMs!)}, highest '
              '${u.speed(sum.windMaxMs!)}${sum.windMeanDirDeg == null ? '' : ', mostly from ${compassPoint(sum.windMeanDirDeg!)}'}.',
          caption: 'Wind ten metres above ground, model value. The direction is where the wind comes from.',
          startWithTable: winds.length < _minLine,
          table: ChartTable(
            head: ['Time', 'Wind'],
            rows: [
              for (final e in snaps)
                if (e.windMs != null)
                  [_hm(local(e)), '${u.speed(e.windMs!)}${dir(e)}'],
            ],
          ),
          chart: TimeLineChart(
            series: [
              ChartSeries(
                name: 'Wind',
                points: [for (final p in winds) (p.$1, u.speedValue(p.$2))],
                color: pal[3],
              ),
            ],
            yLabel: u.speedUnit,
            includeLo: 0,
            breakGap: const Duration(hours: 2),
            dotColor: (_) => pal[3],
            xFormat: _hm,
          ),
        ),
      );
    }

    // Pressure: the model's station pressure against the phone barometer.
    final station = [
      for (final e in snaps)
        if (e.pressureHpa != null) (local(e), e.pressureHpa!),
    ];
    final phone = loaded.phonePressure;
    if (station.isNotEmpty) {
      final cmp = comparePressure(snaps, phone);
      final rows = <(DateTime, List<String>)>[
        for (final p in station) (p.$1, [_hm(p.$1), u.pressure(p.$2), '—']),
        for (final p in phone) (p.$1, [_hm(p.$1), '—', u.pressure(p.$2)]),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      final diff = cmp == null
          ? null
          : '${cmp.meanDiffHpa >= 0 ? 'higher' : 'lower'} than the weather model by ${u.pressureDelta(cmp.meanDiffHpa)} on average over '
                '${cmp.hours} hour${cmp.hours == 1 ? '' : 's'}';
      add(
        ChartFrame(
          id: 'weather-pressure',
          title: 'Air pressure (${u.pressureUnit}): weather model and phone',
          summary:
              'Weather model station pressure from ${u.pressure(sum.pressureMinHpa!)} to ${u.pressure(sum.pressureMaxHpa!)} over '
              '${station.length} hour${station.length == 1 ? '' : 's'}.'
              '${phone.isEmpty ? ' No phone barometer readings for this drive.' : ' ${phone.length} phone barometer readings.'}'
              '${diff == null ? '' : ' The phone read $diff.'}',
          caption:
              'Station pressure: a model value for about a 5 km cell, hourly. Phone barometer: measured inside the car '
              '(cabin pressure), so a small offset is normal.',
          startWithTable: station.length + phone.length < _minLine,
          table: ChartTable(
            head: const ['Time', 'Station pressure (model)', 'Phone barometer'],
            rows: [for (final r in rows) r.$2],
          ),
          chart: TimeLineChart(
            series: [
              ChartSeries(
                name: 'Weather model',
                points: [
                  for (final p in station) (p.$1, u.pressureValue(p.$2)),
                ],
                color: pal[4],
              ),
              if (phone.isNotEmpty)
                ChartSeries(
                  name: 'Phone barometer',
                  points: [
                    for (final p in phone)
                      (p.$1.toLocal(), u.pressureValue(p.$2)),
                  ],
                  color: pal[0],
                ),
            ],
            yLabel: u.pressureUnit,
            legend: phone.isNotEmpty,
            breakGap: const Duration(hours: 2),
            dotColor: phone.isEmpty ? (_) => pal[4] : null,
            xFormat: _hm,
          ),
        ),
      );
      if (diff != null) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'The phone barometer read $diff.',
              key: const Key('weather-pressure-compare'),
              style: t.textTheme.bodySmall,
            ),
          ),
        );
      } else if (phone.isEmpty) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'No phone barometer readings were recorded with this drive, so there is nothing to compare.',
              key: const Key('weather-pressure-nophone'),
              style: t.textTheme.bodySmall,
            ),
          ),
        );
      }
    }

    // Every hourly value, so precipitation, humidity and cloud are not tile-only.
    add(_HourlyTable(snaps: snaps, u: u));

    out.addAll([const SizedBox(height: 12), _CreditLine()]);
    return out;
  }
}

class _HourlyTable extends StatelessWidget {
  final List<WeatherSnapshot> snaps;
  final Units u;
  const _HourlyTable({required this.snaps, required this.u});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String v(double? x, String Function(double) f) => x == null ? '—' : f(x);
    return Material(
      type: MaterialType.transparency, // the card behind has a colour: ink must paint on its own layer
      child: Theme(
        data: t.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('weather-hourly'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text('All hourly values', style: t.textTheme.titleSmall),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 16,
                headingRowHeight: 36,
                dataRowMinHeight: 32,
                dataRowMaxHeight: 36,
                columns: const [
                  DataColumn(label: Text('Time')),
                  DataColumn(label: Text('Temp')),
                  DataColumn(label: Text('Dew point')),
                  DataColumn(label: Text('Humidity')),
                  DataColumn(label: Text('Wind')),
                  DataColumn(label: Text('Precipitation')),
                  DataColumn(label: Text('Cloud')),
                  DataColumn(label: Text('Pressure')),
                ],
                rows: [
                  for (final e in snaps)
                    DataRow(
                      cells: [
                        DataCell(Text(_hm(e.at.toLocal()))),
                        DataCell(Text(v(e.temperatureC, u.temperature))),
                        DataCell(Text(v(e.dewPointC, u.temperature))),
                        DataCell(
                          Text(v(e.humidityPct, (x) => '${x.round()}%')),
                        ),
                        DataCell(
                          Text(
                            e.windMs == null
                                ? '—'
                                : '${u.speed(e.windMs!)}${e.windDirDeg == null ? '' : ' ${compassPoint(e.windDirDeg!)}'}',
                          ),
                        ),
                        DataCell(Text(v(e.precipMm, u.precipitation))),
                        DataCell(Text(v(e.cloudPct, (x) => '${x.round()}%'))),
                        DataCell(Text(v(e.pressureHpa, u.pressure))),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Weather data by Open-Meteo.com (CC BY 4.0)", a link to open-meteo.com (the licence line, directly under values).
class _CreditLine extends StatelessWidget {
  const _CreditLine();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      link: true,
      label: '$openMeteoCredit. Opens open-meteo.com in your browser.',
      excludeSemantics: true,
      child: InkWell(
        key: const Key('weather-credit'),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          final ok = await AppScope.read(context).services
              .openUrl(openMeteoUrl);
          if (!ok)
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'Couldn\'t open the browser. The link is open-meteo.com.',
                ),
              ),
            );
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              openMeteoCredit,
              style: t.textTheme.bodySmall?.copyWith(
                color: t.colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
