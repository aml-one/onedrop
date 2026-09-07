import 'package:air_gesture/air_gesture.dart';
import 'package:test/test.dart';

AirDropPeer desk({
  required String id,
  required bool camera,
  AirPeerOs os = AirPeerOs.windows,
  double attention = 0,
  bool seesHand = false,
}) {
  return AirDropPeer(
    id: id,
    name: id,
    role: AirPeerRole.desktop,
    os: os,
    camera: camera,
    attention: attention,
    seesHand: seesHand,
  );
}

void main() {
  test('one no-camera desktop auto-sends', () {
    final d = resolveLeftFrame(
      nearby: [desk(id: 'pc', camera: false)],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.autoSend);
    expect(d.target?.id, 'pc');
  });

  test('several no-camera desktops show names', () {
    final d = resolveLeftFrame(
      nearby: [
        desk(id: 'office', camera: false),
        desk(id: 'studio', camera: false, os: AirPeerOs.macos),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.pickNoCamera);
    expect(d.choices.map((p) => p.id), ['office', 'studio']);
  });

  test('a camera desktop waits for a palm on fist-exit', () {
    final d = resolveLeftFrame(
      nearby: [
        desk(id: 'cam-pc', camera: true),
        desk(id: 'headless', camera: false),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'cam-pc');
  });

  test('timeout with a camera desktop keeps waiting for a palm', () {
    final d = resolveLeftFrame(
      nearby: [
        desk(id: 'cam-pc', camera: true),
        desk(id: 'headless', camera: false),
      ],
      holdTimedOut: true,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'cam-pc');
  });

  test('a phone with a camera nearby waits for a palm, not a headless PC', () {
    final d = resolveLeftFrame(
      nearby: [
        const AirDropPeer(
          id: 'phone',
          name: 'Ultra',
          role: AirPeerRole.phone,
          os: AirPeerOs.android,
          camera: true,
        ),
        desk(id: 'linux', camera: false, os: AirPeerOs.linux),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'phone');
  });

  test('one Linux desktop without a camera auto-sends', () {
    final d = resolveLeftFrame(
      nearby: [desk(id: 'linux', camera: false, os: AirPeerOs.linux)],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.autoSend);
    expect(d.target?.id, 'linux');
  });

  test('a Windows PC with a camera waits for a palm when the fist leaves', () {
    final d = resolveLeftFrame(
      nearby: [desk(id: 'liv', camera: true)],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'liv');
  });

  test('tablet plus camera PC waits for a palm', () {
    final d = resolveLeftFrame(
      nearby: [
        const AirDropPeer(
          id: 'honor',
          name: 'Honor',
          role: AirPeerRole.phone,
          os: AirPeerOs.android,
          camera: true,
        ),
        desk(id: 'liv', camera: true),
        desk(id: 'nova', camera: false, os: AirPeerOs.macos),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.dropsOnLeave, isFalse);
  });

  test('timeout with several cameras keeps waiting until one sees the fist', () {
    final d = resolveLeftFrame(
      nearby: [
        const AirDropPeer(
          id: 'honor',
          name: 'Honor',
          role: AirPeerRole.phone,
          os: AirPeerOs.android,
          camera: true,
        ),
        desk(id: 'liv', camera: true),
      ],
      holdTimedOut: true,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target, isNull);
  });

  test('the camera that sees the fist gets the drop', () {
    final d = resolveLeftFrame(
      nearby: [
        const AirDropPeer(
          id: 'honor',
          name: 'Honor',
          role: AirPeerRole.phone,
          os: AirPeerOs.android,
          camera: true,
          seesHand: true,
        ),
        desk(id: 'liv', camera: true),
        desk(id: 'nova', camera: false, os: AirPeerOs.macos),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.autoSend);
    expect(d.target?.id, 'honor');
  });

  test('a headless PC is not a target when a camera is nearby', () {
    final d = resolveLeftFrame(
      nearby: [
        const AirDropPeer(
          id: 'honor',
          name: 'Honor',
          role: AirPeerRole.phone,
          os: AirPeerOs.android,
          camera: true,
        ),
        desk(id: 'nova', camera: false, os: AirPeerOs.macos),
      ],
      holdTimedOut: true,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'honor');
  });

  test('a camera desktop the user is facing waits for an open palm', () {
    final d = resolveLeftFrame(
      nearby: [
        desk(id: 'cam-pc', camera: true, attention: 0.72),
        desk(id: 'headless', camera: false),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'cam-pc');
  });

  test('timeout facing a camera desktop still waits for a palm', () {
    final d = resolveLeftFrame(
      nearby: [
        desk(id: 'cam-pc', camera: true, attention: 0.72),
        desk(id: 'headless', camera: false),
      ],
      holdTimedOut: true,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'cam-pc');
  });

  test('the screen with clearly higher attention is the catch target', () {
    final d = resolveLeftFrame(
      nearby: [
        desk(id: 'matebook', camera: true, attention: 0.81),
        desk(id: 'office', camera: true, attention: 0.40),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'matebook');
  });

  test('a phone looking at the drop waits for an open palm', () {
    final d = resolveLeftFrame(
      nearby: [
        const AirDropPeer(
          id: 'pad',
          name: 'MatePad',
          role: AirPeerRole.phone,
          os: AirPeerOs.android,
          camera: true,
          attention: 0.66,
        ),
        desk(id: 'cam-pc', camera: true, attention: 0.12),
      ],
      holdTimedOut: false,
    );
    expect(d.action, LeftFrameAction.waitCatch);
    expect(d.target?.id, 'pad');
  });
}
