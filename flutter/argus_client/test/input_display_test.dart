import 'package:argus_client/src/input_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('displayTerminalInput names terminal control input', () {
    expect(displayTerminalInput('\r'), r'\r');
    expect(displayTerminalInput('\u007f'), 'backspace');
    expect(displayTerminalInput('\u0003'), '0x3');
  });

  test('displayTerminalInput preserves printable text', () {
    expect(displayTerminalInput('abc'), 'abc');
  });
}
