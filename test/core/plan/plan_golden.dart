import 'dart:convert';
import 'dart:io';

/// The website-generated golden numbers (meshcore-insights scripts/plan-tools-golden.ts).
Map<String, dynamic> loadPlanGolden() => jsonDecode(File('test/fixtures/plan_tools_golden.json').readAsStringSync()) as Map<String, dynamic>;
