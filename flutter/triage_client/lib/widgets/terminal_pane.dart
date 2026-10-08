import 'dart:async';

import 'package:flutter/widgets.dart';

import '../terminal/debug_log.dart';
import 'terminal_pane_stub.dart'
    if (dart.library.js_util) 'terminal_pane_web.dart'
    as impl;

/// Transient pill shown at the top of the terminal when scrollback paging
/// exhausts without yielding older lines: a TUI redrawing in place (or the
/// platform window maxed on barren output) means the loaded scrollback is
/// genuinely all there is in reach: the view is not stuck, there is
/// nothing older to load. Shared by both pane implementations so the
/// wording cannot drift between them.
class NoOlderScrollbackPill extends StatelessWidget {
  const NoOlderScrollbackPill({super.key});

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xcc161b1d),
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            'No older scrollback in reach',
            style: TextStyle(color: Color(0xffcdd7d6), fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// Whether a landed history page was barren: it added no buffer lines
/// while the user is still near the top, so the window was a TUI
/// redrawing in place and the pane should ask for a deeper one instead
/// of sitting on identical content. Shared by both pane implementations
/// (the native pane runs this in CI; the web pane cannot, so the web
/// behavior is covered by construction plus the predicate's unit test).
bool shouldContinuePastBarrenPage({
  required int addedLines,
  required bool nearTop,
}) => addedLines <= 0 && nearTop;

/// Latch behind [NoOlderScrollbackPill]: shows the pill for 3 seconds,
/// re-arming on every exhaustion note. Shared by both pane
/// implementations so the timer discipline cannot drift between them;
/// each pane keeps its own platform guards at its call sites.
mixin NoOlderScrollbackLatch<T extends StatefulWidget> on State<T> {
  bool showNoOlderScrollback = false;
  Timer? _noOlderScrollbackTimer;

  void noteHistoryExhausted() {
    _noOlderScrollbackTimer?.cancel();
    _noOlderScrollbackTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => showNoOlderScrollback = false);
      }
    });
    if (mounted && !showNoOlderScrollback) {
      setState(() => showNoOlderScrollback = true);
    }
  }

  void cancelNoOlderScrollbackTimer() {
    _noOlderScrollbackTimer?.cancel();
    _noOlderScrollbackTimer = null;
  }
}

class TerminalController {
  final List<void Function(String)> _writeListeners = [];
  final List<void Function()> _clearListeners = [];
  final List<void Function(int, int)> _resizeListeners = [];
  final List<void Function()> _fitListeners = [];
  final List<void Function()> _refitListeners = [];
  final List<void Function(String)> _inputListeners = [];
  final List<void Function(int, int)> _resizeOutListeners = [];
  final List<void Function()> _interactionListeners = [];

  final List<String> _writeBuffer = [];

  void addWriteListener(void Function(String) listener) {
    _writeListeners.add(listener);
    tdbg(
      'ctrl.addWrite',
      'ctrl#${identityHashCode(this)} now '
          '${_writeListeners.length} listeners, '
          'buffered=${_writeBuffer.length}',
    );
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

  void addInteractionListener(void Function() listener) =>
      _interactionListeners.add(listener);
  void removeInteractionListener(void Function() listener) =>
      _interactionListeners.remove(listener);

  void notifyInteraction() {
    for (final listener in List.from(_interactionListeners)) {
      listener();
    }
  }

  final List<void Function()> _historyReplayedListeners = [];
  void addHistoryReplayedListener(void Function() listener) =>
      _historyReplayedListeners.add(listener);
  void removeHistoryReplayedListener(void Function() listener) =>
      _historyReplayedListeners.remove(listener);

  void notifyHistoryReplayed() {
    for (final listener in List.from(_historyReplayedListeners)) {
      listener();
    }
  }

  // Fired before a scroll-up page re-attach so panes can stash their
  // scroll anchor; the replay that follows carries a bigger window, and
  // the anchor is restored adjusted by the added rows.
  final List<void Function()> _historyPageStartedListeners = [];
  void addHistoryPageStartedListener(void Function() listener) =>
      _historyPageStartedListeners.add(listener);
  void removeHistoryPageStartedListener(void Function() listener) =>
      _historyPageStartedListeners.remove(listener);

  void notifyHistoryPageStarted() {
    for (final listener in List.from(_historyPageStartedListeners)) {
      listener();
    }
  }

  final List<void Function()> _historyPageCancelledListeners = [];
  void addHistoryPageCancelledListener(void Function() listener) =>
      _historyPageCancelledListeners.add(listener);
  void removeHistoryPageCancelledListener(void Function() listener) =>
      _historyPageCancelledListeners.remove(listener);

  void notifyHistoryPageCancelled() {
    for (final listener in List.from(_historyPageCancelledListeners)) {
      listener();
    }
  }

  void write(String data) {
    if (_writeListeners.isEmpty) {
      tdbg(
        'ctrl.write',
        'ctrl#${identityHashCode(this)} NO LISTENERS '
            '-> buffered; ${tdbgPreview(data)}',
      );
      _writeBuffer.add(data);
    } else {
      tdbg(
        'ctrl.write',
        'ctrl#${identityHashCode(this)} '
            '${_writeListeners.length} listeners; ${tdbgPreview(data)}',
      );
      // Isolated per listener: these are independent consumers (xterm.dart on
      // one side, xterm.js on the other), and letting one throw used to stop
      // the rest, which blanked the pane rather than degrading it.
      final listeners = List.of(_writeListeners);
      for (var i = 0; i < listeners.length; i++) {
        try {
          listeners[i](data);
        } catch (error, stack) {
          tdbg('ctrl.write', 'listener #$i THREW: $error\n$stack');
        }
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
    _interactionListeners.clear();
    _historyReplayedListeners.clear();
    _historyPageStartedListeners.clear();
    _historyPageCancelledListeners.clear();
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

  void rebind(String sessionId, TerminalController controller) {
    final route = _routes[sessionId];
    if (route != null) {
      _routes[sessionId] = _TerminalSessionRoute(controller, route.token);
    } else {
      bind(sessionId, controller);
    }
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

  void notifyInteraction(String sessionId) {
    _routes[sessionId]?.controller.notifyInteraction();
  }
}

class _TerminalSessionRoute {
  _TerminalSessionRoute(this.controller, this.token);

  final TerminalController controller;
  final Object token;
}

// Re-export the platform-specific implementation of TerminalPane
typedef TerminalPane = impl.TerminalPane;
