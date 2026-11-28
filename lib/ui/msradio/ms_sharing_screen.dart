// Build 78 (builder A), brief C.3: Sharing and wardrive (GET / POST /uplink, polled every 2 s while open and in front):
// Log what the radio hears (`capture`), Share with MeshSonar (`share`), Wardrive GPS points (`wardrive`, needs capture),
// the IATA code, the uplink state line and the heard / sent / last hour counters. The radio uploads its own data; the app
// never uploads anything it reads here.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/msradio/msradio.dart';
import '../design/app_surfaces.dart' show showAppToast;
import '../design/tokens.dart';
import '../radio/inset_list.dart';
import 'ms_common.dart';

class MsSharingScreen extends StatelessWidget {
  final MsRadioController c;
  const MsSharingScreen(this.c, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('ms-sharing-screen'),
        appBar: AppBar(title: const Text('Sharing and wardrive')),
        body: MsLive<MsUplink>(
          c: c,
          every: kMsMinPoll,
          load: (api) => api.uplink(),
          builder: (context, live) => _SharingBody(c: c, live: live),
        ),
      );
}

class _SharingBody extends StatefulWidget {
  final MsRadioController c;
  final MsLiveData<MsUplink> live;
  const _SharingBody({required this.c, required this.live});

  @override
  State<_SharingBody> createState() => _SharingBodyState();
}

class _SharingBodyState extends State<_SharingBody> {
  final _iata = TextEditingController();
  final _iataFocus = FocusNode();
  String? _busy;

  @override
  void initState() {
    super.initState();
    _iata.text = widget.live.data.uplink?.iata ?? '';
  }

  @override
  void didUpdateWidget(covariant _SharingBody old) {
    super.didUpdateWidget(old);
    // a poll does not overwrite what the person is typing
    if (!_iataFocus.hasFocus) _iata.text = widget.live.data.uplink?.iata ?? '';
  }

  @override
  void dispose() {
    _iata.dispose();
    _iataFocus.dispose();
    super.dispose();
  }

  Future<void> _set(String what, {bool? capture, bool? share, bool? wardrive, String? iata}) async {
    final api = widget.c.api;
    if (api == null) return;
    setState(() => _busy = what);
    try {
      final u = await api.setUplink(capture: capture, share: share, wardrive: wardrive, iata: iata);
      if (!mounted) return;
      // a reply without the uplink part: read it again
      if (u.uplink == null) {
        await widget.live.reload();
      } else {
        widget.live.set(MsUplink(
            uplink: u.uplink, log: u.log ?? widget.live.data.log, ownerKey: u.ownerKey ?? widget.live.data.ownerKey, ownerName: u.ownerName ?? widget.live.data.ownerName));
      }
      if (iata != null && mounted) {
        _iataFocus.unfocus();
        showAppToast(context, 'IATA code saved.');
      }
    } on MsRadioError catch (e) {
      if (mounted) msShowError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.live.data;
    final u = d.uplink ?? const MsUplinkState();
    final l = d.log;
    final t = Theme.of(context);
    Widget sw(String key, String title, String subtitle, bool value, ValueChanged<bool>? onChanged) => SwitchListTile.adaptive(
          key: Key(key),
          title: Text(title),
          subtitle: Text(subtitle),
          value: value,
          onChanged: _busy != null ? null : onChanged,
          contentPadding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
        );
    return MsBody(listKey: const Key('ms-sharing-list'), children: [
      if (widget.live.refreshError != null) MsBanner('Not updated: ${widget.live.refreshError}'),
      InsetGroup(header: 'On the radio', rows: [
        sw('ms-capture', 'Log what the radio hears', 'Every packet heard is kept in the radio\'s log.', u.capture,
            (v) => _set('capture', capture: v)),
        sw('ms-share', 'Share with MeshSonar', 'The radio sends what it hears to MeshSonar itself, live or later.', u.share,
            (v) => _set('share', share: v)),
        sw(
            'ms-wardrive',
            'Wardrive GPS points',
            u.capture ? 'A GPS point every 15 seconds while the radio has a fix.' : 'Needs Log what the radio hears.',
            u.wardrive && u.capture,
            u.capture ? (v) => _set('wardrive', wardrive: v) : null),
      ]),
      InsetGroup(
        header: 'Region',
        footer: 'The 3-letter airport code of the region the radio reports to, for example CMH.',
        rows: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('ms-iata'),
                  controller: _iata,
                  focusNode: _iataFocus,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 3,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]'))],
                  decoration: const InputDecoration(labelText: 'IATA code', counterText: '', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: Gap.s),
              FilledButton.tonal(
                key: const Key('ms-iata-save'),
                style: FilledButton.styleFrom(minimumSize: Size(64, Hit.of(context))),
                onPressed: _busy != null
                    ? null
                    : () {
                        final v = _iata.text.trim().toUpperCase();
                        if (!RegExp(r'^[A-Z0-9]{3}$').hasMatch(v)) {
                          showAppToast(context, 'The code is 3 letters or digits.');
                          return;
                        }
                        _set('iata', iata: v);
                      },
                child: const Text('Save'),
              ),
            ]),
          ),
        ],
      ),
      InsetGroup(header: 'Uplink', rows: [
        InsetRow(title: 'State', value: u.state ?? '—', chevron: false),
        InsetRow(title: 'Heard', value: '${msCount(l?.heard)} · ${msCount(l?.heardHour)} last hour', chevron: false),
        InsetRow(title: 'Sent', value: '${msCount(l?.sent)} · ${msCount(l?.sentHour)} last hour', chevron: false),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.xs, 0, Layout.screenMargin + Gap.xs, Gap.l),
        child: Text(
          'The radio uploads its own data over its own Wi-Fi. This app does not upload anything it reads from the radio.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ),
    ]);
  }
}
