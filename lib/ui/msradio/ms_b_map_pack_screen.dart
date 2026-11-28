// MeshSonar radio > Map pack (brief C.5): the offline map pack in the radio's map partition (name, zooms, tiles, size, free
// space) and "Send a map pack": pick an `.msmp` file, upload it to `POST /maps?size=`, then follow `status.maps` while the
// radio writes it. The last result is the radio's own text.
import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../../platform/file_pick.dart';
import 'ms_b_common.dart';

class MsBMapPackScreen extends StatefulWidget {
  final MsRadioController c;
  final FilePick pick;
  const MsBMapPackScreen({super.key, required this.c, this.pick = const DeviceFilePick()});
  @override
  State<MsBMapPackScreen> createState() => _MsBMapPackScreenState();
}

class _MsBMapPackScreenState extends State<MsBMapPackScreen> {
  MsMaps? _maps;
  String? _error;
  bool _loading = true;

  // upload
  bool _sending = false;
  int _sent = 0, _total = 0;
  String? _fileName;

  // the radio writing it (status.maps)
  bool _radioBusy = false;
  int _radioProgress = 0;
  String? _uploadText;
  late final MsBPoller _poll = MsBPoller(tick: _followStatus, want: () => mounted && _radioBusy);

  MsRadioApi? get _api => widget.c.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) return;
    final err = await msBTry(() async {
      final m = await api.maps();
      if (!mounted) return;
      _maps = m;
      _radioBusy = m.busy;
      _radioProgress = m.progress;
    });
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = err;
    });
    _poll.kick();
  }

  Future<void> _followStatus() async {
    final api = _api;
    if (api == null) return;
    final s = await api.status();
    final m = s.maps;
    if (!mounted) return;
    setState(() {
      _radioBusy = m?.busy ?? false;
      _radioProgress = m?.progress ?? 0;
    });
    if (!_radioBusy) await _load();
  }

  Future<void> _send() async {
    final api = _api;
    if (api == null) return;
    PickedFile? f;
    final pickErr = await msBTry(() async => f = await widget.pick.pickFile(extensions: const ['msmp']));
    if (!mounted) return;
    if (pickErr != null) {
      setState(() => _error = pickErr);
      return;
    }
    final file = f;
    if (file == null) return;
    setState(() {
      _error = null;
      _sending = true;
      _fileName = file.name;
      _sent = 0;
      _total = file.size;
      _uploadText = null;
    });
    MsUploadResult? r;
    final err = await msBTry(() async {
      r = await api.uploadMapPack(file.upload, onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _sent = done;
          _total = total ?? file.size;
        });
      });
    });
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = err;
      _uploadText = r?.text;
      // the radio may still be writing: follow status.maps until it is done
      if (err == null) _radioBusy = true;
    });
    if (err == null) await _followStatus().catchError((Object _) {});
    _poll.kick();
  }

  List<Widget> _rows(BuildContext context) {
    final m = _maps;
    final t = Theme.of(context);
    final out = <Widget>[];
    if (_loading && m == null) return [const MsBBlock(child: Center(child: CircularProgressIndicator()))];
    out.add(MsBError(_error));
    if (m != null && !m.partition) {
      out.add(const MsBBlock(child: NoteCard('This radio has no space for an offline map pack.', key: Key('msb-maps-no-partition'))));
    }
    final p = m?.pack;
    if (m != null && m.partition) {
      if (p == null) {
        out.add(const MsBBlock(
            child: NoteCard('There is no map pack on the radio yet. Send one to see streets on the radio\'s map.',
                key: Key('msb-maps-empty'), title: 'No map pack')));
        out.add(InsetGroup(header: 'Storage', rows: [
          MsBValueRow(title: 'Free space', value: m.spaceKb == null ? 'unknown' : msBBytes(m.spaceKb! * 1024)),
        ]));
      } else {
        final zooms = p.zmin == null || p.zmax == null ? 'unknown' : '${p.zmin} to ${p.zmax}${p.zdef == null ? '' : ' (opens at ${p.zdef})'}';
        out.add(InsetGroup(header: 'Map pack on the radio', groupKey: const Key('msb-maps-pack'), rows: [
          MsBValueRow(title: 'Name', value: p.name ?? 'No name'),
          MsBValueRow(title: 'Zoom levels', value: zooms),
          MsBValueRow(title: 'Tiles', value: p.tiles == null ? 'unknown' : '${p.tiles}'),
          MsBValueRow(title: 'Size', value: msBBytes(p.bytes)),
          MsBValueRow(title: 'Free space', value: m.spaceKb == null ? 'unknown' : msBBytes(m.spaceKb! * 1024)),
        ]));
      }
    }
    if (_sending) {
      out.add(MsBProgress(
        'Sending ${_fileName ?? 'the map pack'}: ${msBBytes(_sent)} of ${msBBytes(_total)}',
        key: const Key('msb-maps-sending'),
        value: _total <= 0 ? null : _sent / _total,
      ));
    } else if (_radioBusy) {
      out.add(MsBProgress('The radio is writing the map pack: $_radioProgress%', key: const Key('msb-maps-writing'), value: msBPct(_radioProgress)));
    }
    final last = _uploadText?.trim().isNotEmpty == true ? _uploadText!.trim() : (m?.lastResult.trim().isNotEmpty == true ? m!.lastResult.trim() : null);
    if (last != null) {
      out.add(InsetGroup(header: 'Last result', rows: [InsetRow(key: const Key('msb-maps-last'), title: last, chevron: false)]));
    }
    if (m == null || m.partition) {
      out.add(MsBButtons([
        FilledButton.icon(
          key: const Key('msb-maps-send'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _sending || _radioBusy ? null : _send,
          icon: const Icon(Icons.upload_file),
          label: const Text('Send a map pack'),
        ),
      ]));
      out.add(MsBBlock(
        child: Text('Pick an .msmp file from Files. It replaces the pack on the radio. Keep the phone on this Wi-Fi until it says Done.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => MsBPage(c: widget.c, id: 'maps', title: 'Map pack', onRefresh: _load, builder: _rows);
}
