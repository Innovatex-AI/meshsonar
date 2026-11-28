// Finding the connected MeshSonar radio on the local network (meshsonar-firmware docs/APP-INTEGRATION.md section 1
// "Over Wi-Fi", brief "Discovery order"):
//   1. the last address that worked for this radio key (MsAddressStore)
//   2. `meshsonar-<first 8 hex of the Bluetooth key>.local` (iOS resolves it with no browsing; Android usually cannot)
//   3. DNS-SD browse for `_meshsonar._tcp` whose TXT `pk` is that prefix (MsServiceBrowser; lib/platform/ms_service_browser.dart)
//   4. an address the person typed (shown on the radio's Wi-Fi screen)
// EVERY candidate is confirmed with `GET /info`: its `key` must equal the Bluetooth key (ignoring case) before the address
// is used. Another radio's address is never used (wrongRadio). Pure Dart.
import 'dart:async';

import 'package:http/http.dart' as http;

import 'ms_api.dart';
import 'ms_errors.dart';
import 'ms_models.dart';
import 'ms_tokens.dart';

/// The DNS-SD service type of the radio's app API.
const String kMsServiceType = '_meshsonar._tcp';

/// One `_meshsonar._tcp` service found on the network.
class MsFoundService {
  /// Instance name, e.g. `meshsonar-a1b2c3d4`.
  final String name;

  /// Resolved addresses (IPv4 and/or IPv6), as the platform reports them.
  final List<String> addresses;

  /// The SRV host name (`meshsonar-a1b2c3d4.local`), when the platform reports it.
  final String? hostname;
  final int port;

  /// TXT record: `v`, `api`, `fw`, `core`, `board`, `pk`.
  final Map<String, String> txt;
  const MsFoundService({required this.name, this.addresses = const [], this.hostname, this.port = 80, this.txt = const {}});

  /// The TXT `pk` (first 8 hex of the radio key), lower-cased.
  String? get keyPrefix => txt['pk']?.toLowerCase();

  /// Addresses to try, IPv4 first, then IPv6, then the host name; each with the port when it is not 80.
  List<String> get candidates {
    String withPort(String a) {
      final v6 = a.contains(':');
      if (port == 80) return v6 ? '[$a]' : a;
      return v6 ? '[$a]:$port' : '$a:$port';
    }

    final v4 = addresses.where((a) => !a.contains(':'));
    final v6 = addresses.where((a) => a.contains(':') && !a.toLowerCase().startsWith('fe80'));
    return [for (final a in v4) withPort(a), for (final a in v6) withPort(a), if (hostname != null && hostname!.isNotEmpty) withPort(_trimDot(hostname!))];
  }

  static String _trimDot(String h) => h.endsWith('.') ? h.substring(0, h.length - 1) : h;
}

/// The DNS-SD seam: the real browser (Bonjour / Android NSD via bonsoir) lives in lib/platform; tests use a fake.
abstract interface class MsServiceBrowser {
  /// Browses [type] for at most [timeout] and returns the services found and resolved.
  Future<List<MsFoundService>> browse(String type, {Duration timeout});
}

/// A browser that finds nothing (platforms without DNS-SD, and the default).
class NoMsServiceBrowser implements MsServiceBrowser {
  const NoMsServiceBrowser();
  @override
  Future<List<MsFoundService>> browse(String type, {Duration timeout = Duration.zero}) async => const [];
}

/// Which discovery step gave the address.
enum MsAddressSource { lastGood, mdnsHost, browse, typed }

enum MsDiscoveryOutcome {
  /// [MsDiscoveryResult.address] answers `/info` with the Bluetooth key.
  found,

  /// An address answered, but with another radio's key. That address is not used.
  wrongRadio,

  /// Nothing answered: the phone is not on the radio's Wi-Fi, the web console is Off, or the radio is off.
  notOnWifi,
}

class MsDiscoveryResult {
  final MsDiscoveryOutcome outcome;
  final String? address;
  final MsAddressSource? source;
  final MsInfo? info;

  /// wrongRadio: the key the other radio gave (lower-case), for "This is not the radio you are connected to".
  final String? otherKey;
  const MsDiscoveryResult(this.outcome, {this.address, this.source, this.info, this.otherKey});

  bool get found => outcome == MsDiscoveryOutcome.found;
}

