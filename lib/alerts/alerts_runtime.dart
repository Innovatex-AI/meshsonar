// AlertsRuntime: builds and connects the pieces of M3 "Alerts" and is the one object the UI looks up
// (AlertsHost.runtime). Nothing here is created at launch in a way that asks the person anything: the notification plugin
// is initialised without a permission prompt.
//
//   main.dart:         final alerts = await AlertsRuntime.createReal(); AlertsHost.runtime.value = alerts; alerts.bindApp(state);
//   chat wiring (2A):  AlertsHost.runtime.value?.bindChat(chatService);   // once the ChatService exists
//
// What bindApp does: remembers the Bluetooth radio on connect and forgets it on a deliberate disconnect; logs the link's
// lifecycle for the S1 test matrix; hooks the radio's drain count to the queue warning; arms/disarms the iOS wake keeper
// (experiment) and the Android foreground service; reconnects to the remembered radio shortly after launch.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_state.dart';
import '../chat/chat_service.dart';
import '../platform/background_link_service.dart';
import '../platform/ios_wake_keeper.dart';
import '../platform/local_notifications.dart';
import '../platform/local_notifications_plugin.dart';
import '../radio/radio_api.dart';
import '../radio/radio_session_impl.dart';
import 'alert_coordinator.dart';
import 'alert_prefs.dart';
import 'ble_lifecycle_log.dart';
import 'last_radio_store.dart';
import 'launch_reconnect.dart';
import 'radio_queue_watch.dart';

class AlertsHost {
  AlertsHost._();

  /// An inert runtime (memory only, no notifications) until main.dart replaces it with the real one, so screens and widget
  /// tests always have something to show. Screens still cope with null.
  static final ValueNotifier<AlertsRuntime?> runtime = ValueNotifier<AlertsRuntime?>(AlertsRuntime.inert());
}

class AlertsRuntime with WidgetsBindingObserver {
  final AlertPrefs prefs;
  final AlertCoordinator coordinator;
  final BleLifecycleLog log;
  final RadioQueueWatch queue;
  final LastRadioStore lastRadio;
  final IosWakeKeeper keeper;
  final BackgroundLinkService backgroundLink;

  /// Set by [bindApp].
  LaunchReconnect? reconnect;

  AlertsRuntime({
    required this.prefs,
    required this.coordinator,
    required this.log,
    required this.queue,
    required this.lastRadio,
    this.keeper = const NoWakeKeeper(),
    this.backgroundLink = const NoBackgroundLinkService(),
  });

  AppState? _app;
  StreamSubscription<LinkRadioSession?>? _sessions;
  StreamSubscription<dynamic>? _inbound;
  StreamSubscription<dynamic>? _links;
  bool _wasConnected = false;
  bool _observing = false;

  /// Memory-only runtime with no real notifications. The default of [AlertsHost.runtime].
  factory AlertsRuntime.inert() {
    final prefs = AlertPrefs();
    return AlertsRuntime(
      prefs: prefs,
      coordinator: AlertCoordinator(notifications: const UnavailableLocalNotifications(), prefs: prefs),
      log: BleLifecycleLog(),
      queue: RadioQueueWatch(),
      lastRadio: MemoryLastRadioStore(),
    );
  }

