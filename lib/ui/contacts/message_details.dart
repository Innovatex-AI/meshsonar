// Message details sheet for a direct message. (Being built by the detail fork; agreed signature.)
import 'package:flutter/material.dart';

import '../../chat/chat_service.dart';

/// Opens the details of one message: route, tries, timings, why it failed. Agent 2A's conversation screen calls this from a
/// message's long-press menu ("Details").
Future<void> showMessageDetails(BuildContext context, {required ChatService chat, required String messageId}) async {}
