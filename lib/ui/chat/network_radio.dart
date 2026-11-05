// What the Network segment needs from the connected radio, behind one small interface so widget tests run it with a fake.
// In the app it is backed by the radio session and the radio tools (adverts, discover); nothing here talks to hardware on
// its own.
import '../../app/app_state.dart';
import '../../radio/protocol.dart' show BattAndStorageFrame;
import '../../chat/chat_copy.dart';
import '../../radio/tools/advert_tool.dart' show AdvertSendStatus;
import '../../radio/tools/discover_tool.dart' show DiscoverStatus;
import '../tools/tools_host.dart' show AppStateToolsHost;

abstract class NetworkRadio {
  /// A radio that can run commands is connected.
  bool get connected;
  String? get name;
  String? get firmware;
  double? get frequencyMhz;

  /// CMD 20, or null when the radio gave no reading.
  Future<BattAndStorageFrame?> battery();

  /// Sends this radio's advert: [wide] false = zero hop (radios in direct range), true = flooded. Returns a sentence for the
  /// toast, and whether it went.
  Future<({bool ok, String message})> announce({required bool wide});

  /// One zero-hop discover request (CONTROL_DATA 55) with the tool's own limit of 4 per 2 minutes. Returns a sentence.
  Future<({bool ok, String message})> discover();
}

/// The real thing, over [AppState].
class AppNetworkRadio implements NetworkRadio {
  final AppState app;
  const AppNetworkRadio(this.app);

  @override
  bool get connected => app.radioSession?.isConnected ?? false;
  @override
  String? get name => app.radioSession?.selfInfo?.name;
  @override
  String? get firmware => app.radioSession?.selfInfo?.firmware;
  @override
  double? get frequencyMhz => app.radioSession?.selfInfo?.radio.freqMhz;

  @override
  Future<BattAndStorageFrame?> battery() async => app.radioSession?.batteryAndStorage();

  @override
  Future<({bool ok, String message})> announce({required bool wide}) async {
    final tools = AppStateToolsHost.of(app).tools;
    if (tools == null) return (ok: false, message: connectRadioFirst);
    final r = await tools.adverts.send(flood: wide);
    return (ok: r.status == AdvertSendStatus.sent, message: r.message);
  }

  @override
  Future<({bool ok, String message})> discover() async {
    final tools = AppStateToolsHost.of(app).tools;
    if (tools == null) return (ok: false, message: connectRadioFirst);
    final found = await tools.discover.scan();
    final msg = tools.discover.message;
    if (tools.discover.status != DiscoverStatus.done) return (ok: false, message: msg ?? 'The scan did not run.');
    if (found.isEmpty) return (ok: false, message: msg ?? 'Nothing answered.');
    return (ok: true, message: found.length == 1 ? '1 node answered.' : '${found.length} nodes answered.');
  }
}
