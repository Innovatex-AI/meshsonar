// "Decode a packet" (AZ-3.2), in Network > Packets: paste hex, decode it on the phone (no network needed), and see the
// same fields and byte inspector as a packet detail. `POST /v1/decode` is used only when the phone's decoder cannot
// handle the bytes (an unknown type, RAW_CUSTOM, or bytes it does not accept), or when the person asks the server to
// try its hashtag list on a channel packet the phone has no key for. Nothing pasted is stored.
// Website twin: `/tools/decode`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/network_request.dart';
import '../../../core/v1/local_decoder.dart';
import '../../../core/v1/packets_api.dart';
import '../../design/app_type.dart';
import '../../theme.dart';
import 'packet_context.dart';
import 'packet_detail_body.dart';
import 'packet_detail_screen.dart';
import 'packet_ui.dart';

class DecodePacketScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;
  final String? initialHex;

  /// Test seam.
  final PacketsApi? api;
  const DecodePacketScreen({super.key, required this.baseUrl, this.regionSlug, this.initialHex, this.api});

  @override
  State<DecodePacketScreen> createState() => _DecodePacketScreenState();
}

class _DecodePacketScreenState extends State<DecodePacketScreen> {
  late final TextEditingController _hex = TextEditingController(text: widget.initialHex ?? '');
  late final PacketsApi _api = widget.api ?? packetsApiFactory(widget.baseUrl);
  PacketDetail? _result;
  bool _known = false;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Future<void> _decode({bool askServer = false}) async {
    FocusScope.of(context).unfocus();
    final bytes = parseHexInput(_hex.text);
    setState(() {
      _error = null;
      _result = null;
      _known = false;
    });
    if (bytes == null) {
      setState(() => _error = 'That is not hex: paste the packet bytes as hex digits (spaces are fine).');
      return;
    }
    final keys = await packetHashtagKeys(context);
    if (!mounted) return;
    PacketDetail? local;
    String? localProblem;
    try {
      local = decodePacketLocally(bytes, hashtagKeys: keys);
    } on LocalDecodeError catch (e) {
      localProblem = e.message;
    }
    final needServer = askServer || local == null || !localDecoderKnowsType(local.type);
    if (!needServer) {
      setState(() => _result = local);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _api.decode(_hex.text.replaceAll(RegExp(r'\s'), ''));
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _result = local;
          _error = local == null ? '$localProblem The server decoder is not available yet.' : null;
        });
      } else {
        setState(() {
          _result = r.detail;
          _known = r.known;
        });
      }
    } on V1Error catch (e) {
      if (!mounted) return;
      setState(() {
        _result = local;
        _error = local == null ? '$localProblem The server could not decode it either: ${e.message}' : 'The server did not answer: ${e.message}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _result;
    final noKey = r != null && r.decodedFields['decodeStatus'] == 'no_key' && r.source == PacketSource.pasted;
    return Scaffold(
      key: const Key('decode-packet-screen'),
      appBar: AppBar(title: const Text('Decode a packet')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              key: const Key('decode-hex'),
              controller: _hex,
              minLines: 2,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
              style: AppType.mono.copyWith(fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Paste the packet as hex, e.g. 1504e2a73c4f…',
                errorText: _error,
                errorMaxLines: 4,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.s),
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              FilledButton.icon(key: const Key('decode-run'), onPressed: _busy ? null : _decode, icon: const Icon(Icons.manage_search), label: const Text('Decode')),
              OutlinedButton.icon(
                key: const Key('decode-paste'),
                icon: const Icon(Icons.content_paste),
                label: const Text('Paste'),
                onPressed: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  if (d?.text != null) _hex.text = d!.text!;
                },
              ),
              if (noKey)
                OutlinedButton(
                  key: const Key('decode-ask-server'),
                  onPressed: _busy ? null : () => _decode(askServer: true),
                  child: const Text("Try the server's hashtag list"),
                ),
              if (_known && r != null)
                TextButton(
                  key: const Key('decode-open-known'),
                  onPressed: () => openNetworkPacket(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, hash: r.hash),
                  child: const Text('The network heard this: open it'),
                ),
            ]),
            if (_busy) const LinearProgressIndicator(key: Key('decode-busy')),
            Text('Decoded on this phone; nothing you paste is stored or sent unless the phone cannot read the type.', style: t.textTheme.bodySmall),
          ]),
        ),
        Expanded(
          child: r == null
              ? ListView(padding: const EdgeInsets.all(Gap.l), children: [WebTwinLine(Uri.https(networkApexHost, '/tools/decode'))])
              : PacketDetailBody(key: ValueKey('decode-${r.hash}-${r.source.name}'), d: r, web: Uri.https(networkApexHost, '/tools/decode')),
        ),
      ]),
    );
  }
}
