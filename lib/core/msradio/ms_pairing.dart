// Pairing the app with the connected MeshSonar radio (meshsonar-firmware docs/APP-INTEGRATION.md section 3).
//
// Signed path (the app is connected to the radio over Bluetooth):
//   idle -> finding (discovery + GET /info key == Bluetooth key) -> starting (POST pair/start with an app nonce)
//   -> verifyingRadio (Ed25519 check of radio_sig over `meshsonar-app-hello:v1:<key>:<app_nonce>:<nonce>` with the
//      BLUETOOTH key; nothing is signed before this passes)
//   -> signing (the app builds `meshsonar-app-pair:v1:<key>:<nonce>:<app_nonce>` itself, compares it with sign_text, and
//      the radio signs it over Bluetooth through the guard person_identity.dart signablePairText)
//   -> finishing (POST pair/finish) -> paired
//   or wrongRadio / signFailed / expired / refused / rateLimited / notOnWifi / locked / failed / cancelled.
// Approval path (no Bluetooth needed): finding -> asking (POST pair/ask) -> waiting (GET pair/ask?n= every 1.5 s up to the
//   60 s expiry) -> paired / refused / locked / expired.
// The token is stored per radio key (MsTokenStore) and never logged. Pure Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;

import '../../radio/crypto.dart' show fromHex, toHex;
import '../person_identity.dart' show MsAppNonces, signablePairText;
import 'ms_api.dart';
import 'ms_discovery.dart';
import 'ms_errors.dart';
import 'ms_models.dart';
import 'ms_tokens.dart';

/// Signs [data] with the connected radio's own key over Bluetooth (ClaimRadio.sign / the radio session's sign).
typedef MsSigner = Future<Uint8List> Function(Uint8List data);

/// The text the radio signs to prove the Wi-Fi side is the same radio (all hex lower-case).
String msHelloText(String key, String appNonce, String nonce) => 'meshsonar-app-hello:v1:${key.toLowerCase()}:$appNonce:$nonce';

/// The text the app has the radio sign over Bluetooth (all hex lower-case).
String msPairText(String key, String nonce, String appNonce) => 'meshsonar-app-pair:v1:${key.toLowerCase()}:$nonce:$appNonce';

/// True when [sigHex] (128 hex) is a valid Ed25519 signature by [keyHex] (64 hex) over [message].
Future<bool> msVerifyEd25519(String keyHex, List<int> message, String sigHex) async {
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(keyHex) || !RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(sigHex)) return false;
  try {
    final pub = cr.SimplePublicKey(fromHex(keyHex.toLowerCase()), type: cr.KeyPairType.ed25519);
    return await cr.Ed25519().verify(message, signature: cr.Signature(fromHex(sigHex.toLowerCase()), publicKey: pub));
  } catch (_) {
    return false;
  }
}

enum MsPairStep {
  idle,
  finding,
  starting,
  verifyingRadio,
  signing,
  finishing,
  asking,
  waiting,
  paired,

  /// The address belongs to another radio, or the radio could not prove it is the Bluetooth radio.
  wrongRadio,

  /// The radio could not sign over Bluetooth (not connected, refused, firmware without signing).
  signFailed,

  /// The pairing nonce or the approval window ran out.
  expired,

  /// The radio refused (bad signature, another device, the person tapped No).
  refused,

  /// Too many tries: wait a minute.
  rateLimited,
  notOnWifi,

  /// The radio is locked.
  locked,
  failed,
  cancelled,
}

class MsPairState {
  final MsPairStep step;

  /// Plain English for the screen (the radio's own text when it refused).
  final String message;
  final String? address;
  final MsInfo? info;

  /// `sign` or `approve` once paired.
  final String? via;
  const MsPairState(this.step, {this.message = '', this.address, this.info, this.via});

  bool get finished => switch (step) {
        MsPairStep.idle ||
        MsPairStep.finding ||
        MsPairStep.starting ||
        MsPairStep.verifyingRadio ||
        MsPairStep.signing ||
        MsPairStep.finishing ||
        MsPairStep.asking ||
        MsPairStep.waiting =>
          false,
        _ => true,
      };

  bool get paired => step == MsPairStep.paired;

  @override
  String toString() => 'MsPairState(${step.name}${message.isEmpty ? '' : ': $message'})';
}

