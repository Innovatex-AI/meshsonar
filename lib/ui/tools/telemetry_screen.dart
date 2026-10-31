// STUB: replaced by the real screen.
import 'package:flutter/material.dart';

import 'tool_kit.dart';

class TelemetryScreen extends StatelessWidget {
  const TelemetryScreen({super.key});
  @override
  Widget build(BuildContext context) => ToolPage(id: 'telemetry', title: 'Telemetry', builder: (context, host, tools) => const SizedBox.shrink());
}
