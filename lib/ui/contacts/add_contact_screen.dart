// Add a contact: scan a QR code, paste a link or key, or show this radio's own contact for someone else to scan.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../chat/contact_manager.dart';
import '../../chat/mesh_links.dart';
import '../../chat/models.dart';
import '../theme.dart';
import 'contacts_controller.dart';
import 'qr_scan_screen.dart';
import 'qr_view.dart';

class AddContactScreen extends StatefulWidget {
  final ContactsController controller;

  /// Tests inject a fake camera; null = the real one.
  final ScannerBuilder? scannerBuilder;

  /// Tests replace the system clipboard and share sheet.
  final Future<String?> Function()? readClipboard;
  final Future<void> Function(String text)? share;
  const AddContactScreen({super.key, required this.controller, this.scannerBuilder, this.readClipboard, this.share});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _text = TextEditingController();
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _showPaste = false;

  ContactManager get _m => widget.controller.manager;

  bool get _bareKey => RegExp(r'^[0-9a-fA-F\s]{64,}$').hasMatch(_text.text.trim()) && !_text.text.trim().toLowerCase().startsWith('meshcore');

  @override
  void dispose() {
    _text.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final clip = widget.readClipboard != null ? await widget.readClipboard!() : (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (clip == null || clip.trim().isEmpty) {
      setState(() => _error = 'The clipboard is empty. Copy a meshcore:// link or a contact key first.');
      return;
    }
    setState(() {
      _text.text = clip.trim();
      _error = null;
    });
  }

  Future<void> _submit(String input) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    AddContactResult r;
    try {
      final t = input.trim();
      r = t.toLowerCase().startsWith('meshcore://') || !_bareKey ? await _m.addFromLink(t) : await _m.addByKey(t, name: _name.text.trim());
    } catch (_) {
      r = const AddContactResult(error: 'Something went wrong adding that contact. Check the link and try again.');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      setState(() => _error = r.error ?? 'That could not be added.');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text('Added ${r.contact!.displayName}.${r.note == null ? '' : ' ${r.note}'}')));
  }

  void _scan() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => QrScanScreen(
        scannerBuilder: widget.scannerBuilder,
        onPaste: () => setState(() => _showPaste = true),
        onCode: (code) {
          setState(() {
            _text.text = code;
            _showPaste = true;
          });
          _submit(code);
        },
      ),
    ));
  }

  void _showMine() {
    final id = _m.radioId;
    final connected = _m.connected && id != null;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        String? link;
        if (connected) {
          var name = widget.controller.chat.selfName();
          name = (name == null || name.trim().isEmpty) ? 'My radio' : name.trim();
          try {
            link = MeshLinks.encodeContact(name: name, publicKey: id, type: ContactType.companion);
          } catch (_) {
            link = MeshLinks.encodeContact(name: 'My radio', publicKey: id, type: ContactType.companion);
          }
        }
        final t = Theme.of(ctx);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
          child: Column(
            key: const Key('my-contact'),
            children: [
              Text('My contact', style: t.textTheme.titleLarge),
              const SizedBox(height: Gap.m),
              if (link == null)
                Text('Connect your radio first. The code is made from your radio\'s identity.', style: t.textTheme.bodyLarge, textAlign: TextAlign.center)
              else ...[
                Text('Someone who scans this adds you as a contact.', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: Gap.m),
                QrView(data: link, size: 240, semanticLabel: 'QR code with your contact'),
                const SizedBox(height: Gap.m),
                Wrap(spacing: Gap.s, runSpacing: Gap.s, alignment: WrapAlignment.center, children: [
                  OutlinedButton.icon(
                    key: const Key('my-copy'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy link'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: link!));
                      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Link copied')));
                    },
                  ),
                  OutlinedButton.icon(
                    key: const Key('my-share'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Share'),
                    onPressed: () async => widget.share != null ? widget.share!(link!) : await SharePlus.instance.share(ShareParams(text: link!)),
                  ),
                ]),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _tile(Key key, IconData icon, String title, String body, VoidCallback onTap) => Card(
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(Corners.card),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: Row(children: [
                Icon(icon, size: 28),
                const SizedBox(width: Gap.l),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    Text(body, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add contact')),
      body: SafeArea(
        child: ListView(
          key: const Key('add-contact'),
          padding: const EdgeInsets.all(Gap.l),
          children: [
            _tile(const Key('add-scan'), Icons.qr_code_scanner_rounded, 'Scan a QR code', 'Point the camera at their contact code.', _scan),
            _tile(const Key('add-paste-tile'), Icons.content_paste_rounded, 'Paste a link or key', 'A meshcore:// link, or a 64-character key.', () => setState(() => _showPaste = !_showPaste)),
            if (_showPaste)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.s),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextField(
                    key: const Key('add-text'),
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) => setState(() => _error = null),
                    decoration: InputDecoration(labelText: 'Link or key', errorText: _error, errorMaxLines: 4, border: const OutlineInputBorder()),
                  ),
                  if (_bareKey) ...[
                    const SizedBox(height: Gap.s),
                    TextField(key: const Key('add-name'), controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)', border: OutlineInputBorder())),
                  ],
                  const SizedBox(height: Gap.s),
                  Row(children: [
                    OutlinedButton.icon(
                      key: const Key('add-clipboard'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: const Icon(Icons.paste_rounded),
                      label: const Text('Paste'),
                      onPressed: _paste,
                    ),
                    const SizedBox(width: Gap.s),
                    Expanded(
                      child: FilledButton(
                        key: const Key('add-submit'),
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _busy || _text.text.trim().isEmpty ? null : () => _submit(_text.text),
                        child: Text(_busy ? 'Adding' : 'Add contact'),
                      ),
                    ),
                  ]),
                ]),
              ),
            if (!_showPaste && _error != null) Padding(padding: const EdgeInsets.all(Gap.s), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
            _tile(const Key('add-mine'), Icons.qr_code_2_rounded, 'Show my contact', 'Let someone scan you.', _showMine),
          ],
        ),
      ),
    );
  }
}
