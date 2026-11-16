// Shared rig for the MeshTrack UI tests: a real MeshTrackService (no start(), so no periodic tick), a fake
// MeshTrackGroupOps that records calls, and a themed host on an iPhone 17 Pro (402 x 874 pt) in dark mode by default.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';
import 'package:meshsonar/ui/theme.dart';

class FakeOps extends ChangeNotifier implements MeshTrackGroupOps {
  final MeshTrackService svc;
  FakeOps(this.svc);

  final calls = <String>[];
  MtGroupOpResult? nextResult;
  int _nextId = 10;
  @override
  bool introSeen = false;
  MtPositionMode mode = MtPositionMode.exact;
  MtRate rateValue = MtRate.smart;
  bool answer = true;
  final Set<int> showPositions = {};
  final Set<int> offRadio = {};
  List<Channel> eligible = const [];

  MtGroupOpResult _take(MtGroupOpResult ok) {
    final r = nextResult;
    nextResult = null;
    return r ?? ok;
  }

  @override
  Future<MtGroupOpResult> createGroup(String name) async {
    calls.add('create:$name');
    final r = _take(MtGroupOpResult(MtGroupOpStatus.ok, channelId: _nextId));
    if (r.ok) svc.addGroup(_nextId++, name);
    notifyListeners();
    return r;
  }

  @override
  Future<MtGroupOpResult> joinFromLink(String link) async {
    calls.add('join:$link');
    final r = _take(MtGroupOpResult(MtGroupOpStatus.ok, channelId: _nextId));
    if (r.ok) svc.addGroup(_nextId++, 'Saturday crew');
    notifyListeners();
    return r;
  }

  @override
  Future<MtGroupOpResult> useExistingChannel(int channelId) async {
    calls.add('use:$channelId');
    final r = _take(MtGroupOpResult(MtGroupOpStatus.ok, channelId: channelId));
    if (r.ok) svc.addGroup(channelId, eligible.firstWhere((c) => c.id == channelId, orElse: () => Channel(radioId: 'r', name: 'Club', kind: ChannelKind.private)).name);
    notifyListeners();
    return r;
  }

  @override
  Future<MtGroupConfig?> stopUsingChannel(int channelId) async {
    calls.add('stop:$channelId');
    final c = svc.leaveGroup(channelId);
    notifyListeners();
    return c;
  }

  @override
  Future<void> undoStopUsing(MtGroupConfig config) async {
    calls.add('undoStop:${config.channelId}');
    svc.restoreGroup(config);
    notifyListeners();
  }

  @override
  Future<MtGroupOpResult> startFresh(int channelId) async {
    calls.add('fresh:$channelId');
    final r = _take(MtGroupOpResult(MtGroupOpStatus.ok, channelId: _nextId));
    if (r.ok) {
      final old = svc.state.group(channelId)!.name;
      svc.leaveGroup(channelId);
      svc.addGroup(_nextId++, old);
    }
    notifyListeners();
    return r;
  }

  @override
  Future<void> undoStartFresh(int newChannelId) async => calls.add('undoFresh:$newChannelId');

  @override
  String inviteLink(int channelId) => 'meshcore://channel/add?name=Group&secret=00112233445566778899aabbccddeeff';

  @override
  List<Channel> eligibleChannels() => eligible;

  @override
  bool notOnRadio(int channelId) => offRadio.contains(channelId);

  @override
  bool isGroup(int channelId) => svc.state.group(channelId) != null;

  /// The Drive panel's "New" tag (the real ops arm it on the first drive).
  bool newTag = false;
  @override
  bool get panelNew => newTag;
  @override
  Future<void> markPanelSeen() async {
    if (!newTag) return;
    newTag = false;
    calls.add('panelSeen');
    notifyListeners();
  }

  @override
  Future<void> setIntroSeen() async {
    introSeen = true;
    calls.add('introSeen');
  }

  @override
  MtPositionMode get positionMode => mode;
  @override
  Future<void> setPositionMode(MtPositionMode m) async {
    mode = m;
    svc.setPositionMode(m);
    notifyListeners();
  }

