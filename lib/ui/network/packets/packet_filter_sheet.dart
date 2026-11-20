// The Packets filter sheet (AZ-3.2), built for a thumb: tall sheet, big chips, Apply / Clear pinned at the bottom.
// Every `/v1/packets` filter (type, route, observer, node or prefix, hash, channel, scope, hops, SNR, source ours /
// outside), the filter-language text field with suggestions from `GET /v1/filters/fields` (or the built-in copy) and
// the mistake shown under it with its position, and saved filters stored on the device.
// Website twin: the filter box of `/packets`.
import 'package:flutter/material.dart';

import '../../../core/v1/packets_api.dart';
import '../../../core/v1/saved_packet_filters.dart';
import '../../design/app_type.dart';
import '../../theme.dart';

/// What the sheet hands back: the filter and, when a saved filter carried one, its window.
typedef PacketFilterResult = ({PacketFilter filter, String? window});

Future<PacketFilterResult?> showPacketFilterSheet(
  BuildContext context, {
  required PacketFilter filter,
  required FilterCatalogue catalogue,
  required SavedPacketFilterStore store,
  String? window,
}) =>
    showModalBottomSheet<PacketFilterResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: PacketFilterSheet(filter: filter, catalogue: catalogue, store: store, window: window),
      ),
    );

class PacketFilterSheet extends StatefulWidget {
  final PacketFilter filter;
  final FilterCatalogue catalogue;
  final SavedPacketFilterStore store;
  final String? window;
  const PacketFilterSheet({super.key, required this.filter, required this.catalogue, required this.store, this.window});

  @override
  State<PacketFilterSheet> createState() => _PacketFilterSheetState();
}

class _PacketFilterSheetState extends State<PacketFilterSheet> {
  late PacketFilter _f = widget.filter;
  late final TextEditingController _text = TextEditingController(text: widget.filter.text);
  final TextEditingController _node = TextEditingController();
  final TextEditingController _observer = TextEditingController();
  late final TextEditingController _hash = TextEditingController(text: widget.filter.hash ?? '');
  final TextEditingController _channel = TextEditingController();
  late final TextEditingController _scope = TextEditingController(text: widget.filter.scope ?? '');
  String? _nodeError, _observerError, _hashError, _channelError, _scopeError;
  List<SavedPacketFilter> _saved = const [];

