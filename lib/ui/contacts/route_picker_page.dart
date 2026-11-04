// "Choose repeaters yourself" (chat plan 4.7 b): pick repeaters, reorder them, see hash collisions, test the chain, then Save
// (the set-path radio WRITE). The page is only reachable while AppFlags.routeWriteVerified is on (see path_manager_screen.dart).
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoButton, CupertinoNavigationBar, CupertinoSlidingSegmentedControl, CupertinoTextField;
import 'package:flutter/material.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../../core/heard.dart' show haversineM;
import '../../radio/path_tools.dart';
import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/tool_frames.dart' show maxTraceHops;
import '../../radio/tools/trace_tool.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/hop_chain.dart';
import '../design/tokens.dart';
import 'contact_widgets.dart' show heardText;
import 'profile_widgets.dart';
import 'route_nodes.dart';

/// The words for the cap line: "At most 32 repeaters with 2-byte hashes."
String hopCapText(int hashSize) => 'At most ${maxHopsFor(hashSize)} repeaters with $hashSize-byte hashes.'; // copy-ok: Advanced

class RoutePickerPage extends StatefulWidget {
  final ContactManager manager;
  final String publicKey;
  final RadioTools? tools;
  const RoutePickerPage({super.key, required this.manager, required this.publicKey, this.tools});
  @override
  State<RoutePickerPage> createState() => _RoutePickerPageState();
}

class _RoutePickerPageState extends State<RoutePickerPage> {
  final List<Contact> _chosen = [];
  final List<PathCandidate> _typed = [];
  int _hashSize = 1;
  bool _testing = false;
  bool? _tested;
  String? _testNote;
  bool _saving = false;
  final _text = TextEditingController();
  String? _textError;

