// MeshSonar radio > Owner link (brief C.9): whether this radio names one of the person's radios as its owner; "Link to my
// MeshSonar account" lists the radios this app already knows the person proved (their claims), never this radio itself, and
// sends `POST /owner`; "Remove link" (`POST /owner/clear`). MeshSonar then shows the person an offer under More > Observers.
// Only offered while the server advertises radio proof (`capabilities.radioProof`): [msBOwnerAvailable].
import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../../core/node_claim.dart';
import '../app.dart' show AppScope;
import 'ms_b_common.dart';

/// A radio of the person the radio can be linked to.
class MsBKnownRadio {
  /// Lower-case 64 hex.
  final String key;
  final String label;

  /// How it was proven, in words (optional).
  final String? detail;
  const MsBKnownRadio({required this.key, required this.label, this.detail});
}

/// True when the owner link may be offered: the server advertises radio proof. Without an AppScope (isolated tests) false.
bool msBOwnerAvailable(BuildContext context) => AppScope.maybeOf(context)?.radioProofOffered ?? false;

/// The person's proven radios the app knows (their active claims), without [exclude] (this radio's own key).
List<MsBKnownRadio> msBKnownRadios(BuildContext context, {Set<String> exclude = const {}}) {
  final s = AppScope.maybeOf(context);
  if (s == null || !s.nodeClaimsEnabled) return const [];
  final ex = {for (final k in exclude) k.toLowerCase()};
  return [
    for (final NodeClaim c in s.claims.active)
      if (!ex.contains(c.pubkey.toLowerCase()) && isPublicKeyHex(c.pubkey.toLowerCase()))
        MsBKnownRadio(key: c.pubkey.toLowerCase(), label: c.label, detail: 'Key ${c.pubkey.substring(0, 8)}'),
  ];
}

class MsBOwnerScreen extends StatefulWidget {
  final MsRadioController c;

  /// Tests and the screenshot build: override the server capability and the person's radios. Null reads the app state.
  final bool? radioProofOffered;
  final List<MsBKnownRadio>? knownRadios;
  const MsBOwnerScreen({super.key, required this.c, this.radioProofOffered, this.knownRadios});
  @override
  State<MsBOwnerScreen> createState() => _MsBOwnerScreenState();
}

class _MsBOwnerScreenState extends State<MsBOwnerScreen> {
  MsOwner? _owner;
  String? _error, _note;
  bool _loading = true, _acting = false, _started = false;

  MsRadioApi? get _api => widget.c.api;

  bool _available(BuildContext context) => widget.radioProofOffered ?? msBOwnerAvailable(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!_available(context)) return; // flag off: no request at all
    _load();
    final s = AppScope.maybeOf(context);
    if (widget.knownRadios == null && s != null && s.nodeClaimsEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => s.claims.refresh());
    }
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) return;
    MsOwner? o;
    final err = await msBTry(() async => o = await api.owner());
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (o != null) _owner = o;
      if (err != null) _error = err;
    });
  }

  Future<void> _act(Future<MsOwner> Function(MsRadioApi api) job, String note) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _acting = true;
      _error = null;
      _note = null;
    });
    MsOwner? o;
    final err = await msBTry(() async => o = await job(api));
    if (!mounted) return;
    setState(() {
      _acting = false;
      _error = err;
      if (o != null) {
        _owner = o;
        _note = note;
      }
    });
  }

  List<MsBKnownRadio> _radios(BuildContext context) {
    final exclude = {widget.c.radioKey, if (_owner?.selfKey != null) _owner!.selfKey!};
    final given = widget.knownRadios;
    if (given != null) return [for (final r in given) if (!exclude.contains(r.key.toLowerCase())) r];
    return msBKnownRadios(context, exclude: exclude);
  }

  Future<void> _link() async {
    final radios = _radios(context);
    final picked = await showModalBottomSheet<MsBKnownRadio>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final t = Theme.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
            child: ListView(key: const Key('msb-owner-pick'), shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Which of your radios is the owner?', style: t.textTheme.titleMedium),
              ),
              if (radios.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: NoteCard('MeshSonar does not know any of your radios yet. Prove your own radio first: connect it and claim it '
                      'under More > Claimed radios.', key: Key('msb-owner-none')),
                ),
              for (final r in radios)
                ListTile(
                  key: Key('msb-owner-radio-${r.key.substring(0, 8)}'),
                  minTileHeight: 48,
                  leading: const Icon(Icons.settings_input_antenna),
                  title: Text(r.label),
                  subtitle: r.detail == null ? null : Text(r.detail!),
                  onTap: () => Navigator.pop(ctx, r),
                ),
            ]),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    await _act((api) => api.setOwner(ownerKey: picked.key, name: picked.label), 'Linked to ${picked.label}.');
  }

  Future<void> _remove() async {
    final ok = await msBConfirm(context,
        key: 'owner-clear',
        title: 'Remove the link?',
        body: 'This radio stops naming an owner. Its sharing reconnects at once; nothing else changes.',
        confirmLabel: 'Remove link',
        destructive: true);
    if (!ok || !mounted) return;
    await _act((api) => api.clearOwner(), 'The link was removed.');
  }

  List<Widget> _rows(BuildContext context) {
    final o = _owner;
    final t = Theme.of(context);
    if (_loading && o == null) return [const MsBBlock(child: Center(child: CircularProgressIndicator()))];
    final linkedTo = o == null || !o.linked
        ? null
        : (o.ownerName ?? (o.ownerKey == null ? 'a radio' : 'radio ${o.ownerKey!.substring(0, 8)}'));
    return [
      MsBError(_error),
      if (_note != null) MsBBlock(child: NoteCard(_note!, key: const Key('msb-owner-note'), kind: NoteKind.good)),
      if (o != null) ...[
        InsetGroup(header: 'MeshSonar account', groupKey: const Key('msb-owner-state'), rows: [
          InsetRow(title: 'Linked', value: linkedTo == null ? 'Not linked' : 'Linked to $linkedTo', chevron: false),
          if (o.linked && o.ownerKey != null) InsetRow(title: 'Owner key', value: o.ownerKey!.substring(0, 8), chevron: false),
          if (o.share != null) InsetRow(title: 'Sharing with MeshSonar', value: o.share! ? 'On' : 'Off', chevron: false),
        ]),
        MsBBlock(
          child: Text(
            'Linking names one of your own radios as this radio\'s owner. MeshSonar then shows you an offer to add this radio as '
            'your observer, under More > Observers. Nothing changes until you accept it there.',
            key: const Key('msb-owner-explain'),
            style: t.textTheme.bodyMedium,
          ),
        ),
        if (o.share == false)
          const MsBBlock(child: NoteCard('Sharing is off on this radio, so MeshSonar will not see the link until it is on.', key: Key('msb-owner-share-off'))),
        MsBButtons([
          FilledButton.icon(
            key: const Key('msb-owner-link'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _acting ? null : _link,
            icon: const Icon(Icons.link),
            label: Text(o.linked ? 'Link to another of my radios' : 'Link to my MeshSonar account'),
          ),
          if (o.linked)
            OutlinedButton(
              key: const Key('msb-owner-clear'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: t.colorScheme.error),
              onPressed: _acting ? null : _remove,
              child: const Text('Remove link'),
            ),
        ]),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_available(context)) return const SizedBox.shrink(key: Key('msb-owner-hidden'));
    return MsBPage(c: widget.c, id: 'owner', title: 'Owner link', onRefresh: _load, builder: _rows);
  }
}
