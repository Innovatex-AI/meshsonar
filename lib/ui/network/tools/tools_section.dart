// Network > Tools (build 71 seam; stream D fills this in). The signature is fixed: stream A builds the section strip
// against it. Tools: Path Inspector, Trace Viewer, Prefix Tool, Scope Audit, Observers compare, Region definition.
import 'package:flutter/material.dart';

class ToolsSection extends StatelessWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A tool to open straight away: `path`, `trace`, `prefix`, `scope-audit`, `compare`, `definition`; null shows the list.
  final String? initialTool;

  /// The tool's argument from a link (a packet or trace hash, a prefix, a hop list).
  final String? initialArg;
  const ToolsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialTool, this.initialArg});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
