import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/host.dart';

void main() {
  test('AOW OS desktop from AOW_FORM and os-release', () {
    expect(
      detectAowOs(isLinux: true, env: const {'AOW_FORM': 'desktop'}),
      isTrue,
    );
    expect(
      detectAowOsMobile(isLinux: true, env: const {'AOW_FORM': 'desktop'}),
      isFalse,
    );
    expect(
      detectAowOs(
        isLinux: true,
        osRelease: 'NAME="AOW OS"\nID=aow\nPRETTY_NAME="AOW OS 1.0"\n',
      ),
      isTrue,
    );
    expect(detectAowOs(isLinux: false, env: const {'AOW_FORM': 'desktop'}), isFalse);
    expect(detectAowOs(isLinux: true, env: const {'XDG_CURRENT_DESKTOP': 'GNOME'}), isFalse);
  });

  test('AOW OS Mobile from AOW_FORM=phone', () {
    expect(
      detectAowOsMobile(isLinux: true, env: const {'AOW_FORM': 'phone'}),
      isTrue,
    );
    expect(
      detectAowOsMobile(isLinux: true, env: const {'AOW_FORM': 'tablet'}),
      isTrue,
    );
    expect(
      detectAowOsMobile(
        isLinux: true,
        env: const {'XDG_CURRENT_DESKTOP': 'AOW', 'FORM_FACTOR': 'handset'},
      ),
      isTrue,
    );
    expect(
      detectAowOsMobile(isLinux: true, env: const {'AOW_FORM': 'desktop'}),
      isFalse,
    );
  });
}
