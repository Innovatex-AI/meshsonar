// The one entry point the screens use for the connected MeshSonar radio's Wi-Fi side.
//
//   final link = AppScope.of(context).radioSessions.link;          // a MeshCoreCompanionLink (a ClaimRadio)
//   final c = MsRadioController.forCaps(radioCapsOf(context), radioKey: link.selfPublicKey, sign: link.sign,
//       secrets: KeychainMsSecretKv(), browser: const BonsoirMsServiceBrowser());   // lib/platform seams
//   if (c == null) -> stock MeshCore radio: show nothing, make no request (THE stock gate).
//   await c.connect();            // discovery + /info key check + token check -> c.state.step
//   c.api!.status() ...           // every endpoint, once c.state.step is paired
//   await c.pairSigned();         // or c.pairByApproval(), c.useAddress('192.168.1.77')
//   await c.forget();             // unpair + delete the token
//   c.dispose();                  // when the radio disconnects
//
// A 401 from any call drops the stored token and moves the state to notPaired ("Pair again"). Nothing here touches the
// Bluetooth link except [sign] during signed pairing. Pure Dart.
import 'dart:async';

import 'package:http/http.dart' as http;

import '../../radio/caps.dart';
import '../person_identity.dart' show MsAppNonces;
import 'ms_api.dart';
import 'ms_discovery.dart';
import 'ms_errors.dart';
import 'ms_models.dart';
import 'ms_pairing.dart';
import 'ms_tokens.dart';

enum MsLinkStep {
  /// connect() has not run yet.
  idle,

  /// Looking for the radio on the local network.
  finding,

  /// The radio cannot be reached over Wi-Fi (the Bluetooth link is not affected).
  notOnWifi,

  /// An address answered with another radio's key; it is not used.
  wrongRadio,

  /// Found, but this app has no good token: pair.
  notPaired,

  /// Found and paired: [MsRadioController.api] works.
  paired,
}

class MsLinkState {
  final MsLinkStep step;
  final String? address;
  final MsAddressSource? source;
  final MsInfo? info;

  /// Plain English for the screen.
  final String message;
  const MsLinkState(this.step, {this.address, this.source, this.info, this.message = ''});

  bool get paired => step == MsLinkStep.paired;

  /// The chip on the Radio screen: Paired, Not paired, Not on Wi-Fi.
  String get chip => switch (step) {
        MsLinkStep.paired => 'Paired',
        MsLinkStep.notPaired => 'Not paired',
        MsLinkStep.finding || MsLinkStep.idle => 'Looking...',
        MsLinkStep.wrongRadio => 'Wrong radio',
        MsLinkStep.notOnWifi => 'Not on Wi-Fi',
      };

  @override
  String toString() => 'MsLinkState(${step.name}${address == null ? '' : ' @ $address'})';
}

class MsRadioController {
  /// The Bluetooth key of the connected radio, lower-case 64 hex.
  final String radioKey;
  final MeshSonarFw fw;
  final MsTokenStore tokens;
  final MsRadioDiscovery discovery;
  final MsSigner? sign;
  final MsAppNonces nonces;
  final String appName;
  final http.Client _client;
  final bool _ownsClient;
  final Future<void> Function(Duration d)? _wait;
  final DateTime Function()? _clock;

  /// One request at a time to this radio, shared by every API this controller makes (discovery's /info checks too).
  final MsSerialQueue queue;

  MsRadioController._({
    required this.radioKey,
    required this.fw,
    required this.tokens,
    required this.discovery,
    required this.queue,
    required http.Client client,
    required bool ownsClient,
    this.sign,
    required this.nonces,
    required this.appName,
    Future<void> Function(Duration d)? wait,
    DateTime Function()? clock,
  })  : _client = client, // ignore: prefer_initializing_formals
        _ownsClient = ownsClient, // ignore: prefer_initializing_formals
        _wait = wait, // ignore: prefer_initializing_formals
        _clock = clock; // ignore: prefer_initializing_formals

  /// THE gate: null unless [caps] says this is a MeshSonar radio and [radioKey] is a 64-hex key. With a stock MeshCore
  /// radio nothing in lib/core/msradio is constructed, so no local-network request is ever made.
  ///
  /// [sign] is the radio session's `sign` (CMD_SIGN_* over Bluetooth); [secrets] the secure storage
  /// (KeychainMsSecretKv in the app, InMemoryMsSecretKv in tests); [browser] the DNS-SD browser
  /// (BonsoirMsServiceBrowser in the app); [client] an http client (FakeMsRadio.client for tests and the simulator).
  static MsRadioController? forCaps(
    RadioCaps caps, {
    required String? radioKey,
    required MsSecretKv secrets,
    MsSigner? sign,
    http.Client? client,
    MsServiceBrowser? browser,
    MsAddressStore? addresses,
    MsAppNonces? nonces,
    String appName = 'MeshSonar iOS',
    Duration browseTimeout = const Duration(seconds: 5),
    Future<void> Function(Duration d)? wait,
    DateTime Function()? clock,
  }) {
    final fw = caps.meshSonar;
    final key = radioKey?.toLowerCase();
    if (fw == null || key == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) return null;
    final c = client ?? msRadioHttp();
    final queue = MsSerialQueue();
    return MsRadioController._(
      radioKey: key,
      fw: fw,
      tokens: MsTokenStore(secrets),
      queue: queue,
      discovery: MsRadioDiscovery(
        client: c,
        browser: browser,
        addresses: addresses ?? KvMsAddressStore(secrets),
        browseTimeout: browseTimeout,
        apiFactory: (base) => MsRadioApi(baseUrl: base, client: c, queue: queue, wait: wait),
      ),
      client: c,
      ownsClient: client == null,
      sign: sign,
      nonces: nonces ?? MsAppNonces.instance,
      appName: appName,
      wait: wait,
      clock: clock,
    );
  }

