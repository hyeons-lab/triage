import '../widgets/terminal_pane.dart' show TerminalController;
import 'terminal_sink.dart';

/// [TerminalSink] over the platform-agnostic [TerminalController].
///
/// The controller is already the single write seam shared by both platform
/// views: on native, SessionVm's listener writes controller output into the
/// `xterm.dart` `Terminal`; on web, the web pane's listener writes it into the
/// xterm.js instance. Routing the store through the controller therefore reuses
/// the existing, tested emulator plumbing on both platforms.
///
/// Sizing is owned by the views (native `TerminalView` auto-fit, web FitAddon),
/// so [resize] is a no-op; history replays at the current view width and the
/// live repaint self-heals the visible frame after a resize. Input and
/// resize-out continue to flow through the controller/input-router directly, so
/// the store does not consume emulator output/resize here.
class TerminalControllerSink implements TerminalSink {
  TerminalControllerSink(this.controller);

  final TerminalController controller;

  @override
  void write(String data) => controller.write(data);

  @override
  void clear() => controller.clear();

  @override
  void resize(int cols, int rows) {
    // No-op: the views own sizing; the store must not fight the auto-fit.
  }

  @override
  set onOutput(void Function(String data)? handler) {}

  @override
  set onResize(void Function(int cols, int rows)? handler) {}

  @override
  void dispose() {}
}