  @override
  MtRate get rate => rateValue;
  @override
  Future<void> setRate(MtRate r) async {
    rateValue = r;
    svc.setRate(r);
    notifyListeners();
  }

  @override
  bool get answerRequests => answer;
  @override
  Future<void> setAnswerRequests(bool on) async {
    answer = on;
    svc.setAnswerRequests(on);
    notifyListeners();
  }

  @override
  bool showPositionMessages(int channelId) => showPositions.contains(channelId);
  @override
  Future<void> setShowPositionMessages(int channelId, bool on) async {
    on ? showPositions.add(channelId) : showPositions.remove(channelId);
    notifyListeners();
  }
}

class MtRig {
  final sent = <(int, String)>[];
  PrivacyZones zones = const PrivacyZones([]);
  late final MeshTrackService svc = MeshTrackService(
    sendChannelText: (id, text) async {
      sent.add((id, text));
      return true;
    },
    budget: (_, _) => MtBudget.ok,
    zones: () => zones,
    selfName: () => 'Andy',
    now: () => clock,
  );
  DateTime clock = DateTime.now();
  late final FakeOps ops = FakeOps(svc);
  MtLatLon? here = (lat: 40.1262, lon: -82.9291); // Westerville
  double? accuracy;
  ChatController? chat;
  Units units = Units.metric;
  final centred = <(double, double)>[];

  MeshTrackBinding get binding => MeshTrackBinding(
        service: svc,
        ops: ops,
        units: units,
        here: () => here,
        hereAccuracyM: () => accuracy,
        selfName: () => 'Andy',
        chat: () => chat,
        now: () => clock,
        onCentre: (_, lat, lon) => centred.add((lat, lon)),
      );

  /// A friend's MT1 position heard on [channelId] ([dLat] north of me).
  void hear(int channelId, String name, {double dLat = 0.03, double dLon = 0.03, int? speed, int pathLen = 0, double snr = 6.5}) {
    final h = here!;
    final code = _code(h.lat + dLat, h.lon + dLon);
    svc.onChannelText(MtInboundText(
      channelId: channelId,
      text: '$name: MT1 @$code${speed == null ? '' : ' s$speed c45'}',
      receivedAt: clock,
      snr: snr,
      pathLen: pathLen,
    ));
  }

  static String _code(double lat, double lon) => PlusCode.encode(lat, lon);

  /// A fresh, good GPS fix where I am.
  void fix({double? lat, double? lon}) =>
      svc.onFix(MtFix(lat: lat ?? here!.lat, lon: lon ?? here!.lon, accuracyM: 5, speedMps: 20, courseDeg: 90, at: clock));

  /// The scope sits above the app, like AppScope in the real app, so pushed pages see it too.
  Widget host(Widget child, {Brightness brightness = Brightness.dark}) => MeshTrackScope(
        binding: binding,
        child: MaterialApp(
          theme: meshSonarTheme(brightness),
          darkTheme: meshSonarTheme(Brightness.dark),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          home: child,
        ),
      );

  /// Ends the test: stops the service's timers.
  Future<void> done(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 70)); // toasts, Undo windows, "Asked" and the send pump run out
    await svc.dispose();
    await tester.pump();
  }
}

/// A screen with a button that opens [open] (sheets need a Navigator and a context below the scope).
class Opener extends StatelessWidget {
  final Future<void> Function(BuildContext context) open;
  const Opener(this.open, {super.key});
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        child: Center(child: CupertinoButton(key: const Key('open'), onPressed: () => open(context), child: const Text('Open'))),
      );
}

/// iPhone 17 Pro (402 x 874 pt, 3x), or another size; [scale] = text size.
void phone(WidgetTester tester, {double w = 402, double h = 874, double scale = 1.0}) {
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// iPad Pro 11 landscape (1194 x 834 pt, 2x).
void ipad(WidgetTester tester) {
  tester.view.physicalSize = const Size(1194 * 2, 834 * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