  final _states = StreamController<MsLinkState>.broadcast();
  MsLinkState _state = const MsLinkState(MsLinkStep.idle);
  MsRadioApi? _api;
  MsPairingFlow? _flow;
  bool _disposed = false;

  Stream<MsLinkState> get states => _states.stream;
  MsLinkState get state => _state;

  /// The API of the confirmed address (null until one is found). Calls that need a token work once [state] is paired.
  MsRadioApi? get api => _api;

  /// The pairing in progress (for its own state stream), if any.
  MsPairingFlow? get pairing => _flow;

  void _emit(MsLinkState s) {
    if (_disposed) return;
    _state = s;
    _states.add(s);
  }

  MsRadioApi _newApi(Uri base, {String? token}) => MsRadioApi(
        baseUrl: base,
        token: token,
        client: _client,
        queue: queue,
        wait: _wait,
        onUnauthorized: _unauthorized,
      );

  void _unauthorized() {
    unawaited(tokens.drop(radioKey));
    if (_state.step == MsLinkStep.paired || _state.step == MsLinkStep.notPaired) {
      _emit(MsLinkState(MsLinkStep.notPaired, address: _state.address, source: _state.source, info: _state.info, message: 'Pair again.'));
    }
  }

  Future<MsLinkState> _adopt(MsDiscoveryResult r) async {
    switch (r.outcome) {
      case MsDiscoveryOutcome.notOnWifi:
        _api = null;
        _emit(const MsLinkState(MsLinkStep.notOnWifi, message: 'Not on Wi-Fi'));
        return _state;
      case MsDiscoveryOutcome.wrongRadio:
        _api = null;
        _emit(MsLinkState(MsLinkStep.wrongRadio, address: r.address, info: r.info, message: 'This is not the radio you are connected to.'));
        return _state;
      case MsDiscoveryOutcome.found:
        final token = await tokens.read(radioKey);
        final api = _newApi(MsRadioApi.baseFor(r.address!)!, token: token);
        _api = api;
        var info = r.info;
        var paired = false;
        if (token != null) {
          try {
            info = await api.info();
            paired = info.paired;
            if (!paired) {
              await tokens.drop(radioKey);
              api.token = null;
            }
          } on MsRadioError catch (e) {
            if (e.unreachable) {
              _emit(const MsLinkState(MsLinkStep.notOnWifi, message: 'Not on Wi-Fi'));
              return _state;
            }
          }
        }
        _emit(MsLinkState(paired ? MsLinkStep.paired : MsLinkStep.notPaired, address: r.address, source: r.source, info: info));
        return _state;
    }
  }

  /// Finds the radio (discovery order, [typedAddress] last) and checks the stored token.
  Future<MsLinkState> connect({String? typedAddress}) async {
    _emit(MsLinkState(MsLinkStep.finding, address: _state.address));
    return _adopt(await discovery.find(radioKey, typed: typedAddress));
  }

  /// "Enter address": uses only [address] (after the `/info` key check).
  Future<MsLinkState> useAddress(String address) async {
    _emit(MsLinkState(MsLinkStep.finding, address: address));
    return _adopt(await discovery.check(radioKey, address));
  }

  MsPairingFlow _newFlow() => _flow = MsPairingFlow(
        radioKey: radioKey,
        discovery: discovery,
        tokens: tokens,
        sign: sign,
        nonces: nonces,
        appName: appName,
        apiFactory: (base) => _newApi(base),
        wait: _wait,
        clock: _clock,
      );

  Future<MsPairState> _pair(Future<MsPairState> Function(MsPairingFlow f, String? address) run) async {
    final f = _newFlow();
    final known = _state.step == MsLinkStep.notPaired || _state.step == MsLinkStep.paired ? _state.address : null;
    final r = await run(f, known);
    if (r.paired && f.api != null) {
      _api = f.api;
      _emit(MsLinkState(MsLinkStep.paired, address: r.address, source: _state.source, info: r.info));
    } else if (r.step == MsPairStep.wrongRadio) {
      _emit(MsLinkState(MsLinkStep.wrongRadio, address: r.address, info: r.info, message: r.message));
    } else if (r.step == MsPairStep.notOnWifi) {
      _emit(const MsLinkState(MsLinkStep.notOnWifi, message: 'Not on Wi-Fi'));
    }
    return r;
  }

  /// Signed pairing (needs the Bluetooth link: [sign]). Watch [pairing]'s states for progress.
  Future<MsPairState> pairSigned() => _pair((f, a) => f.pairSigned(address: a));

  /// Approval on the radio (works without Bluetooth).
  Future<MsPairState> pairByApproval() => _pair((f, a) => f.pairByApproval(address: a));

  /// "Forget this radio": drops this app's token on the radio (best effort) and here.
  Future<void> forget() async {
    final api = _api;
    if (api != null && api.isPaired) {
      try {
        await api.unpair();
      } on MsRadioError {
        // the token is dropped here either way
      }
      api.token = null;
    }
    await tokens.drop(radioKey);
    if (_state.step == MsLinkStep.paired) {
      _emit(MsLinkState(MsLinkStep.notPaired, address: _state.address, source: _state.source, info: _state.info));
    }
  }

  /// Call when the radio disconnects or the page closes for good.
  void dispose() {
    if (_disposed) return;
    _flow?.cancel();
    _disposed = true;
    _states.close();
    if (_ownsClient) _client.close();
  }
}

/// For screens that want to show the radio's refusal text: the message of any error from [MsRadioApi].
String msErrorText(Object e) => e is MsRadioError ? e.message : 'Something went wrong talking to the radio.';
