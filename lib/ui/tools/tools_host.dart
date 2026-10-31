// What the Tools screens need from the rest of the app, behind one small interface. In the app it is backed by AppState
// ([AppStateToolsHost]); widget tests put a fake in a [ToolsHostScope] so a screen is tested with a real RadioTools over the
// simulated radio and none of the app's network, storage or drive machinery.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../chat/models.dart' show Channel;
import '../../core/api.dart' show RadioPreset;
import '../../radio/crypto.dart';
import '../../radio/session.dart' show LinkState;
import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/rx_log.dart' show KnownChannel;
import '../../radio/tools/trace_tool.dart';
import '../app.dart';
import '../connect_screen.dart';

abstract class ToolsHost implements Listenable {
  /// The connected radio's Tools; null when there is no radio, or the link cannot run them.
  RadioTools? get tools;

  /// State of the link to the radio (for "reconnecting" and "handed over" wording).
  LinkState get linkState;

  /// The radio's name for headings, null when unknown.
  String? get radioName;

  /// A drive is being recorded (a radio parameter change would split it).
  bool get driveRecording;

  /// Stops the drive and saves it.
  Future<void> stopDrive();

  /// The viewed region's suggested radio preset (null when none or not loaded), the region's name, its website address.
  RadioPreset? get regionPreset;
  String? get regionName;
  Uri? get regionSite;

  /// Region scope names to test scoped adverts against ("#cmh").
  List<String> get scopeNames;

  /// Channels the person has joined (names and secrets), for labelling channel packets in the Rx log.
  Future<List<KnownChannel>> knownChannels();

  /// The phone's position now, after asking permission; null when it is denied or unavailable.
  Future<({double lat, double lon})?> phonePosition();

  /// The last position this app knows for the phone (no new request), for distances.
  ({double lat, double lon})? get lastPosition;

  Future<void> openUrl(Uri url);

  /// Opens the screen that connects a radio.
  void openConnect(BuildContext context);
}

class ToolsHostScope extends InheritedWidget {
  final ToolsHost host;
  const ToolsHostScope({super.key, required this.host, required super.child});

  /// The host above, or the AppState-backed one when only an AppScope is above.
  static ToolsHost of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<ToolsHostScope>();
    if (s != null) return s.host;
    return AppStateToolsHost.of(AppScope.of(context));
  }

  @override
  bool updateShouldNotify(ToolsHostScope old) => host != old.host;
}

/// ToolsHost over AppState. One per AppState (so the Tools keep their state while screens come and go).
class AppStateToolsHost implements ToolsHost {
  final AppState s;
  AppStateToolsHost._(this.s);

  static final Expando<AppStateToolsHost> _hosts = Expando();
  static final Expando<TraceStore> _traceStores = Expando();

  static AppStateToolsHost of(AppState s) => _hosts[s] ??= AppStateToolsHost._(s);

  @override
  void addListener(VoidCallback listener) => s.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => s.removeListener(listener);

  /// Saved traces live next to the app's other small preferences; memory only when the app has no such folder (tests).
  TraceStore _traceStore() {
    final existing = _traceStores[s];
    if (existing != null) return existing;
    final dir = s.services.uiPrefsFile?.parent;
    TraceStore store = TraceStore();
    if (dir != null) {
      final f = File('${dir.path}${Platform.pathSeparator}saved_traces.json');
      store = _loadTraceStoreSync(f);
    }
    return _traceStores[s] = store;
  }

  static TraceStore _loadTraceStoreSync(File f) => FileTraceStore.openSync(f);

  @override
  RadioTools? get tools {
    final session = s.radioSession;
    if (session == null || !session.isConnected) return null;
    session.traceStore ??= _traceStore();
    session.pingBusy ??= () => s.pinging;
    return session.tools;
  }

  @override
  LinkState get linkState => s.radioSessions.state;
  @override
  String? get radioName => s.selfInfo?.name;
  @override
  bool get driveRecording => s.driving;
  @override
  Future<void> stopDrive() => s.stopDrive();
  @override
  RadioPreset? get regionPreset => s.viewingPreset;
  @override
  String? get regionName => s.viewingRegion?.name;
  @override
  Uri? get regionSite {
    final u = s.viewingRegion?.url;
    return u == null ? null : Uri.tryParse(u);
  }

  @override
  List<String> get scopeNames {
    final slug = s.viewingRegion?.slug;
    return [if (slug != null && slug.isNotEmpty) '#${slug.toLowerCase()}'];
  }

  @override
  Future<List<KnownChannel>> knownChannels() async {
    final out = <KnownChannel>[];
    final seen = <String>{};
    void add(String name, List<int> secret) {
      if (secret.length < 16) return;
      final key = toHex(secret.sublist(0, 16));
      if (seen.add(key)) out.add(KnownChannel(name, Uint8List.fromList(secret.sublist(0, 16))));
    }

    // The chat store's channels (secrets in the Keychain), then whatever the radio itself holds.
    try {
      final open = s.services.openChatStore;
      final radioId = s.radioSession?.selfPublicKey;
      if (open != null && radioId != null) {
        final store = await open();
        for (final Channel c in store.channels.list(radioId)) {
          final secret = await store.channels.secretOf(c);
          if (secret != null) add(c.name, secret);
        }
      }
    } catch (_) {}
    try {
      for (final c in await (s.radioSession?.listChannels() ?? Future.value(const []))) {
        if (!c.isEmpty) add(c.name, c.secret);
      }
    } catch (_) {}
    return out;
  }

  @override
  Future<({double lat, double lon})?> phonePosition() async {
    try {
      final loc = s.activeLocation;
      if (!await loc.ensurePermission()) return null;
      final fix = await loc.current();
      return fix == null ? null : (lat: fix.lat, lon: fix.lon);
    } catch (_) {
      return null;
    }
  }

  @override
  ({double lat, double lon})? get lastPosition {
    final f = s.status.lastFix;
    return f == null ? null : (lat: f.lat, lon: f.lon);
  }

  @override
  Future<void> openUrl(Uri url) => s.services.openUrl(url);

  @override
  void openConnect(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
}
