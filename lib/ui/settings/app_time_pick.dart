import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../design/app_surfaces.dart';

/// Time of day picker. Apple: an inline wheel in an app sheet with a Done button. Elsewhere the Material dialog.
Future<TimeOfDay?> showAppTimePicker(BuildContext context, TimeOfDay initial) async {
  final p = Theme.of(context).platform;
  if (p != TargetPlatform.iOS && p != TargetPlatform.macOS) {
    return showTimePicker(context: context, initialTime: initial);
  }
  var value = DateTime(2000, 1, 1, initial.hour, initial.minute);
  final done = await showAppSheet<bool>(
    context,
    detents: const [0.42],
    builder: (ctx, controller) => AppSheetScaffold(
      controller: controller,
      title: 'Choose a time',

      primaryAction: FilledButton(key: const Key('time-picker-done'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Done')),
      children: [
        SizedBox(
          height: 200,
          child: CupertinoDatePicker(
            key: const Key('time-picker-wheel'),
            mode: CupertinoDatePickerMode.time,
            initialDateTime: value,
            onDateTimeChanged: (d) => value = d,
          ),
        ),
      ],
    ),
  );
  return done == true ? TimeOfDay(hour: value.hour, minute: value.minute) : null;
}
