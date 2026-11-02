// A form field that shows its current choice and opens an action sheet to change it (replaces DropdownButton, whose
// anchored Material menu opens over the content). Works with a nullable T: the option whose value is null is "None".
import 'package:flutter/material.dart';

import 'design/app_surfaces.dart';
import 'design/app_symbols.dart';

class PickOption<T> {
  final T value;
  final String label;
  const PickOption(this.value, this.label);
}

class PickField<T> extends StatelessWidget {
  final String label;
  final String? helper;
  final T value;
  final List<PickOption<T>> options;
  final ValueChanged<T> onChanged;
  final bool dense;
  const PickField({
    super.key,
    required this.label,
    this.helper,
    required this.value,
    required this.options,
    required this.onChanged,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final current =
        options.where((o) => o.value == value).firstOrNull?.label ?? '';
    return InkWell(
      onTap: () async {
        final i = await showAppActionSheet<int>(
          context,
          title: label,
          actions: [
            for (var k = 0; k < options.length; k++)
              AppAction(
                options[k].label,
                k,
                checked: options[k].value == value,
                key: ValueKey('pick-option-$k'),
              ),
          ],
        );
        if (i != null) onChanged(options[i].value);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          border: dense ? const OutlineInputBorder() : null,
          isDense: dense,
          suffixIcon: const AppSymbolIcon(AppSymbols.chevronDown, size: 18),
        ),
        child: Text(current, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