  /// Real objects for the app. Files live next to the other app data.
  static Future<AlertsRuntime> createReal() async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final root = Directory(p.join(base.path, 'meshsonar'));
    await root.create(recursive: true);
    final prefs = AlertPrefs(File(p.join(root.path, 'alert_prefs.json')));
    await prefs.load();
    final log = BleLifecycleLog(file: File(p.join(root.path, 'ble_lifecycle.log')));
    await log.load();
    final notifications = PluginLocalNotifications();
    final rt = AlertsRuntime(
      prefs: prefs,
      coordinator: AlertCoordinator(notifications: notifications, prefs: prefs),
      log: log,
      queue: RadioQueueWatch(),
      lastRadio: FileLastRadioStore(File(p.join(root.path, 'last_radio.json'))),
      keeper: Platform.isIOS ? MethodChannelIosWakeKeeper() : const NoWakeKeeper(),
      backgroundLink: Platform.isAndroid ? AndroidBackgroundLinkService() : const NoBackgroundLinkService(),
    );
    await rt.start();
    return rt;
  }

  /// Initialises the notification plugin (no prompt) and starts logging lifecycle changes.
  Future<void> start() async {
    // A relaunch by the system happens with the app NOT in front: the first lines then say bg, which is how the test matrix
    // tells "started by iOS" from "opened by the person".
    AppLifecycleState? life;
    try {
      life = WidgetsBinding.instance.lifecycleState;
    } catch (_) {}
    final fg = life == null || life == AppLifecycleState.resumed;
    log.setForeground(fg);
    coordinator.setForeground(fg);
    log.add('launch', 'process started, lifecycle=${life?.name ?? 'unknown'}');
    await coordinator.init();
    if (!_observing) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (_) {}
    }
    if (coordinator.pendingOpen.value != null) log.add('notify', 'app launched by a notification tap');
    final report = await keeper.report();
    if (report.launchedByRestore) log.add('keeper', 'this process was started by iOS state restoration');
    for (final l in report.lines) {
      log.add('keeper', l);
    }
    if (report.lines.isNotEmpty) await keeper.clearReport();
  }

  void bindChat(ChatService chat) => coordinator.attachChat(chat);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    log.setForeground(fg);
    coordinator.setForeground(fg);
    log.add('lifecycle', state.name);
    if (fg) unawaited(reconnect?.onForeground());
  }

  /// Connects the pieces to the app. Call once after `state.init()` started.
  void bindApp(AppState app) {
    _app = app;
    app.onRadioConnected = _onConnected;
    app.onRadioReleased = _onReleased;
    app.addListener(_onApp);
    _sessions = app.radioSessions.sessions.listen(_onSession);
    _links = app.radioSessions.linkStates.listen((s) => log.add('link', s.name));
    reconnect = LaunchReconnect(
      store: lastRadio,
      connect: (d) => app.connect(d, RadioKind.bluetooth),
      isConnected: () => app.connected,
      blocked: () => app.driving || app.connecting || app.reconnecting,
      log: log,
    );
  }

  /// Call right after `AppState.init()`: tries the remembered radio (first try after one second, so the Bluetooth stack has
  /// powered on).
  void startLaunchReconnect() => unawaited(reconnect?.run(reason: 'launch'));

  void _onApp() {
    final c = _app?.connected ?? false;
    if (c == _wasConnected) return;
    _wasConnected = c;
    if (!c) log.add('link', 'app sees the radio gone');
  }

  void _onConnected(RadioDevice device, RadioKind kind, SelfInfo info) {
    if (kind != RadioKind.bluetooth) return;
    log.add('connect', 'connected to "${info.name}"');
    unawaited(lastRadio.save(LastRadio(device.id, info.name, publicKeyHex: info.publicKey)));
    if (prefs.iosWakeKeeper) unawaited(keeper.arm(device.id));
    if (prefs.enabled && backgroundLink.supported) unawaited(backgroundLink.start(radioName: info.name));
  }

  void _onReleased() {
    log.add('connect', 'released by the person (no automatic reconnect)');
    reconnect?.cancel();
    unawaited(lastRadio.clear());
    unawaited(keeper.disarm());
    unawaited(backgroundLink.stop());
  }

  void _onSession(LinkRadioSession? s) {
    unawaited(_inbound?.cancel());
    _inbound = null;
    if (s == null) return;
    s.onQueueDrained = (n) {
      log.add('drain', '$n message frame${n == 1 ? '' : 's'} taken from the radio queue');
      queue.onDrained(n);
    };
    _inbound = s.inbound.listen((_) => log.add('inbound', 'message persisted'));
  }

  /// The Diagnostics switch for the iOS wake keeper experiment.
  Future<void> setIosWakeKeeper(bool on) async {
    await prefs.setIosWakeKeeper(on);
    final id = (await lastRadio.load())?.id;
    if (on && id != null && (_app?.connected ?? false)) {
      await keeper.arm(id);
    } else if (!on) {
      await keeper.disarm();
    }
    log.add('keeper', on ? 'experiment switched on' : 'experiment switched off');
  }

  void dispose() {
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    _app
      ?..removeListener(_onApp)
      ..onRadioConnected = null
      ..onRadioReleased = null;
    unawaited(_sessions?.cancel());
    unawaited(_links?.cancel());
    unawaited(_inbound?.cancel());
    coordinator.dispose();
  }
}
