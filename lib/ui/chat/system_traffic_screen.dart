// Read-only traffic of the System (wardrive) channel: what other drivers' pings put on it. Opened from the System row of
// the Chats list (and from the old Channels list while the chatRedesign flag exists).
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
import '../theme.dart';
import '../design/app_symbols.dart';
import '../design/state_views.dart';
import 'message_bubble.dart';

/// Read-only list of what others posted on the wardrive channel (pings from other MeshSonar and MeshMapper users).
class SystemTrafficScreen extends StatefulWidget {
  final ChatController controller;
  final Channel channel;
  const SystemTrafficScreen({super.key, required this.controller, required this.channel});
  @override
  State<SystemTrafficScreen> createState() => _SystemTrafficScreenState();
}

class _SystemTrafficScreenState extends State<SystemTrafficScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_r);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.controller.service.systemTraffic(widget.channel.id!, limit: 100);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.channel.name} traffic')),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Text(
              'This is the wardrive channel: other people\'s pings land here. It is read-only and kept only on this phone, the newest ${page.messages.length}.',
              style: t.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: page.messages.isEmpty
                ? const AppEmptyView(symbol: AppSymbols.waveform, title: 'Nothing heard yet', message: 'Pings from other drivers on this channel will show up here while your radio is connected.')
                : ListView.builder(
                    key: const Key('traffic-list'),
                    itemCount: page.messages.length,
                    itemBuilder: (context, i) => MessageBubble(message: page.messages[i], showSender: true),
                  ),
          ),
        ]),
      ),
    );
  }
}
