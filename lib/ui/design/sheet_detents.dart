// Detents for form-like sheets (antenna, ping settings, telemetry, preset prompt). At large Dynamic Type sizes a
// half-height sheet shows two lines of a form, so the sheet opens at the full-height detent instead (Drive plan WP8).
import 'package:flutter/widgets.dart';

/// Text scale at and above which form sheets open full height (AX1 is about 1.64 on iOS; AX3 about 2.35).
const double kFormSheetFullHeightScale = 1.35;

/// Full-height detent fraction used by form sheets.
const double kFormSheetFull = 0.92;

/// `[kFormSheetFull]` alone when the text is large, else a medium and a full detent.
List<double> formSheetDetents(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(100) / 100;
  return scale >= kFormSheetFullHeightScale ? const [kFormSheetFull] : const [0.62, kFormSheetFull];
}
