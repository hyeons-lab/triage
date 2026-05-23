import 'terminal_pane_stub.dart'
    if (dart.library.js_util) 'terminal_pane_web.dart' as impl;

class TerminalController {
  final List<void Function(String)> _writeListeners = [];
  final List<void Function()> _clearListeners = [];
  final List<void Function(int, int)> _resizeListeners = [];
  final List<void Function()> _fitListeners = [];

  void addWriteListener(void Function(String) listener) => _writeListeners.add(listener);
  void removeWriteListener(void Function(String) listener) => _writeListeners.remove(listener);

  void addClearListener(void Function() listener) => _clearListeners.add(listener);
  void removeClearListener(void Function() listener) => _clearListeners.remove(listener);

  void addResizeListener(void Function(int, int) listener) => _resizeListeners.add(listener);
  void removeResizeListener(void Function(int, int) listener) => _resizeListeners.remove(listener);

  void addFitListener(void Function() listener) => _fitListeners.add(listener);
  void removeFitListener(void Function() listener) => _fitListeners.remove(listener);

  void write(String data) {
    for (final listener in List.from(_writeListeners)) {
      listener(data);
    }
  }

  void clear() {
    for (final listener in List.from(_clearListeners)) {
      listener();
    }
  }

  void resize(int cols, int rows) {
    for (final listener in List.from(_resizeListeners)) {
      listener(cols, rows);
    }
  }

  void fit() {
    for (final listener in List.from(_fitListeners)) {
      listener();
    }
  }

  void dispose() {
    _writeListeners.clear();
    _clearListeners.clear();
    _resizeListeners.clear();
    _fitListeners.clear();
  }
}

// Re-export the platform-specific implementation of TerminalPane
typedef TerminalPane = impl.TerminalPane;
