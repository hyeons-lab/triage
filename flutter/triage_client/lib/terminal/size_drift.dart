/// Whether two terminal sizes disagree, quietly false when either is unknown.
///
/// With nothing to compare, the quiet option is to leave the PTY alone.
bool terminalSizesDrifted({
  required int? aCols,
  required int? aRows,
  required int? bCols,
  required int? bRows,
}) {
  if (aCols == null || aRows == null) return false;
  if (bCols == null || bRows == null) return false;
  return aCols != bCols || aRows != bRows;
}

/// Whether a cached live-grid size disagrees with the shared PTY's size.
///
/// [gridRowsCols] is `(rows, cols)`, matching `getCachedTerminalSize`: the
/// order knowledge for drift checks lives here, in the tested helper, so
/// drift call sites pass the tuple through instead of destructuring it.
/// Companion to `SessionVm.hostSizeDriftedFromOwnFit`: that getter
/// compares the host against the last size this device fitted, so a fit that
/// applied locally but never reached the host (term 46, PTY 80) reads as
/// healthy while rendering narrow. Comparing the view's *actual* grid against
/// the host closes that blind spot and lets the foreground reclaim heal a
/// stuck-narrow grid.
bool cachedGridDriftedFromHost({
  required (int, int)? gridRowsCols,
  required int? hostCols,
  required int? hostRows,
}) {
  if (gridRowsCols == null) return false;
  return terminalSizesDrifted(
    aCols: gridRowsCols.$2,
    aRows: gridRowsCols.$1,
    bCols: hostCols,
    bRows: hostRows,
  );
}
