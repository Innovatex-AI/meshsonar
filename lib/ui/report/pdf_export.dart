// PDF export glue for the UI: loads Barlow from the plain assets in assets/fonts (SIL OFL 1.1: embedding in a
// document is allowed; D46: the only place a font file is read, and SF is never embedded) and writes a rendered report (lib/core/report_pdf.dart) to the export folder, then opens the
// share sheet through the existing seams (services.exportDir / services.shareFile). The share sheet offers Print and
// Save to Files for a PDF, so there is no print plugin. Nothing here touches the network.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../../app/app_state.dart';
import '../../core/report_pdf.dart';
import '../design/app_type.dart';

const String pdfRegularFont = AppType.documentRegular;
const String pdfBoldFont = AppType.documentBold;

Future<ReportFonts> loadReportFonts() async =>
    ReportFonts(regular: await rootBundle.load(pdfRegularFont), bold: await rootBundle.load(pdfBoldFont));

/// Renders [doc] with Barlow and shares it as [name] (a `.pdf` file name).
Future<File> shareReportPdf(AppState s, String name, ReportDoc doc) async {
  final fonts = await loadReportFonts();
  final Uint8List bytes = await renderReportPdf(doc, fonts: fonts);
  final dir = await s.services.exportDir();
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  await s.services.shareFile(f);
  return f;
}
