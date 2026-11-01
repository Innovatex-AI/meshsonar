// Settings > Wardriving: everything about the pings this phone sends, in one place. Which channel they go out on, whether they
// are sent at all, what exactly goes on the air, what it costs in airtime, how often, and what became of the ones of the
// current drive (heard by repeaters on the phone, confirmed by observers on the server).
//
// Honest by construction: MeshSonar only ever transmits ONE thing while wardriving, the ping "MS:" + 10 random characters on
// the wardrive channel, as an ordinary flood group text. That text is the message the network's observers hear and report.
// "Send pings to the mesh" off = listen-only (discovery): nothing is transmitted and no observer can confirm anything.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/ping_feedback.dart';
import '../../core/api.dart' show Settings;
import '../../radio/airtime.dart';
import '../../radio/wardrive_engine.dart' show formatPingText, pingTagLength;
import '../app.dart';
import 'ping_feedback_rows.dart';
import 'settings_kit.dart';

const String wardrivingHelp = 'MeshSonar wardrives by sending one short message, a ping, on a shared channel. Repeaters '
    'repeat it, your radio hears them, and fixed observers report it to the website: that is how a ping gets its repeaters, '
    'hop counts and routes. An auto-ping goes out when BOTH are met: the time has passed and you\'ve moved the distance. '
    'Ping now works any time. Changes to the cadence apply straight away, even mid-drive.';

const String _notSendingReason = 'Off while pings are not sent: nothing is transmitted. Turn on "Send pings to the mesh" to '
    'use it.';

/// The three cadence sliders. [prefix] keeps the keys of the Settings copy and the Map tab's quick sheet apart (that sheet is
/// lib/ui/drive/ping_settings_sheet.dart). Changes apply straight away, even mid-drive.
List<Widget> pingCadenceTiles(BuildContext context, {String prefix = ''}) {
  final s = AppScope.of(context);
  final st = s.settings;
  final units = s.units;
  final sending = !st.discoveryMode;
  return [
    SliderTile(
      key: Key('${prefix}interval'),
      sliderKey: Key('${prefix}interval-slider'),
      icon: Icons.timer_outlined,
      title: 'Auto-ping',
      stops: intervalStops,
      value: st.intervalSec,
      label: (v) => 'Every $v s',
      caption: 'How often an automatic ping may go out while driving. It goes out exactly when this time has passed and you '
          'have moved the distance below. Shorter maps more, but uses more airtime on the shared mesh.',
      disabledReason: _notSendingReason,
      minLabel: '10 s',
      maxLabel: '2 min',
      enabled: sending,
      onChanged: (v) => s.updateSettings(s.settings.copyWith(intervalSec: v)),
    ),
    SliderTile(
      key: Key('${prefix}min-distance'),
      sliderKey: Key('${prefix}min-distance-slider'),
      icon: Icons.straighten,
      title: 'Minimum distance',
      stops: units.minDistanceStops(distanceStops),
      value: st.minDistanceM,
      label: units.sliderDistance,
      caption: 'Skips auto-pings while you\'re stopped at lights: the next one waits until you have moved this far.',
      disabledReason: _notSendingReason,
      minLabel: units.sliderDistance(units.minDistanceStops(distanceStops).first),
      maxLabel: units.sliderDistance(units.minDistanceStops(distanceStops).last),
      enabled: sending,
      onChanged: (v) => s.updateSettings(s.settings.copyWith(minDistanceM: v)),
    ),
    SliderTile(
      key: Key('${prefix}listen-window'),
      sliderKey: Key('${prefix}listen-window-slider'),
      icon: Icons.hearing_outlined,
      title: 'Listen window',
      stops: listenStops,
      value: st.listenWindowSec,
      label: (v) => '$v s',
      caption: 'How long each ping waits for repeaters to answer. Longer hears slower and more distant repeaters; it keeps '
          'going past this while repeats are still arriving. Never longer than the interval less a second. Default 10 s, '
          'the same as MeshMapper.',
      disabledReason: _notSendingReason,
      minLabel: '${Settings.minListenSec} s',
      maxLabel: '${Settings.maxListenSec} s',
      enabled: sending,
      onChanged: (v) => s.updateSettings(s.settings.copyWith(listenWindowSec: v)),
    ),
  ];
}

/// An example of what goes on the air, for the preview row ("MS:" and ten characters).
String pingPreviewText() => formatPingText('k3x9m2q7ab'.substring(0, pingTagLength));

/// "214 ms" / "1.2 s".
String airtimeLabel(double ms) => ms < 1000 ? '${ms.round()} ms' : '${(ms / 1000).toStringAsFixed(1)} s';

