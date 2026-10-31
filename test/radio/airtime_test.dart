import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/airtime.dart';

void main() {
  double at(int bytes, int sf, double bw, {int cr = 5, int? pre}) =>
      loraAirtimeMs(payloadBytes: bytes, sf: sf, bwKhz: bw, cr: cr, preambleSymbols: pre);

  test('Semtech formula with the datasheet 8-symbol preamble (explicit override)', () {
    // SF7 BW62.5 CR5, 37 bytes: Tsym 2.048 ms, preamble 12.25 x 2.048 = 25.088, 68 payload symbols = 139.264 -> 164.352 ms.
    expect(at(37, 7, 62.5, pre: 8), closeTo(164.352, 1e-9));
    // The website's tested reference values (meshcore-insights src/lib/tools/airtime.ts) share this formula.
    expect(at(37, 7, 250, pre: 8).round(), 41);
  });

  test('MeshCore preamble: 32 symbols at SF8 and below, 16 above (RadioLibWrappers.h preambleLengthForSF)', () {
    expect(meshcorePreambleSymbols(7), 32);
    expect(meshcorePreambleSymbols(8), 32);
    expect(meshcorePreambleSymbols(9), 16);
    expect(meshcorePreambleSymbols(12), 16);
    // default = MeshCore's: SF8/BW62.5, 37-byte ping = 386 ms (not 288 with the 8-symbol preamble)
    expect(at(37, 8, 62.5).round(), 386);
    expect(at(37, 8, 62.5, pre: 8).round(), 288);
    expect(at(37, 7, 62.5), closeTo(164.352 + 24 * 2.048, 1e-9));
    expect(at(37, 11, 250), closeTo(at(37, 11, 250, pre: 16), 1e-12));
  });

  test('a slower coding rate and a bigger packet take longer; a wider band is faster', () {
    expect(at(37, 7, 62.5, cr: 8), greaterThan(at(37, 7, 62.5)));
    expect(at(100, 7, 62.5), greaterThan(at(37, 7, 62.5)));
    expect(at(37, 7, 125), lessThan(at(37, 7, 62.5)));
  });

  test('group text packet size: the ping "KE4BFI: MS:xxxxxxxxxx" is 37 bytes on air', () {
    expect(groupTextPacketBytes('KE4BFI: MS:xxxxxxxxxx'.length), 37);
    expect(groupTextPacketBytes('KE4BFI: MS:xxxxxxxxxx'.length, transportCodes: true), 41);
    expect(groupTextPacketBytes(11), 5 + 16);
    expect(groupTextPacketBytes(12), 5 + 32);
  });
}
