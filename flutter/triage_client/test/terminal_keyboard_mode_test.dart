import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_keyboard_mode.dart';

void main() {
  test('desktop always takes the hardware path', () {
    // The IME path desyncs HardwareKeyboard on desktop, so suppression must
    // never open it there.
    expect(
      terminalHardwareKeyboardOnly(isMobile: false, softKeyboardEnabled: true),
      isTrue,
    );
    expect(
      terminalHardwareKeyboardOnly(isMobile: false, softKeyboardEnabled: false),
      isTrue,
    );
  });

  test('mobile takes the hardware path only while suppressed', () {
    expect(
      terminalHardwareKeyboardOnly(isMobile: true, softKeyboardEnabled: true),
      isFalse,
    );
    expect(
      terminalHardwareKeyboardOnly(isMobile: true, softKeyboardEnabled: false),
      isTrue,
    );
  });
}