List<Widget> wardrivingSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  final sending = !st.discoveryMode;
  final info = s.selfInfo;
  final airMs = info == null
      ? null
      : wardrivePingAirtimeMs(radioName: info.name, sf: info.radio.sf, bwKhz: info.radio.bwKhz, cr: info.radio.cr);
  final tiles = pingCadenceTiles(context);
  final shareOfTime = airMs == null || st.intervalSec <= 0 ? null : 100 * airMs / (st.intervalSec * 1000);
  final shown = info?.name.isNotEmpty == true ? info!.name : 'Your radio';
  return [
    SettingsAnchor(
      id: 'channel',
      child: ListTile(
        key: const Key('channel'),
        leading: const Icon(Icons.tag),
        title: const Text('Wardrive channel'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(st.channel, key: const Key('channel-name')),
          const Text('Pings go out on this channel. Use the one your mesh community wardrives on; the default is '
              '#wardriving. The key comes from the name in lower case, so #Wardriving is the same channel.'),
          if (s.driving) const SettingsWhyNot('Locked while driving: stop the drive to change it.'),
        ]),
        trailing: const Icon(Icons.chevron_right),
        onTap: s.driving
            ? null
            : () async {
                final v = await editSettingText(context,
                    title: 'Wardrive channel',
                    initial: st.channel,
                    hint: '#wardriving',
                    help: 'The channel pings are sent on. Use the one your mesh community wardrives on.',
                    validate: (v) => v.trim().isEmpty ? 'Enter a channel name' : null);
                if (v != null) {
                  var c = v.trim();
                  if (!c.startsWith('#')) c = '#$c';
                  await s.updateSettings(st.copyWith(channel: c));
                }
              },
      ),
    ),
    SettingsAnchor(
      id: 'send-pings',
      child: SwitchListTile(
        key: const Key('send-pings'),
        secondary: Icon(s.driving ? Icons.lock_outline : (sending ? Icons.podcasts : Icons.hearing_outlined)),
        title: const Text('Send pings to the mesh'),
        subtitle: s.driving
            ? const SettingsWhyNot('Locked while driving: stop the drive to change it.')
            : Text(sending
                ? 'On: each ping is sent on ${st.channel}. Repeaters repeat it, observers report it to the website: that is '
                    'where a ping\'s repeaters, hop counts and routes come from.'
                : 'Off (listen-only): the next drive transmits nothing, not even the ping. It only records repeaters '
                    'it overhears. No observer can confirm your drive.'),
        value: sending,
        onChanged: s.driving ? null : (v) => s.updateSettings(st.copyWith(discoveryMode: !v)),
      ),
    ),
    SettingsAnchor(
      id: 'ping-message',
      child: ListTile(
        key: const Key('ping-message'),
        leading: const Icon(Icons.chat_bubble_outline),
        title: const Text('What goes on the air'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$shown: ${pingPreviewText()}', key: const Key('ping-preview')),
          const Text('Ten random characters, new for every ping. No position, no time, nothing about you; MeshCore itself '
              'puts your radio\'s name in front. Where the ping happened is recorded on this phone from its GPS.'),
          const Text('Sent as an ordinary flood: every repeater in range repeats it, with no region scope.'),
        ]),
      ),
    ),
    SettingsAnchor(
      id: 'ping-airtime',
      child: ListTile(
        key: const Key('ping-airtime'),
        leading: const Icon(Icons.timer_outlined),
        title: const Text('Airtime per ping'),
        subtitle: Text(
          airMs == null
              ? 'Connect a radio to see how long one ping occupies the air at its settings.'
              : 'About ${airtimeLabel(airMs)} on air at SF${info!.radio.sf} / ${info.radio.bwKhz!.toStringAsFixed(1)} kHz'
                  '${shareOfTime == null || !sending ? '' : ', ${shareOfTime.toStringAsFixed(1)}% of the time at one ping every ${st.intervalSec} s'}. '
                  'The interval below is the limit on pings; one is only held back for a moment right after you send a chat message.',
        ),
      ),
    ),
    SettingsAnchor(id: 'interval', child: tiles[0]),
    SettingsAnchor(id: 'min-distance', child: tiles[1]),
    SettingsAnchor(id: 'listen-window', child: tiles[2]),
    pingFeedbackRows(context),
    SettingsAnchor(id: 'wardrive-counters', child: WardriveCountersTile(state: s)),
  ];
}

/// "This drive": pings sent, repeaters that heard them, observers that confirmed them.
class WardriveCountersTile extends StatefulWidget {
  final AppState state;
  const WardriveCountersTile({super.key, required this.state});
  @override
  State<WardriveCountersTile> createState() => _WardriveCountersTileState();
}

class _WardriveCountersTileState extends State<WardriveCountersTile> {
  @override
  void initState() {
    super.initState();
    // Opening the page asks the server once for the newest observer numbers (also for a drive that just ended).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.state.hasKey) widget.state.pollObservers();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListTile(
      key: const Key('wardrive-counters'),
      leading: const Icon(Icons.fact_check_outlined),
      title: const Text('This drive'),
      subtitle: Text(driveCounterSummary(s), key: const Key('wardrive-counters-text')),
    );
  }
}

/// The counters in words. Observer numbers say where they stand: waiting for the first upload, live, or not offered.
String driveCounterSummary(AppState s) {
  if (!s.driving && s.txPingCount == 0) {
    return 'No drive running. Start one and the counters show here: pings sent, repeaters that heard them, observers that '
        'confirmed them.';
  }
  if (s.settings.discoveryMode && s.driving) {
    return 'Listen-only: nothing is sent. ${s.pingCount} repeater sighting${s.pingCount == 1 ? '' : 's'} recorded so far.';
  }
  final b = StringBuffer('${s.txPingCount} ping${s.txPingCount == 1 ? '' : 's'} sent, heard by repeaters ${s.heardCount} time${s.heardCount == 1 ? '' : 's'} '
      '(${s.echoCount} repeater hearing${s.echoCount == 1 ? '' : 's'}). ');
  final skipped = s.skippedPingCounts.values.fold<int>(0, (a, b) => a + b);
  if (skipped > 0) {
    b.write('$skipped held back. ');
  }
  b.write(observerLine(s));
  return b.toString().trim();
}

String observerLine(AppState s) {
  final f = s.pingFeedback;
  return switch (f.state) {
    ObserverFeedbackState.live => 'Observers confirmed ${f.confirmedPings} of ${f.answeredPings} uploaded pings.',
    ObserverFeedbackState.waiting => 'Observers: waiting for the first upload (pings upload every few minutes).',
    ObserverFeedbackState.unavailable => 'Observers: this server does not report them.',
    ObserverFeedbackState.noKey => 'Observers: needs a driver key, because only uploaded pings can be matched.',
  };
}
