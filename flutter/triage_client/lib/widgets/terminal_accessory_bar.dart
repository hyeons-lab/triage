import 'package:flutter/material.dart';

/// On-screen row of keys a soft keyboard lacks (Esc, Ctrl, Tab, arrows, common
/// shell symbols), shown above the terminal on touch clients — native mobile and
/// the mobile web client alike. Sits directly above the keyboard and scrolls
/// horizontally so it fits narrow phones.
///
/// Purely presentational: each key reports its byte sequence through [onSend],
/// except the sticky Ctrl toggle, which reports through [onToggleCtrl]. The
/// caller owns the armed state and passes it back as [ctrlArmed] to light the
/// key. Keeping the two panes' bars as one widget means they can never drift.
class TerminalAccessoryBar extends StatelessWidget {
  const TerminalAccessoryBar({
    super.key,
    required this.onSend,
    required this.onToggleCtrl,
    required this.ctrlArmed,
  });

  /// Called with the raw byte sequence a key emits (e.g. `'\x1b'` for esc).
  final void Function(String bytes) onSend;

  /// Called when the sticky Ctrl key is tapped; the caller flips [ctrlArmed].
  final VoidCallback onToggleCtrl;

  /// Whether sticky Ctrl is currently armed, to highlight the key.
  final bool ctrlArmed;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xff141a1c),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _key('esc', () => onSend('\x1b')),
            _key('ctrl', onToggleCtrl, active: ctrlArmed),
            _key('tab', () => onSend('\t')),
            // Shift+Tab (back-tab, `ESC [ Z`) — e.g. to cycle Claude Code's
            // auto / accept-edits / plan modes from a phone.
            _key('⇧tab', () => onSend('\x1b[Z')),
            // Enter/Return: the soft keyboard's return key maps to an IME action
            // that never reaches the terminal, so a terminal needs an explicit
            // one. `\r` (carriage return) is what a terminal expects on Enter.
            _key('enter', () => onSend('\r')),
            _key('▲', () => onSend('\x1b[A')),
            _key('▼', () => onSend('\x1b[B')),
            _key('◀', () => onSend('\x1b[D')),
            _key('▶', () => onSend('\x1b[C')),
            _key('^C', () => onSend('\x03')),
            _key('/', () => onSend('/')),
            _key('|', () => onSend('|')),
            _key('-', () => onSend('-')),
            _key('~', () => onSend('~')),
          ],
        ),
      ),
    );
  }

  // A single accessory key. Uses a raw GestureDetector (no focus node) so a tap
  // never steals focus from the terminal and dismisses the keyboard. [active]
  // highlights a latched modifier (sticky Ctrl).
  Widget _key(String label, VoidCallback onTap, {bool active = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 40, minHeight: 34),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xff2b6a63) : const Color(0xff232c2f),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xffd9e5e3),
              fontSize: 13,
              fontFamily: 'JetBrains Mono',
              // Fall back for glyphs the bundled JetBrains Mono subset may lack
              // (the arrow triangles ▲▼◀▶), so the arrow keys never render as
              // tofu on a device whose default only covers them elsewhere.
              fontFamilyFallback: ['Menlo', 'Noto Sans Symbols', 'monospace'],
            ),
          ),
        ),
      ),
    );
  }
}
