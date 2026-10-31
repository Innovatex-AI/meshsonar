import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/scope_guard.dart';

void main() {
  final key = Uint8List.fromList(List.generate(16, (i) => i + 1));

  test('frames: key, clear, unscoped (MyMesh.cpp 1978-1992)', () {
    expect(encodeSetFloodScope(FloodScope.key(key)), [Cmd.setFloodScopeKey, 0, ...key]);
    expect(encodeSetFloodScope(FloodScope.radioDefault), [Cmd.setFloodScopeKey, 0]);
    expect(encodeSetFloodScope(FloodScope.unscoped), [Cmd.setFloodScopeKey, 1]);
  });

  test('a ping (no scope) leaves a radio nobody touched alone', () {
    final g = ScopeGuard(firmwareVerCode: 14);
    expect(g.commandFor(null), isNull);
    expect(g.commandFor(FloodScope.radioDefault), isNull);
  });

  test('chat on a scoped channel sets the scope; the next ping clears it so it cannot leak', () {
    final g = ScopeGuard(firmwareVerCode: 14);
    final step = g.commandFor(FloodScope.key(key))!;
    expect(step.cmd, [Cmd.setFloodScopeKey, 0, ...key]);
    g.applied(step.target);
    expect(g.commandFor(FloodScope.key(key)), isNull, reason: 'same scope again: nothing to send');
    final clear = g.commandFor(null)!;
    expect(clear.cmd, [Cmd.setFloodScopeKey, 0]);
    g.applied(clear.target);
    expect(g.commandFor(null), isNull, reason: 'cleared: nothing more');
  });

  test('switching between two scopes sends the new one every time', () {
    final g = ScopeGuard(firmwareVerCode: 14);
    final other = Uint8List.fromList(List.filled(16, 9));
    g.applied(g.commandFor(FloodScope.key(key))!.target);
    final s = g.commandFor(FloodScope.key(other))!;
    expect(s.cmd.sublist(2), other);
  });

  test('old firmware: no key form below ver 8, no unscoped form below ver 12', () {
    expect(ScopeGuard(firmwareVerCode: 7).supported, isFalse);
    expect(ScopeGuard(firmwareVerCode: 7).commandFor(FloodScope.key(key)), isNull);
    final g = ScopeGuard(firmwareVerCode: 9);
    final s = g.commandFor(FloodScope.unscoped);
    expect(s, isNull, reason: 'falls back to the radio default, which an untouched radio already is');
    g.applied(g.commandFor(FloodScope.key(key))!.target);
    expect(g.commandFor(FloodScope.unscoped)!.cmd, [Cmd.setFloodScopeKey, 0]);
  });

  test('disable stops all commands; reset forgets what was applied', () {
    final g = ScopeGuard(firmwareVerCode: 14);
    g.applied(g.commandFor(FloodScope.key(key))!.target);
    g.reset();
    expect(g.commandFor(null), isNull);
    g.disable();
    expect(g.commandFor(FloodScope.key(key)), isNull);
  });
}