  ContactManager get _m => widget.manager;
  Contact get _target => _m.store.contacts.get(_m.radioId ?? '', widget.publicKey)!;
  List<Contact> get _repeaters => [
        for (final c in _m.store.contacts.list(_m.radioId ?? '')) if (c.type == ContactType.repeater || c.type == ContactType.room) c
      ];
  List<PathCandidate> get _chain => [..._chosen.map((c) => PathCandidate(c.publicKey, c.displayName)), ..._typed];
  List<PathCandidate> get _known => [for (final c in _repeaters) PathCandidate(c.publicKey, c.displayName)];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        _tested = null;
        _testNote = null;
      });

  void _add(Contact c) {
    if (_chain.length >= maxHopsFor(_hashSize)) {
      showAppToast(context, hopCapText(_hashSize));
      return;
    }
    AppHaptics.selection();
    _chosen.add(c);
    _changed();
  }

  void _applyText() {
    final r = parsePathText(_text.text);
    if (r.route == null) {
      setState(() => _textError = r.error);
      return;
    }
    _chosen.clear();
    _typed
      ..clear()
      ..addAll([for (final h in r.route!.hexHops) PathCandidate(h.padRight(64, '0'), 'Repeater $h')]);
    _hashSize = r.route!.hashSize;
    _textError = null;
    _changed();
  }

  PathRoute get _route => PathRoute(_hashSize, [for (final c in _chain) PathCandidate(c.keyHex, c.name).hash(_hashSize).let(_hexBytes)]);

  Future<void> _test() async {
    final tools = widget.tools ?? radioToolsOf(context);
    if (tools == null || !_m.connected) {
      showAppToast(context, 'Connect your radio to test the route.');
      return;
    }
    if (_chain.length > maxTraceHops) {
      setState(() => _testNote = 'A test can follow at most $maxTraceHops repeaters.');
      return;
    }
    setState(() {
      _testing = true;
      _tested = null;
      _testNote = null;
    });
    final stops = [for (final c in _chain) TraceStop(name: c.name, keyHex: c.keyHex)];
    final t = await tools.trace.run(stops, hashSize: _hashSize == 3 ? 4 : _hashSize);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _tested = t.ok;
      _testNote = t.ok ? 'The chain answered.' : (t.detail ?? 'No answer.');
    });
  }

  Future<void> _save() async {
    if (_chain.isEmpty || _saving) return;
    if (_tested != true) {
      final go = await showAppConfirm(context,
          title: 'Save without testing?',
          message: 'The route has not been tested. A wrong route can stop messages from arriving.',
          confirmLabel: 'Save without testing',
          confirmKey: const Key('picker-save-untested'));
      if (!go || !mounted) return;
    }
    setState(() => _saving = true);
    final err = await _m.setRoute(widget.publicKey, _route);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      showAppToast(context, err, kind: AppToastKind.error);
      return;
    }
    AppHaptics.success();
    showAppToast(context, 'Route saved. Keeping this route.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    final collisions = findHashCollisions(_chain, _known, _hashSize);
    final nodes = routeNodes(targetName: _target.displayName, route: _chain.isEmpty ? null : _route, repeaters: _repeaters);
    return Scaffold(
      backgroundColor: col.bg,
      appBar: CupertinoNavigationBar(
        backgroundColor: col.bg,
        border: null,
        automaticallyImplyLeading: false,
        leading: CupertinoButton(padding: EdgeInsets.zero, onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel', key: Key('picker-cancel'))),
        middle: const Text('Choose repeaters'),
        trailing: CupertinoButton(
          key: const Key('picker-save'),
          padding: EdgeInsets.zero,
          onPressed: _chain.isEmpty || _saving ? null : _save,
          child: const Text('Save'),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(padding: const EdgeInsets.only(bottom: Gap.xl), children: [
              ProfileGroup(rows: [
                Padding(
                  padding: const EdgeInsets.all(Layout.screenMargin),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Hash size', style: AppType.footnote.copyWith(color: col.textMuted)), // copy-ok: Advanced
                    const SizedBox(height: Gap.xs),
                    CupertinoSlidingSegmentedControl<int>(
                      key: const Key('picker-hash-size'),
                      groupValue: _hashSize,
                      children: const {1: Text('1 byte'), 2: Text('2 bytes'), 3: Text('3 bytes')},
                      onValueChanged: (v) {
                        if (v == null) return;
                        _hashSize = v;
                        if (_chain.length > maxHopsFor(v)) {
                          _chosen.clear();
                          _typed.clear();
                        }
                        _changed();
                      },
                    ),
                    const SizedBox(height: Gap.xs),
                    Text(hopCapText(_hashSize), key: const Key('picker-cap'), style: AppType.footnote.copyWith(color: col.textMuted)),
                  ]),
                ),
              ]),
              if (_chain.isNotEmpty)
                ProfileGroup(rows: [
                  Padding(padding: const EdgeInsets.all(Layout.screenMargin), child: HopChain(nodes: nodes)),
                ]),
              if (_chain.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Corners.card),
                    child: ColoredBox(
                      color: col.surfaceHigh,
                      child: ReorderableListView(
                        key: const Key('picker-chain'),
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        onReorderItem: (a, b) {
                          // The chain is chosen first, typed after; reorder works across the combined list.
                          final all = [..._chosen.map<Object>((c) => c), ..._typed.map<Object>((c) => c)];
                          final item = all.removeAt(a);
                          all.insert(b, item);
                          _chosen
                            ..clear()
                            ..addAll(all.whereType<Contact>());
                          _typed
                            ..clear()
                            ..addAll(all.whereType<PathCandidate>());
                          _changed();
                        },
                        children: [
                          for (var i = 0; i < _chain.length; i++)
                            Container(
                              key: ValueKey('hop-$i-${_chain[i].keyHex}'),
                              color: col.surfaceHigh,
                              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
                              constraints: const BoxConstraints(minHeight: Hit.minAndroid),
                              child: Row(children: [
                                ReorderableDragStartListener(index: i, child: Padding(padding: const EdgeInsets.only(right: Gap.m), child: AppSymbolIcon(AppSymbols.lineDecrease, size: 20, color: col.textMuted))),
                                Expanded(child: Text(_chain[i].name, style: AppType.body.copyWith(color: col.textPrimary))),
                                Text(_chain[i].hash(_hashSize), key: Key('chip-$i'), style: monoStyle.copyWith(color: col.textMuted)),
                                const SizedBox(width: Gap.s),
                                Semantics(
                                  button: true,
                                  label: 'Remove ${_chain[i].name}',
                                  child: GestureDetector(
                                    key: Key('chip-remove-$i'),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      if (i < _chosen.length) {
                                        _chosen.removeAt(i);
                                      } else {
                                        _typed.removeAt(i - _chosen.length);
                                      }
                                      _changed();
                                    },
                                    child: SizedBox(width: Hit.minAndroid, height: Hit.minAndroid, child: Center(child: AppSymbolIcon(AppSymbols.xmarkCircleFill, size: 20, color: col.textMuted))),
                                  ),
                                ),
                              ]),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_chain.isNotEmpty) const SizedBox(height: Gap.l),
              for (final w in collisions)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.s),
                  child: Text(w.warning, key: Key('collision-${w.hash}'), style: AppType.footnote.copyWith(color: col.warning)),
                ),
              ProfileGroup(rows: [
                ProfileRow(
                  key: const Key('picker-test'),
                  label: 'Test route',
                  valueWidget: _testing ? const CupertinoActivityIndicator() : null,
                  value: _tested == null ? null : (_tested! ? 'Works' : 'No answer'),
                  chevron: !_testing && _tested == null,
                  onTap: _chain.isEmpty || _testing ? null : _test,
                ),
              ], footer: _testNote),
              Padding(
                padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.l, 0, Layout.screenMargin, Gap.xs),
                child: Semantics(header: true, child: Text('ADD A REPEATER', style: AppType.footnote.copyWith(color: col.textMuted))),
              ),
              ProfileGroup(rows: [
                if (_repeaters.isEmpty) const ProfileRow(label: 'No repeaters in your contacts yet'),
                for (final r in _repeaters)
                  ProfileRow(
                    key: Key('pick-${r.publicKey.substring(0, 8)}'),
                    label: r.displayName,
                    value: _detail(r),
                    onTap: () => _add(r),
                  ),
              ]),
              ProfileGroup(rows: [
                Padding(
                  padding: const EdgeInsets.all(Layout.screenMargin),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Advanced: type the hashes', style: AppType.footnote.copyWith(color: col.textMuted)), // copy-ok: Advanced
                    const SizedBox(height: Gap.xs),
                    CupertinoTextField(
                      key: const Key('picker-text'),
                      controller: _text,
                      placeholder: 'aa,bb,cc',
                      autocorrect: false,
                      onSubmitted: (_) => _applyText(),
                    ),
                    if (_textError != null) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(_textError!, key: const Key('picker-text-error'), style: AppType.footnote.copyWith(color: col.danger))),
                    Align(alignment: Alignment.centerRight, child: CupertinoButton(key: const Key('picker-text-apply'), padding: EdgeInsets.zero, onPressed: _applyText, child: const Text('Use these'))),
                  ]),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  String _detail(Contact r) {
    final t = _target;
    final parts = <String>[r.publicKey.substring(0, _hashSize * 2)];
    if (r.lat != null && r.lon != null && t.lat != null && t.lon != null) {
      parts.add('${(haversineM(t.lat!, t.lon!, r.lat!, r.lon!) / 1000).toStringAsFixed(1)} km');
    }
    parts.add(heardText(r.lastHeardMs, _m.nowMs()).replaceFirst('Heard ', ''));
    return parts.join(' · ');
  }
}

List<int> _hexBytes(String h) => [for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
