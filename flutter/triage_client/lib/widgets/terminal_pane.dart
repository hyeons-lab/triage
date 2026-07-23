import 'terminal_pane_stub.dart'
    if (dart.library.js_util) 'terminal_pane_web.dart'
    as impl;

class TerminalController {
  final List<void Function(String)> _writeListeners = [];
  final List<void Function()> _clearListeners = [];
  final List<void Function(int, int)> _resizeListeners = [];
  final List<void Function()> _fitListeners = [];
  final List<void Function()> _refitListeners = [];
  final List<void Function(String)> _inputListeners = [];
  final List<void Function(int, int)> _resizeOutListeners = [];

  final List<String> _writeBuffer = [];

  void addWriteListener(void Function(String) listener) {
    _writeListeners.add(listener);
    if (_writeBuffer.isNotEmpty) {
      for (final data in _writeBuffer) {
        listener(data);
      }
      _writeBuffer.clear();
    }
  }

  void removeWriteListener(void Function(String) listener) =>
      _writeListeners.remove(listener);

  void addClearListener(void Function() listener) =>
      _clearListeners.add(listener);
  void removeClearListener(void Function() listener) =>
      _clearListeners.remove(listener);

  void addResizeListener(void Function(int, int) listener) =>
      _resizeListeners.add(listener);
  void removeResizeListener(void Function(int, int) listener) =>
      _resizeListeners.remove(listener);

  void addFitListener(void Function() listener) => _fitListeners.add(listener);
  void removeFitListener(void Function() listener) =>
      _fitListeners.remove(listener);

  // `fit` is what the view's own resize observer fires — recompute the grid from
  // the current pixels. `refit` is the explicit user/resume request, which must
  // do that *and* re-assert the fitted size on the host even when the grid did
  // not change (so a stale-narrow grid on tab resume is corrected and a
  // shared-PTY device-reclaim takes effect). The view implements the difference.
  void addRefitListener(void Function() listener) =>
      _refitListeners.add(listener);
  void removeRefitListener(void Function() listener) =>
      _refitListeners.remove(listener);

  void addInputListener(void Function(String) listener) =>
      _inputListeners.add(listener);
  void removeInputListener(void Function(String) listener) =>
      _inputListeners.remove(listener);

  void addResizeOutListener(void Function(int, int) listener) =>
      _resizeOutListeners.add(listener);
  void removeResizeOutListener(void Function(int, int) listener) =>
      _resizeOutListeners.remove(listener);

  void write(String data) {
    if (_writeListeners.isEmpty) {
      _writeBuffer.add(data);
    } else {
      for (final listener in List.from(_writeListeners)) {
        listener(data);
      }
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

  void refit() {
    for (final listener in List.from(_refitListeners)) {
      listener();
    }
  }

  void sendInput(String data) {
    for (final listener in List.from(_inputListeners)) {
      listener(data);
    }
  }

  void sendResizeOut(int cols, int rows) {
    for (final listener in List.from(_resizeOutListeners)) {
      listener(cols, rows);
    }
  }

  void dispose() {
    _writeListeners.clear();
    _clearListeners.clear();
    _resizeListeners.clear();
    _fitListeners.clear();
    _refitListeners.clear();
    _inputListeners.clear();
    _resizeOutListeners.clear();
    _writeBuffer.clear();
  }
}

class TerminalSessionInputRouter {
  final Map<String, _TerminalSessionRoute> _routes = {};

  bool hasRoute(String sessionId) => _routes.containsKey(sessionId);

  Object bind(String sessionId, TerminalController controller) {
    final token = Object();
    _routes[sessionId] = _TerminalSessionRoute(controller, token);
    return token;
  }

  void unbind(String sessionId, Object token) {
    final route = _routes[sessionId];
    if (route != null && identical(route.token, token)) {
      _routes.remove(sessionId);
    }
  }

  void remove(String sessionId) {
    _routes.remove(sessionId);
  }

  void sendInput(String sessionId, String data) {
    _routes[sessionId]?.controller.sendInput(data);
  }

  void sendResizeOut(String sessionId, int cols, int rows) {
    _routes[sessionId]?.controller.sendResizeOut(cols, rows);
  }
}

class _TerminalSessionRoute {
  _TerminalSessionRoute(this.controller, this.token);

  final TerminalController controller;
  final Object token;
}

// Re-export the platform-specific implementation of TerminalPane
typedef TerminalPane = impl.TerminalPane;
