// Turns errors into short plain-language messages for people in a car. Never shows stack traces.
import 'dart:async';
import 'dart:io';

import '../core/api.dart';

String friendlyError(Object e, {String action = 'That'}) {
  if (e is CmatException) {
    switch (e.status) {
      case 401:
        return 'The server doesn\'t recognise this driver key. Request a new key in Settings.';
      case 403:
        return 'Your driver key isn\'t approved yet. Your pings are saved on this phone; check the key in Settings.';
      case 413:
        return 'The server said the upload was too large. Your pings are saved; try again.';
      case 429:
        return 'The server is busy. Your pings are saved; try again in a minute.';
    }
    if (e.status == null) {
      // HttpCmatClient throws network failures and timeouts with no HTTP status.
      return 'Can\'t reach the server. Check your signal; your data is safe on this phone.';
    }
    if (e.status! >= 500) {
      return 'The server had a problem (${e.status}). Your data is safe on this phone; try again later.';
    }
    return e.message.isEmpty ? '$action failed.' : e.message;
  }
  if (e is SocketException || e is HttpException) {
    return 'Can\'t reach the server. Check your signal; your data is safe on this phone.';
  }
  if (e is TimeoutException) {
    return '$action took too long. Try again.';
  }
  if (e is FileSystemException) {
    return 'Couldn\'t save to this device\'s storage (${e.message}).';
  }
  if (e is FormatException) {
    return 'Got an answer we couldn\'t read. Check the server URL in Settings.';
  }
  if (e is StateError) {
    return '$action failed: ${e.message}.';
  }
  final s = e.toString();
  final cleaned = s.startsWith('Exception: ') ? s.substring(11) : s;
  // Keep it to one short line.
  final firstLine = cleaned.split('\n').first;
  return firstLine.length > 160 ? '$action failed.' : '$action failed: $firstLine';
}

/// Shown when a problem report can't be sent for a reason signal will fix; the report stays saved on the phone.
const String reportNotSentMessage = 'Not sent. Your report is saved on this phone; send it when you have signal.';

/// Plain-language text for a problem report the server didn't take.
String friendlyReportError(Object e) {
  if (e is! CmatException) return friendlyError(e, action: 'Sending the report');
  return switch (e.status) {
    // 503 is the server's "problem reports are turned off"; other 5xx are outages.
    404 || 503 => 'This server doesn\'t accept problem reports.',
    401 || 403 || 429 => friendlyError(e),
    413 => 'The report is too large.',
    null || >= 500 => reportNotSentMessage,
    _ => 'The server didn\'t take the report: ${e.message}',
  };
}

/// Plain-language text for a sync error string coming back in a SyncReport.
String friendlySyncError(String error) {
  final l = error.toLowerCase();
  if (l.contains('no driver key')) {
    return 'Request a driver key in Settings to upload. Pings are kept on this phone.';
  }
  if (l.contains('403') || l.contains('not approved') || l.contains('forbidden')) {
    return 'Upload refused: your driver key isn\'t approved. Pings are kept on this phone.';
  }
  if (l.contains('401') || l.contains('not recognised') || l.contains('not recognized')) {
    return 'Upload refused: the server doesn\'t know this driver key. Pings are kept on this phone.';
  }
  if (l.contains('socket') ||
      l.contains('network') ||
      l.contains('connection') ||
      l.contains('host') ||
      l.contains('timed out') ||
      l.contains('secure connection')) {
    return 'Couldn\'t reach the server. Pings are kept on this phone and will upload next time.';
  }
  final firstLine = error.split('\n').first;
  return 'Sync didn\'t finish: ${firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine}. Pings are kept on this phone.';
}
