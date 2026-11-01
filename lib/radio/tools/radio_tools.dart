// RadioTools: the Tools of one radio session, created together so they share one radio, one TxArbiter (the airtime ledger)
// and one lifetime. Everything the UI shows lives here, so a screen that is left and opened again finds its results.
// Pure Dart.
import 'dart:async';

import '../tx_arbiter.dart';
import 'advert_tool.dart';
import 'discover_tool.dart';
import 'noise_monitor.dart';
import 'radio_setup.dart';
import 'rx_log.dart';
import 'telemetry_tool.dart';
import 'tools_radio.dart';
import 'trace_tool.dart';

class RadioTools {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final TraceTool trace;
  final DiscoverTool discover;
  final AdvertTool adverts;
  final RxLog rxLog;
  final NoiseMonitor noise;
  final TelemetryTool telemetry;
  final RadioSetupTool setup;

  RadioTools._(this.radio, this.arbiter, this.trace, this.discover, this.adverts, this.rxLog, this.noise, this.telemetry, this.setup);

  /// [pingBusy]: true while a wardrive ping is in flight (the noise monitor then skips its read). [traceStore]: where saved
  /// traces live (null = memory).
  factory RadioTools(ToolsRadio radio, TxArbiter arbiter,
      {DateTime Function()? clock, bool Function()? pingBusy, TraceStore? traceStore}) {
    return RadioTools._(
      radio,
      arbiter,
      TraceTool(radio, arbiter, clock: clock, store: traceStore),
      DiscoverTool(radio, arbiter, clock: clock),
      AdvertTool(radio, arbiter, clock: clock),
      RxLog(clock: clock),
      NoiseMonitor(radio, arbiter, clock: clock, busy: pingBusy),
      TelemetryTool(radio, arbiter, clock: clock),
      RadioSetupTool(radio),
    );
  }

  bool get connected => radio.isConnected;

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
    telemetry.dispose();
    setup.dispose();
  }
}
