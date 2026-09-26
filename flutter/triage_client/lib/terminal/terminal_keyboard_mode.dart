/// Hardware-keyboard routing for the native terminal view.
library;

/// Whether the terminal view should take the hardware-keyboard path instead of
/// its hidden IME TextInput connection: always on desktop (the IME path
/// desyncs the framework hardware-keyboard state there and swallows
/// keystrokes), and on mobile only while the soft keyboard is suppressed
/// (closing the IME path is what keeps it down).
bool terminalHardwareKeyboardOnly({
  required bool isMobile,
  required bool softKeyboardEnabled,
}) => !isMobile || !softKeyboardEnabled;
