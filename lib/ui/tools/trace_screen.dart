// STUB: replaced by the real screen.
import 'package:flutter/material.dart';

import 'tool_kit.dart';

class TraceScreen extends StatelessWidget {
  const TraceScreen({super.key});
  @override
  Widget build(BuildContext context) => ToolPage(id: 'trace', title: 'Trace path', builder: (context, host, tools) => const SizedBox.shrink());
}
