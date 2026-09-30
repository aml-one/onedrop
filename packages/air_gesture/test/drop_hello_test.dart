import 'package:air_gesture/air_gesture.dart';
import 'package:test/test.dart';

void main() {
  test('parseAirOs maps Files AOW hello strings to linux', () {
    expect(parseAirOs('linux'), AirPeerOs.linux);
    expect(parseAirOs('aow'), AirPeerOs.linux);
    expect(parseAirOs('aow-os'), AirPeerOs.linux);
    expect(parseAirOs('AOW-OS-Mobile'), AirPeerOs.linux);
    expect(parseAirOs('android'), AirPeerOs.android);
    expect(parseAirOs('windows'), AirPeerOs.windows);
  });

  test('LAN hello advertises aow-os and aow-os-mobile', () {
    expect(airOsHelloWire(AirPeerOs.linux), 'linux');
    expect(airOsHelloWire(AirPeerOs.linux, aowOs: true), 'aow-os');
    expect(
      airOsHelloWire(AirPeerOs.linux, aowOs: true, aowOsMobile: true),
      'aow-os-mobile',
    );
    expect(airOsHelloWire(AirPeerOs.android, aowOsMobile: true), 'aow-os-mobile');
  });
}