/// One pairing attempt at a time with the radio [radioKey] (the Bluetooth key, 64 hex).
class MsPairingFlow {
  final String radioKey;
  final MsRadioDiscovery discovery;
  final MsTokenStore tokens;

  /// Null without a Bluetooth link: only [pairByApproval] can work.
  final MsSigner? sign;
  final MsAppNonces nonces;

  /// The `app` name the radio shows ("Allow MeshSonar iOS on 192.168.1.50 ...") and lists under tokens.
  final String appName;
  final MsRadioApi Function(Uri base) apiFactory;
  final DateTime Function() _clock;
  final Future<void> Function(Duration d) _wait;
  final Duration pollEvery;

  /// The approval window (the radio's `expires_in`, at most this).
  final Duration askWindow;

  MsPairingFlow({
    required String radioKey,
    required this.discovery,
    required this.tokens,
    required this.apiFactory,
    this.sign,
    MsAppNonces? nonces,
    this.appName = 'MeshSonar iOS',
    DateTime Function()? clock,
    Future<void> Function(Duration d)? wait,
    this.pollEvery = const Duration(milliseconds: 1500),
    this.askWindow = const Duration(seconds: 60),
  })  : radioKey = radioKey.toLowerCase(),
        nonces = nonces ?? MsAppNonces.instance,
        _clock = clock ?? DateTime.now,
        _wait = wait ?? Future<void>.delayed;

  final _states = StreamController<MsPairState>.broadcast();
  MsPairState _state = const MsPairState(MsPairStep.idle);
  bool _cancelled = false;
  bool _running = false;
  MsRadioApi? _api;

  Stream<MsPairState> get states => _states.stream;
  MsPairState get state => _state;

  /// The API of the paired radio (token set) after [MsPairState.paired]; null before.
  MsRadioApi? get api => _state.paired ? _api : null;

  /// Stops at the next step (an approval poll ends at once). The radio forgets an unused challenge by itself.
  void cancel() => _cancelled = true;

  Future<void> close() => _states.close();

  MsPairState _emit(MsPairStep step, {String message = '', String? address, MsInfo? info, String? via}) {
    _state = MsPairState(step, message: message, address: address ?? _state.address, info: info ?? _state.info, via: via);
    if (!_states.isClosed) _states.add(_state);
    return _state;
  }

  MsPairState _fromError(MsRadioError e) => switch (e.kind) {
        MsErrorKind.notOnWifi || MsErrorKind.timeout => _emit(MsPairStep.notOnWifi, message: MsRadioError.defaultMessage(MsErrorKind.notOnWifi)),
        MsErrorKind.rateLimited => _emit(MsPairStep.rateLimited, message: e.message),
        MsErrorKind.expired => _emit(MsPairStep.expired, message: e.message),
        MsErrorKind.forbidden => _emit(MsPairStep.refused, message: e.message),
        MsErrorKind.locked => _emit(MsPairStep.locked, message: e.message),
        _ => _emit(MsPairStep.failed, message: e.message),
      };

  Future<MsPairState> _guarded(Future<MsPairState> Function() body) async {
    if (_running) return _state;
    _running = true;
    _cancelled = false;
    _api = null;
    try {
      return await body();
    } on MsRadioError catch (e) {
      return _fromError(e);
    } catch (_) {
      return _emit(MsPairStep.failed, message: 'Pairing did not work. Try again.');
    } finally {
      _running = false;
    }
  }

  /// finding: confirms [address] (or runs discovery) and returns the API for the confirmed address, or null after emitting
  /// the end state.
  Future<MsRadioApi?> _find(String? address) async {
    _emit(MsPairStep.finding);
    final r = address == null ? await discovery.find(radioKey) : await discovery.check(radioKey, address);
    if (_cancelled) {
      _emit(MsPairStep.cancelled);
      return null;
    }
    switch (r.outcome) {
      case MsDiscoveryOutcome.wrongRadio:
        _emit(MsPairStep.wrongRadio, message: 'This is not the radio you are connected to.', address: r.address, info: r.info);
        return null;
      case MsDiscoveryOutcome.notOnWifi:
        _emit(MsPairStep.notOnWifi, message: MsRadioError.defaultMessage(MsErrorKind.notOnWifi));
        return null;
      case MsDiscoveryOutcome.found:
        _emit(MsPairStep.finding, address: r.address, info: r.info);
        return apiFactory(MsRadioApi.baseFor(r.address!)!);
    }
  }

