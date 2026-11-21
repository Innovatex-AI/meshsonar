// Shared pieces of the Channels screens: the message row (reader and search), its action sheet and the report sheet.
// Sender names are claims (any key holder can write any name), so the row never presents one as verified.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/v1/channels_api.dart';
import '../../theme.dart';
import '../packets/packet_detail_screen.dart' show openNetworkPacket;
import '../packets/packet_ui.dart' show snrText;

/// "11:20" today, "Nov 20, 11:20" on another day (the phone's own time zone).
String messageTimeText(BuildContext context, DateTime at, {DateTime? now}) {
  final l = at.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final hm = TimeOfDay.fromDateTime(l).format(context);
  if (l.year == n.year && l.month == n.month && l.day == n.day) return hm;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[l.month - 1]} ${l.day}, $hm';
}

/// One message. Tap opens its packet; the trailing button (44 pt) opens the actions (report, packet, copy).
class ChannelMessageTile extends StatelessWidget {
  final ChannelMessage message;
  final String baseUrl;
  final String? regionSlug;

  /// Search results name the channel and can open it.
  final bool showChannel;
  final VoidCallback? onOpenChannel;
  final DateTime? now;
  const ChannelMessageTile({super.key, required this.message, required this.baseUrl, required this.regionSlug, this.showChannel = false, this.onOpenChannel, this.now});

  void _openPacket(BuildContext context) => openNetworkPacket(context, baseUrl: baseUrl, regionSlug: regionSlug, hash: message.packetHash);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final m = message;
    final muted = t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final sender = m.sender ?? 'Unknown sender';
    final facts = [
      'heard by ${m.heardBy}',
      '${m.hops} ${m.hops == 1 ? 'hop' : 'hops'}',
      if (m.bestSnr != null) 'SNR ${snrText(m.bestSnr)}',
    ].join(' · ');
    return Semantics(
      container: true,
      label: m.hidden ? 'Message hidden by a moderator' : '$sender says: ${m.text ?? ''}',
      child: InkWell(
        key: Key('channel-msg-${m.id}'),
        onTap: () => _openPacket(context),
        onLongPress: () => showMessageActions(context, message: m, baseUrl: baseUrl, regionSlug: regionSlug, onOpenChannel: onOpenChannel),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.only(left: Gap.l, top: Gap.xs, bottom: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelLarge?.copyWith(color: c.primary))),
                    const SizedBox(width: Gap.s),
                    Text(messageTimeText(context, m.firstSeen, now: now), style: muted),
                  ]),
                  if (showChannel && (m.channelName ?? m.channelId).isNotEmpty) Text('in ${m.channelName ?? m.channelId}', style: muted),
                  const SizedBox(height: 2),
                  if (m.hidden)
                    Text('Hidden by a moderator.', key: Key('channel-msg-hidden-${m.id}'), style: t.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, color: c.onSurfaceVariant))
                  else if (m.text == null)
                    Text('No readable text.', style: t.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, color: c.onSurfaceVariant))
                  else
                    Text.rich(_highlighted(m.text!, m.highlight, t), style: t.textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(facts, style: muted),
                ]),
              ),
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  key: Key('channel-msg-more-${m.id}'),
                  tooltip: 'Message actions',
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_horiz, color: c.onSurfaceVariant),
                  onPressed: () => showMessageActions(context, message: m, baseUrl: baseUrl, regionSlug: regionSlug, onOpenChannel: onOpenChannel),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// [text] with the server's match ranges in bold (ranges out of bounds are ignored).
