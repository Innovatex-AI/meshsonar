// RadioTools: the Tools of one radio session, created together so they share one radio, one TxArbiter (the airtime ledger)
// and one lifetime. Everything the UI shows lives here, so a screen that is left and opened again finds its results.
// Pure Dart.
import 'dart:async';

import '../tx_arbiter.dart';
import 'advert_tool.dart';
import 'ask_location.dart';
import 'device_settings.dart';
import 'discover_tool.dart';
import 'noise_monitor.dart';
import 'ping_tool.dart';
import 'radio_setup.dart';
import 'rx_log.dart';
import 'telemetry_tool.dart';
import 'tools_radio.dart';
import 'trace_tool.dart';

class RadioTools {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final TraceTool trace;
  final PingTool ping;
  final DiscoverTool discover;
  final AdvertTool adverts;
  final RxLog rxLog;
  final NoiseMonitor noise;
  final TelemetryTool telemetry;
  final RadioSetupTool setup;

  /// Ask for location (MeshTrack MT-13) on top of [telemetry]: per-contact state and the once-per-30-s limit.
  final AskLocationHub askLocation;

  /// Device settings (Chat plan 4.14): the verified writes of the Device settings screen.
  final DeviceSettingsTool device;

  RadioTools._(this.radio, this.arbiter, this.trace, this.ping, this.discover, this.adverts, this.rxLog, this.noise, this.telemetry, this.setup, this.device, this.askLocation);

  /// [pingBusy]: true while a wardrive ping is in flight (the noise monitor then skips its read). [traceStore]: where saved
  /// traces live (null = memory).
  factory RadioTools(ToolsRadio radio, TxArbiter arbiter,
      {DateTime Function()? clock, bool Function()? pingBusy, TraceStore? traceStore}) {
    final trace = TraceTool(radio, arbiter, clock: clock, store: traceStore);
    final telemetry = TelemetryTool(radio, arbiter, clock: clock);
    return RadioTools._(
      radio,
      arbiter,
      trace,
      PingTool(radio, arbiter, trace, clock: clock),
      DiscoverTool(radio, arbiter, clock: clock),
      AdvertTool(radio, arbiter, clock: clock),
      RxLog(clock: clock),
      NoiseMonitor(radio, arbiter, clock: clock, busy: pingBusy),
      telemetry,
      RadioSetupTool(radio),
      DeviceSettingsTool(radio, clock: clock),
      AskLocationHub(telemetry, clock: clock),
    );
  }

  bool get connected => radio.isConnected;

  /// Delete my data: every telemetry answer and every Ask for location answer kept in memory (positions included).
  void forgetPositions() {
    askLocation.clear();
    telemetry.clearHistory();
  }

  /// Starts the passive collectors (RX log, adverts). They read what the radio already pushes; they send nothing.
  void startListening() {
    if (!rxLog.listening) rxLog.listen(radio.rxPackets);
    adverts.start();
  }

  Future<void> dispose() async {
    await rxLog.dispose();
    await adverts.dispose();
    noise.dispose();
    trace.dispose();
    discover.dispose();
    askLocation.dispose();
    telemetry.dispose();
    setup.dispose();
    device.dispose();
  }
}