  bool _stop() {
    if (!_cancelled) return false;
    _emit(MsPairStep.cancelled);
    return true;
  }

  Future<MsPairState> _done(MsRadioApi api, MsPairToken t) async {
    if (t.key != null && t.key != radioKey) return _emit(MsPairStep.wrongRadio, message: 'This is not the radio you are connected to.');
    await tokens.save(radioKey, t.token);
    api.token = t.token;
    _api = api;
    return _emit(MsPairStep.paired, via: t.via);
  }

  /// Signed pairing: one tap, no tap on the radio. Needs [sign] (a Bluetooth link to this radio).
  Future<MsPairState> pairSigned({String? address}) => _guarded(() async {
        final api = await _find(address);
        if (api == null) return _state;

        _emit(MsPairStep.starting);
        final appNonce = nonces.issue();
        final start = await api.pairStart(appNonce: appNonce, app: appName);
        if (_stop()) return _state;

        _emit(MsPairStep.verifyingRadio);
        if (start.key != radioKey) return _emit(MsPairStep.wrongRadio, message: 'This is not the radio you are connected to.');
        final hello = utf8.encode(msHelloText(radioKey, appNonce, start.nonce));
        if (!await msVerifyEd25519(radioKey, hello, start.radioSig)) {
          return _emit(MsPairStep.wrongRadio, message: 'The radio on Wi-Fi could not prove it is the radio you are connected to.');
        }
        final text = msPairText(radioKey, start.nonce, appNonce);
        if (start.signText != null && start.signText!.toLowerCase() != text) {
          return _emit(MsPairStep.failed, message: 'The radio asked to sign a different text. Nothing was signed.');
        }
        if (_stop()) return _state;

        _emit(MsPairStep.signing);
        final s = sign;
        if (s == null) return _emit(MsPairStep.signFailed, message: 'Connect the radio over Bluetooth, or use Ask on the radio.');
        final bytes = Uint8List.fromList(utf8.encode(text));
        if (signablePairText(bytes, radioKey, nonces: nonces) == null) {
          return _emit(MsPairStep.failed, message: 'This pairing request is too old. Try again.');
        }
        final Uint8List sig;
        try {
          sig = await s(bytes);
        } catch (_) {
          return _emit(MsPairStep.signFailed, message: 'The radio could not sign over Bluetooth. Try again, or use Ask on the radio.');
        }
        if (sig.length != 64) return _emit(MsPairStep.signFailed, message: 'The radio sent a signature this app cannot use.');
        if (_stop()) return _state;

        _emit(MsPairStep.finishing);
        final t = await api.pairFinish(nonce: start.nonce, sigHex: toHex(sig), app: appName);
        return _done(api, t);
      });

  /// Approval on the radio: the radio asks the person to Allow this app; polled every [pollEvery] up to the expiry.
  Future<MsPairState> pairByApproval({String? address}) => _guarded(() async {
        final api = await _find(address);
        if (api == null) return _state;

        _emit(MsPairStep.asking);
        final ask = await api.pairAsk(app: appName);
        final window = Duration(seconds: ask.expiresIn) < askWindow && ask.expiresIn > 0 ? Duration(seconds: ask.expiresIn) : askWindow;
        final until = _clock().add(window);

        _emit(MsPairStep.waiting, message: 'Tap Allow on the radio.');
        while (true) {
          await _wait(pollEvery);
          if (_stop()) return _state;
          if (!_clock().isBefore(until)) return _emit(MsPairStep.expired, message: 'No answer on the radio in time. Try again.');
          final MsPairAskResult r;
          try {
            r = await api.pairAskResult(ask.n);
          } on MsRadioError catch (e) {
            // a lost poll is retried until the window ends; anything the radio says is final
            if (e.unreachable || e.kind == MsErrorKind.busy) continue;
            return _fromError(e);
          }
          switch (r.state) {
            case MsAskState.wait:
            case MsAskState.unknown:
              continue;
            case MsAskState.no:
              return _emit(MsPairStep.refused, message: 'The radio said No.');
            case MsAskState.locked:
              return _emit(MsPairStep.locked, message: 'The radio is locked. Unlock it and try again.');
            case MsAskState.yes:
              final t = r.token;
              if (t == null) return _emit(MsPairStep.failed, message: 'The radio allowed it but sent no token. Try again.');
              return _done(api, t);
          }
        }
      });
}