TextSpan _highlighted(String text, List<(int, int)> ranges, ThemeData t) {
  if (ranges.isEmpty) return TextSpan(text: text);
  final sorted = [...ranges]..sort((a, b) => a.$1.compareTo(b.$1));
  final spans = <TextSpan>[];
  var at = 0;
  for (final (s, e) in sorted) {
    if (s < at || e <= s || e > text.length) continue;
    if (s > at) spans.add(TextSpan(text: text.substring(at, s)));
    spans.add(TextSpan(text: text.substring(s, e), style: TextStyle(fontWeight: FontWeight.w700, color: t.colorScheme.primary)));
    at = e;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(children: spans);
}

/// The actions of one message: Report (not on a hidden message: there is nothing left to report), Open packet,
/// Open channel (search), Copy text.
Future<void> showMessageActions(BuildContext context, {required ChannelMessage message, required String baseUrl, required String? regionSlug, VoidCallback? onOpenChannel}) {
  final m = message;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          key: const Key('channel-msg-open-packet'),
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('Open packet'),
          onTap: () {
            Navigator.of(sheet).pop();
            openNetworkPacket(context, baseUrl: baseUrl, regionSlug: regionSlug, hash: m.packetHash);
          },
        ),
        if (onOpenChannel != null)
          ListTile(
            key: const Key('channel-msg-open-channel'),
            leading: const Icon(Icons.forum_outlined),
            title: Text('Open ${m.channelName ?? 'channel'}'),
            onTap: () {
              Navigator.of(sheet).pop();
              onOpenChannel();
            },
          ),
        if (!m.hidden && m.text != null)
          ListTile(
            key: const Key('channel-msg-copy'),
            leading: const Icon(Icons.copy),
            title: const Text('Copy text'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: m.text!));
              Navigator.of(sheet).pop();
            },
          ),
        if (!m.hidden)
          ListTile(
            key: const Key('channel-msg-report'),
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report this message'),
            onTap: () {
              Navigator.of(sheet).pop();
              showReportSheet(context, baseUrl: baseUrl, messageId: m.id);
            },
          ),
      ]),
    ),
  );
}

/// The report form (the site's ReportForm): what a report does, a reason, an optional note, Send. Sent once.
Future<void> showReportSheet(BuildContext context, {required String baseUrl, required String messageId}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReportSheet(baseUrl: baseUrl, messageId: messageId),
    );

class _ReportSheet extends StatefulWidget {
  final String baseUrl, messageId;
  const _ReportSheet({required this.baseUrl, required this.messageId});
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

/// What to say for a failed report. Every wording ends by saying nothing was sent, except a timeout (unknown).
String reportErrorText(Object e) {
  if (e is V1NotLive) return 'Reports are not switched on yet. Nothing was sent.';
  if (e is V1Error) {
    if (e.code == 'rate_limited' || e.status == 429) {
      return 'Too many reports from this connection. ${e.retryAfter != null ? 'Try again in ${e.retryAfter} s.' : 'Try again later.'}';
    }
    if (e.code == 'timeout') return 'The server took too long to answer, so it is not known whether the report arrived.';
    if (e.offline) return 'No connection. Nothing was sent.';
    return '${e.message.isEmpty ? 'The report was not accepted.' : e.message} Nothing was sent.';
  }
  return 'The report was not accepted. Nothing was sent.';
}

class _ReportSheetState extends State<_ReportSheet> {
  String _reason = reportReasons.keys.first;
  final TextEditingController _note = TextEditingController();
  bool _sending = false;
  String? _error;
  ReportReceipt? _receipt;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _receipt != null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final api = channelsApiFactory(widget.baseUrl);
    try {
      final r = await api.report(widget.messageId, reason: _reason, note: _note.text);
      if (mounted) setState(() => _receipt = r);
    } catch (e) {
      if (mounted) setState(() => _error = reportErrorText(e));
    } finally {
      api.close();
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final r = _receipt;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: r != null
              ? Column(key: const Key('report-received'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Report received', style: t.textTheme.titleLarge),
                  const SizedBox(height: Gap.s),
                  Text('A moderator will look at it. Thank you.', style: t.textTheme.bodyMedium),
                  const SizedBox(height: Gap.xs),
                  SelectableText('Receipt: ${r.id}', key: const Key('report-receipt'), style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                  const SizedBox(height: Gap.l),
                  FilledButton(key: const Key('report-done'), onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
                ])
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Report this message', style: t.textTheme.titleLarge),
                  const SizedBox(height: Gap.s),
                  Text(reportExplainer, key: const Key('report-explainer'), style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                  const SizedBox(height: Gap.s),
                  RadioGroup<String>(
                    groupValue: _reason,
                    onChanged: (v) {
                      if (v != null && !_sending) setState(() => _reason = v);
                    },
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final e in reportReasons.entries)
                        RadioListTile<String>(key: Key('report-reason-${e.key}'), value: e.key, title: Text(e.value), dense: false, contentPadding: EdgeInsets.zero),
                    ]),
                  ),
                  TextField(
                    key: const Key('report-note'),
                    controller: _note,
                    enabled: !_sending,
                    maxLength: reportNoteMaxChars,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder()),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.s),
                      child: Text(_error!, key: const Key('report-error'), style: t.textTheme.bodyMedium?.copyWith(color: c.error)),
                    ),
                  FilledButton(
                    key: const Key('report-send'),
                    onPressed: _sending ? null : _send,
                    child: Text(_sending ? 'Sending…' : 'Send report'),
                  ),
                ]),
        ),
      ),
    );
  }
}
