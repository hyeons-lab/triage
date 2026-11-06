# Plan: Rust VT FFI Core (`crates/triage-term`) + Flutter `TriageRustTerminal`

## Thinking

Even after migrating to `xterm2: ^5.4.0` and applying client-side replay/decompression optimizations, running a full VT100/xterm state machine, UTF-8/ANSI byte-by-byte parser, grapheme width lookup, and soft-wrap reflow loop in Dart on the main UI isolate remains the primary bottleneck during heavy history replay and width reflow.

Meanwhile, `triaged` already uses `tattoy-wezterm-term` (`0.1.0-fork.5`) and `tattoy-wezterm-surface` (`0.1.0-fork.2`) in the Cargo workspace as its authoritative server-side VT engine. Wrapping `tattoy-wezterm-term` in a dedicated C-ABI Rust crate (`crates/triage-term`) and bridging it into Flutter via `dart:ffi` gives the client:
1. Native Rust SIMD-accelerated UTF-8/VT parsing (`advance_bytes`).
2. Native Rust line reflow (`Screen::rewrap_lines`) matching the daemon's exact wrapping and cursor semantics.
3. Dirty-row tracking via `Line::changed_since(seqno)` so only rows modified since the last frame sync are packed and copied across FFI into `BufferLine.data`.
4. Full preservation of Flutter's `TerminalView` / `RenderTerminal` `CustomPainter`, hardware keyboard/IME handling, selection handles, and scroll physics by implementing `TriageRustTerminal extends xt.Terminal` (`package:xterm2/xterm.dart`).

### Key Invariants to Preserve
- **Packed cell layout (`BufferLine.data`)**: Each cell in `xterm2_core` is 4 `uint32` words (`foreground`, `background`, `attributes`, `content`). `crates/triage-term` packs dirty rows directly into this 4-word layout so Dart only performs a bulk `Uint32List.setRange` copy per dirty row.
- **Line wrap flag convention**: WezTerm sets `last_cell_was_wrapped()` on the row that wrapped (`row i`), whereas `xterm2` sets `BufferLine.isWrapped` on the continuation row (`row i + 1`). Therefore, in `crates/triage-term`, row `i` is marked wrapped if and only if `i > 0 && lines[i - 1].last_cell_was_wrapped()`.
- **`BufferLine` object identity across scrollback eviction, `ESC[3J`, and width reflow**:
  - `Screen::phys_to_stable_row_index(0)` tracks the cumulative number of lines evicted or erased from the top of the primary scrollback buffer (`stable_row_index_offset`).
  - When `trimmed_top = current_stable_offset - last_stable_offset > 0`, `TriageRustTerminal` calls `buf.lines.trimStart(trimmed_top)` so evicted/erased `BufferLine` objects have `attached == false` (releasing `TerminalScrollAnchor` and clearing any selection covering erased scrollback).
  - Existing surviving `BufferLine` instances are resized and updated in place rather than replaced wholesale, preserving `identical(terminal.buffer.lines[i], anchored.line)` across width resizes.
- **Graceful fallback**: On web (`dart:js_interop`) or environments where `libtriage_term` is not present, `createTriageTerminal` falls back transparently to `xt.Terminal`.

## Plan

1. **Create `crates/triage-term` in the Cargo workspace**:
   - Add `crates/triage-term` to `Cargo.toml` workspace members.
   - Configure `crate-type = ["cdylib", "staticlib", "rlib"]` with `tattoy-wezterm-term` and `tattoy-wezterm-surface`.
   - Implement `TriageTermEngine` and C-ABI functions (`triage_term_new`, `triage_term_free`, `triage_term_write`, `triage_term_resize`, `triage_term_clear`, `triage_term_set_alt_screen`, `triage_term_sync`, and buffer pointer accessors).
   - Add Rust unit tests in `crates/triage-term` covering SGR colors/attributes, wide CJK/emoji cells, combining characters, auto-wrap + reflow, `ESC[3J` scrollback clear, alt-screen switching, and Mode 2026 synchronized output.

2. **Implement Dart FFI bindings and `TriageRustTerminal` in `flutter/triage_client`**:
   - Create `lib/terminal/triage_term_ffi.dart` (conditional export for native vs web), `lib/terminal/triage_term_ffi_native.dart` (`dart:ffi` loader + `TriageRustTerminal extends xt.Terminal`), and `lib/terminal/triage_term_ffi_stub.dart` (web fallback returning standard `xt.Terminal`).
   - Update `SessionVm._createTerminal()` in `lib/main.dart` and terminal constructors to use `createTriageTerminal(...)`.

3. **Build native libraries & verify test suite**:
   - Build `cargo build --release -p triage-term` for host macOS (`target/release/libtriage_term.dylib`) and copy into `flutter/triage_client/macos/` / discovery path so `flutter test` and macOS desktop automatically load the Rust VT engine.
   - Cross-compile `crates/triage-term` for Android `aarch64-linux-android` and `x86_64-linux-android` into `flutter/triage_client/android/app/src/main/jniLibs/`.
   - Add unit tests in `flutter/triage_client/test/terminal/triage_rust_terminal_test.dart` verifying that `TriageRustTerminal.isNativeAvailable` is true on host and testing VT emulation, reflow, scrollback clear, and cell packing through FFI.
   - Run `cargo test -p triage-term`, `cargo clippy -p triage-term --all-targets -- -D warnings`, `flutter analyze`, and `flutter test`.
   - Build the release Android APK, update the HTTP server artifact, update the devlog, commit, and push to PR #207.
