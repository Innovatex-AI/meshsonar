// The live Map Definition (schemaMinor 7, with `symbols.tools` and the page presets) for the tool-map tests.
import 'dart:io';

import 'package:meshsonar/core/map_definition.dart';

MapDefinition liveToolDefinition() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