  static const _hopsTop = 16.0;
  static const _snrLow = -20.0, _snrHigh = 15.0;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    widget.store.load().then((v) {
      if (mounted) setState(() => _saved = v);
    });
  }

  @override
  void dispose() {
    for (final c in [_text, _node, _observer, _hash, _channel, _scope]) {
      c.dispose();
    }
    super.dispose();
  }

  FilterError? get _textError => filterError(_text.text, catalogue: widget.catalogue);

  /// The sheet's state as a filter, or null when a field has a mistake.
  PacketFilter? _collect() {
    final h = _hash.text.trim().toLowerCase();
    final s = _scope.text.trim();
    setState(() {
      _hashError = h.isEmpty || RegExp(r'^[0-9a-f]{8,16}$').hasMatch(h) ? null : 'A hash is 8 to 16 hex characters.';
      _scopeError = s.isEmpty || RegExp(r'^(#[^\s,]{1,31}|unscoped|unmatched)$').hasMatch(s) ? null : 'Write #name, unscoped or unmatched.';
    });
    if (_hashError != null || _scopeError != null || _textError != null) return null;
    return _f.copyWith(hash: h.isEmpty ? null : h, clearHash: h.isEmpty, scope: s.isEmpty ? null : s, clearScope: s.isEmpty, text: _text.text.trim());
  }

  void _addNode() {
    final v = _node.text.trim().toLowerCase();
    setState(() {
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
        _f = _f.copyWith(nodes: {..._f.nodes, v}.take(20).toList());
        _nodeError = null;
        _node.clear();
      } else if (RegExp(r'^([0-9a-f]{2}){1,3}$').hasMatch(v)) {
        _f = _f.copyWith(prefix: v);
        _nodeError = null;
        _node.clear();
      } else {
        _nodeError = 'A full node key (64 hex) or a hop code (2, 4 or 6 hex).';
      }
    });
  }

  void _addObserver() {
    final v = _observer.text.trim();
    setState(() {
      if (RegExp(r'^[A-Za-z0-9_.:-]{1,160}$').hasMatch(v)) {
        final id = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(v) ? v.toLowerCase() : v;
        _f = _f.copyWith(observers: {..._f.observers, id}.take(20).toList());
        _observerError = null;
        _observer.clear();
      } else {
        _observerError = 'An observer key, or source:id for an outside observer.';
      }
    });
  }

  void _addChannel() {
    var v = _channel.text.trim();
    if (v.startsWith('#')) v = 'tag:${v.substring(1)}';
    if (v.toLowerCase() == 'public') v = 'public';
    setState(() {
      if (RegExp(r'^(public|tag:[^\s/,]{1,64}|enc:[0-9a-f]{2})$').hasMatch(v)) {
        _f = _f.copyWith(channels: {..._f.channels, v});
        _channelError = null;
        _channel.clear();
      } else {
        _channelError = 'Public, a #hashtag, or enc:<2 hex> for an unknown channel.';
      }
    });
  }

  void _insertSuggestion(String word, String partial) {
    final sel = _text.selection;
    final cursor = sel.isValid ? sel.baseOffset : _text.text.length;
    final before = _text.text.substring(0, cursor - partial.length);
    final after = _text.text.substring(cursor);
    final ins = '$word ';
    _text.value = TextEditingValue(text: '$before$ins$after', selection: TextSelection.collapsed(offset: before.length + ins.length));
  }

  Future<void> _save() async {
    final f = _collect();
    if (f == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (c) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: const Text('Save this filter'),
          content: TextField(key: const Key('filter-save-name'), controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(key: const Key('filter-save-confirm'), onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    await widget.store.save(SavedPacketFilter(name, f, window: widget.window));
    if (mounted) setState(() => _saved = widget.store.items);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final err = _textError;
    final sel = _text.selection;
    final sug = filterSuggestions(_text.text, sel.isValid ? sel.baseOffset : _text.text.length, catalogue: widget.catalogue);
    final hops = RangeValues((_f.hopsMin ?? 0).toDouble(), (_f.hopsMax ?? _hopsTop).toDouble().clamp(0, _hopsTop));
    final snr = RangeValues((_f.snrMin ?? _snrLow).clamp(_snrLow, _snrHigh), (_f.snrMax ?? _snrHigh).clamp(_snrLow, _snrHigh));
    Widget chips(List<Widget> c) => Wrap(spacing: Gap.s, runSpacing: Gap.s, children: c);
    return Column(
      key: const Key('packet-filter-sheet'),
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            children: [
              Text('Filter packets', style: t.textTheme.titleLarge),
              if (_saved.isNotEmpty) ...[
                _title(context, 'Saved filters'),
                chips([
                  for (final s in _saved)
                    InputChip(
                      key: ValueKey('saved-filter-${s.name}'),
                      label: Text(s.name),
                      onPressed: () => Navigator.pop(context, (filter: s.filter, window: s.window)),
                      onDeleted: () async {
                        await widget.store.remove(s.name);
                        if (mounted) setState(() => _saved = widget.store.items);
                      },
                      deleteButtonTooltipMessage: 'Delete ${s.name}',
                    ),
                ]),
              ],
              _title(context, 'Type'),
              chips([
                for (final e in packetTypeWireNames.values)
                  FilterChip(
                    key: Key('filter-type-$e'),
                    label: Text(packetTypeLabel(e)),
                    selected: _f.types.contains(e),
                    onSelected: (v) => setState(() => _f = _f.copyWith(types: v ? {..._f.types, e} : ({..._f.types}..remove(e)))),
                  ),
              ]),
              _title(context, 'Route'),
              chips([
                for (final r in packetRouteWireNames)
                  FilterChip(
                    key: Key('filter-route-$r'),
                    label: Text(packetRouteLabel(r)),
                    selected: _f.routes.contains(r),
                    onSelected: (v) => setState(() => _f = _f.copyWith(routes: v ? {..._f.routes, r} : ({..._f.routes}..remove(r)))),
                  ),
              ]),
              _title(context, 'Heard by'),
              SegmentedButton<PacketSourceFilter>(
                key: const Key('filter-source'),
                segments: const [
                  ButtonSegment(value: PacketSourceFilter.all, label: Text('Everyone')),
                  ButtonSegment(value: PacketSourceFilter.ours, label: Text('Ours')),
                  ButtonSegment(value: PacketSourceFilter.outside, label: Text('Outside')),
                ],
                selected: {_f.source},
                onSelectionChanged: (v) => setState(() => _f = _f.copyWith(source: v.first)),
              ),
              Text('Ours = MeshSonar observers and app phones. Outside = feeds from other analyzers.', style: t.textTheme.bodySmall),
              _title(context, 'Hops'),
              RangeSlider(
                key: const Key('filter-hops'),
                values: hops,
                min: 0,
                max: _hopsTop,
                divisions: _hopsTop.toInt(),
                labels: RangeLabels('${hops.start.round()}', hops.end >= _hopsTop ? 'any' : '${hops.end.round()}'),
                onChanged: (v) => setState(() => _f = _f.copyWith(
                      hopsMin: v.start <= 0 ? null : v.start.round(),
                      clearHopsMin: v.start <= 0,
                      hopsMax: v.end >= _hopsTop ? null : v.end.round(),
                      clearHopsMax: v.end >= _hopsTop,
                    )),
              ),
              Text(_f.hopsMin == null && _f.hopsMax == null ? 'Any number of hops' : 'From ${_f.hopsMin ?? 0} to ${_f.hopsMax ?? 'any'} hops', style: t.textTheme.bodySmall),
              _title(context, 'Best SNR'),
              RangeSlider(
                key: const Key('filter-snr'),
                values: snr,
                min: _snrLow,
                max: _snrHigh,
                divisions: (_snrHigh - _snrLow).toInt(),
                labels: RangeLabels('${snr.start.round()} dB', '${snr.end.round()} dB'),
                onChanged: (v) => setState(() => _f = _f.copyWith(
                      snrMin: v.start <= _snrLow ? null : v.start.roundToDouble(),
                      clearSnrMin: v.start <= _snrLow,
                      snrMax: v.end >= _snrHigh ? null : v.end.roundToDouble(),
                      clearSnrMax: v.end >= _snrHigh,
                    )),
              ),
              Text(_f.snrMin == null && _f.snrMax == null ? 'Any SNR' : 'From ${_f.snrMin?.round() ?? 'any'} to ${_f.snrMax?.round() ?? 'any'} dB', style: t.textTheme.bodySmall),
              _title(context, 'Node or hop code'),
              _entry(context, _node, 'filter-node', 'Node key or hop code (a7, 3cd0)', _nodeError, _addNode),
              chips([
                for (final n in _f.nodes)
                  InputChip(label: Text('Node ${n.substring(0, 8)}…'), onDeleted: () => setState(() => _f = _f.copyWith(nodes: [..._f.nodes]..remove(n)))),
                if (_f.prefix != null) InputChip(label: Text('Hop ${_f.prefix}'), onDeleted: () => setState(() => _f = _f.copyWith(clearPrefix: true))),
              ]),
              _title(context, 'Observer'),
              _entry(context, _observer, 'filter-observer', 'Observer key or source:id', _observerError, _addObserver),
              chips([
                for (final o in _f.observers)
                  InputChip(label: Text(o.length > 14 ? '${o.substring(0, 10)}…' : o), onDeleted: () => setState(() => _f = _f.copyWith(observers: [..._f.observers]..remove(o)))),
              ]),
              _title(context, 'Channel'),
              chips([
                FilterChip(
                  key: const Key('filter-channel-public'),
                  label: const Text('Public'),
                  selected: _f.channels.contains('public'),
                  onSelected: (v) => setState(() => _f = _f.copyWith(channels: v ? {..._f.channels, 'public'} : ({..._f.channels}..remove('public')))),
                ),
                for (final c in _f.channels.where((c) => c != 'public'))
                  InputChip(label: Text(c.startsWith('tag:') ? '#${c.substring(4)}' : c), onDeleted: () => setState(() => _f = _f.copyWith(channels: {..._f.channels}..remove(c)))),
              ]),
              _entry(context, _channel, 'filter-channel', '#hashtag or enc:62', _channelError, _addChannel),
              _title(context, 'Packet hash'),
              TextField(
                key: const Key('filter-hash'),
                controller: _hash,
                style: AppType.mono.copyWith(fontSize: 16),
                decoration: InputDecoration(hintText: '8 to 16 hex characters', errorText: _hashError, border: const OutlineInputBorder()),
              ),
              _title(context, 'Scope'),
              TextField(
                key: const Key('filter-scope'),
                controller: _scope,
                decoration: InputDecoration(hintText: '#cmh, unscoped or unmatched', errorText: _scopeError, border: const OutlineInputBorder()),
              ),
              _title(context, 'Filter text'),
              TextField(
                key: const Key('filter-text'),
                controller: _text,
                minLines: 1,
                maxLines: 4,
                maxLength: widget.catalogue.maxLength,
                autocorrect: false,
                enableSuggestions: false,
                style: AppType.mono.copyWith(fontSize: 16),
                decoration: InputDecoration(
                  hintText: widget.catalogue.examples.isEmpty ? 'type = ADVERT and hops >= 2' : widget.catalogue.examples.first,
                  errorText: err == null ? null : '${err.toString()} (at character ${err.at + 1})',
                  errorMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (sug.words.isNotEmpty)
                SizedBox(
                  height: 48,
                  child: ListView(
                    key: const Key('filter-suggestions'),
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final w in sug.words.take(12))
                        Padding(
                          padding: const EdgeInsets.only(right: Gap.s),
                          child: ActionChip(key: ValueKey('filter-suggest-$w'), label: Text(w), onPressed: () => _insertSuggestion(w, sug.partial)),
                        ),
                    ],
                  ),
                ),
              if (widget.catalogue.builtIn)
                Text('Field list built into the app (the server list is not available).', style: t.textTheme.bodySmall),
              for (final ex in widget.catalogue.examples.take(3))
                TextButton(
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                  onPressed: () => _text.text = ex,
                  child: Text(ex, style: AppType.mono.copyWith(fontSize: 14)),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
            child: Wrap(alignment: WrapAlignment.end, spacing: Gap.s, runSpacing: Gap.s, children: [
              TextButton(key: const Key('filter-save'), onPressed: _save, child: const Text('Save…')),
              OutlinedButton(
                key: const Key('filter-clear'),
                onPressed: () => Navigator.pop(context, (filter: PacketFilter.none, window: null)),
                child: const Text('Clear all'),
              ),
              FilledButton(
                key: const Key('filter-apply'),
                onPressed: () {
                  final f = _collect();
                  if (f != null) Navigator.pop(context, (filter: f, window: null));
                },
                child: const Text('Apply'),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _title(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
        child: Semantics(header: true, child: Text(s, style: Theme.of(context).textTheme.titleSmall)),
      );

  Widget _entry(BuildContext context, TextEditingController c, String key, String hint, String? error, VoidCallback onAdd) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: Key(key),
              controller: c,
              autocorrect: false,
              onSubmitted: (_) => onAdd(),
              decoration: InputDecoration(hintText: hint, errorText: error, errorMaxLines: 2, border: const OutlineInputBorder()),
            ),
          ),
          IconButton(key: Key('$key-add'), tooltip: 'Add', icon: const Icon(Icons.add_circle_outline), onPressed: onAdd),
        ],
      );
}