/// `meshsonar-<first 8 hex, lower>.local` for [radioKey].
String msMdnsHostFor(String radioKey) => 'meshsonar-${radioKey.substring(0, 8).toLowerCase()}.local';

class MsRadioDiscovery {
  final http.Client _client;
  final MsServiceBrowser browser;
  final MsAddressStore addresses;
  final Duration browseTimeout;

  /// Timeout of each `/info` check (4 s like every call).
  final Duration infoTimeout;

  /// Makes the client used for the `/info` check of one address (tests inject one).
  final MsRadioApi Function(Uri base)? apiFactory;

  MsRadioDiscovery({
    http.Client? client,
    MsServiceBrowser? browser,
    MsAddressStore? addresses,
    this.browseTimeout = const Duration(seconds: 5),
    this.infoTimeout = const Duration(seconds: 4),
    this.apiFactory,
  })  : _client = client ?? msRadioHttp(),
        browser = browser ?? const NoMsServiceBrowser(),
        addresses = addresses ?? InMemoryMsAddressStore();

  MsRadioApi _apiFor(Uri base) => apiFactory?.call(base) ?? MsRadioApi(baseUrl: base, client: _client, timeout: infoTimeout);

  /// Checks one address: `GET /info` must answer with [radioKey]. A good address is remembered as the last good one.
  Future<MsDiscoveryResult> check(String radioKey, String address, {MsAddressSource source = MsAddressSource.typed}) async {
    final key = radioKey.toLowerCase();
    final base = MsRadioApi.baseFor(address);
    if (base == null) return const MsDiscoveryResult(MsDiscoveryOutcome.notOnWifi);
    final MsInfo info;
    try {
      info = await _apiFor(base).info();
    } on MsRadioError {
      // nothing usable answered there (no route, timeout, web console Off, not a MeshSonar radio)
      return const MsDiscoveryResult(MsDiscoveryOutcome.notOnWifi);
    }
    if (info.key == null || info.key != key) {
      return MsDiscoveryResult(MsDiscoveryOutcome.wrongRadio, address: address, source: source, info: info, otherKey: info.key);
    }
    await addresses.saveGood(key, address);
    return MsDiscoveryResult(MsDiscoveryOutcome.found, address: address, source: source, info: info);
  }

  /// Runs the discovery order for [radioKey] (the Bluetooth key, 64 hex). [typed] is tried last. The first address whose
  /// `/info` key matches wins; when none matches but some address answered with another key, the result is wrongRadio.
  Future<MsDiscoveryResult> find(String radioKey, {String? typed}) async {
    final key = radioKey.toLowerCase();
    MsDiscoveryResult? wrong;
    final tried = <String>{};

    Future<MsDiscoveryResult?> attempt(String address, MsAddressSource source) async {
      if (!tried.add(address.toLowerCase())) return null;
      final r = await check(key, address, source: source);
      if (r.found) return r;
      if (r.outcome == MsDiscoveryOutcome.wrongRadio) {
        wrong ??= r;
        if (source == MsAddressSource.lastGood) await addresses.forget(key);
      }
      return null;
    }

    // 1. last good address
    final last = await addresses.lastGood(key);
    if (last != null && last.isNotEmpty) {
      final r = await attempt(last, MsAddressSource.lastGood);
      if (r != null) return r;
    }
    // 2. the mDNS host name built from the Bluetooth key
    final r2 = await attempt(msMdnsHostFor(key), MsAddressSource.mdnsHost);
    if (r2 != null) return r2;
    // 3. DNS-SD browse, matching TXT pk
    List<MsFoundService> found;
    try {
      found = await browser.browse(kMsServiceType, timeout: browseTimeout);
    } catch (_) {
      found = const [];
    }
    final pk = key.substring(0, 8);
    for (final s in found.where((s) => s.keyPrefix == pk)) {
      for (final a in s.candidates) {
        final r = await attempt(a, MsAddressSource.browse);
        if (r != null) return r;
      }
    }
    // 4. the address the person typed
    if (typed != null && typed.trim().isNotEmpty) {
      final r = await attempt(typed.trim(), MsAddressSource.typed);
      if (r != null) return r;
    }
    return wrong ?? const MsDiscoveryResult(MsDiscoveryOutcome.notOnWifi);
  }
}
