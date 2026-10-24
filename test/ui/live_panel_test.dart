import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/live_stream.dart';
import 'package:meshsonar/ui/region/live_screen.dart';

void main() {
  testWidgets('shows streamed packets in a list and pauses when backgrounded', (tester) async {
    final body = StreamController<List<int>>();
    var opens = 0;
    final stream = LiveStream(Uri.parse('https://x.test'), connect: (r) async {
      opens++;
      return http.StreamedResponse(body.stream, 200);
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LivePanel(baseUrl: 'https://x.test', regionSlug: 'cmh', stream: stream))));
    await tester.pump();
    expect(find.byKey(const Key('live-empty')), findsOneWidget);
    body.add(utf8.encode('event: packet\ndata: {"kind":"packet","packet":{"hash":"ab12","type":5,"route":1,"at":"${DateTime.now().toUtc().toIso8601String()}",'
        '"observations":[{"observer":"o1","snrDb":7.5,"hops":2}],"hops":[]}}\n\n'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.text('Group text'), findsOneWidget);
    expect(find.textContaining('1 observer'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(stream.state, LiveConnState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(opens, 2);
    await tester.pumpWidget(const SizedBox());
    unawaited(stream.dispose());
    unawaited(body.close());
  });
}
