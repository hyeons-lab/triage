import 'dart:ui' show Offset, Size;

/// Gap between the copy button and the selection it points at.
const _gap = 6.0;

/// Where the floating copy button sits over a touch selection.
class CopyButtonPlacement {
  const CopyButtonPlacement(this.left, this.top);

  final double left;
  final double top;

  @override
  bool operator ==(Object other) =>
      other is CopyButtonPlacement && other.left == left && other.top == top;

  @override
  int get hashCode => Object.hash(left, top);

  @override
  String toString() => 'CopyButtonPlacement($left, $top)';
}

/// Places the copy button for a selection that starts at [anchor] (the top-left
/// of its first cell) and whose last line ends at [selectionBottom], within a
/// [viewport] of the given size.
///
/// The button prefers to sit above the selection so it never covers the text it
/// acts on. When the selection starts too close to the top for that, it flips to
/// just below its first visible line, which is the one case where covering a
/// line beats being unreachable. Horizontally it centres on the anchor and is
/// then clamped so a selection starting at either edge still gets a fully
/// visible button.
///
/// Placement follows the *visible* part of the selection: a long selection whose
/// start has scrolled off the top still gets a button, anchored to the top of
/// what remains on screen. Only a selection with nothing left in the viewport
/// returns null, along with a viewport too small to hold the button at all.
/// Callers treat null as "hide it": a control anchored to text the user cannot
/// see is worse than no control.
CopyButtonPlacement? placeCopyButton({
  required Offset anchor,
  required double selectionBottom,
  required double lineHeight,
  required Size viewport,
  required Size button,
}) {
  // Nothing of the selection is on screen. Checked against its full span rather
  // than its first line, so scrolling the start of a long selection out of view
  // does not take the button with it.
  if (selectionBottom <= 0 || anchor.dy >= viewport.height) return null;

  // Anchor to the first visible line, which is the selection's own start unless
  // that has scrolled above the viewport.
  final visibleTop = anchor.dy < 0 ? 0.0 : anchor.dy;
  final above = visibleTop - button.height - _gap;
  // `above` is the preference; below the line is the fallback when it would sit
  // off the top edge, and is itself rejected when it overflows the bottom.
  final top = above >= 0 ? above : visibleTop + lineHeight + _gap;
  if (top + button.height > viewport.height) return null;

  // A viewport narrower than the button has nowhere to put it.
  final maxLeft = viewport.width - button.width;
  if (maxLeft < 0) return null;
  final left = (anchor.dx - button.width / 2).clamp(0.0, maxLeft);

  return CopyButtonPlacement(left, top);
}
