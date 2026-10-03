# 000155-01 — Phase −1 parse benchmark

## Thinking

The triage-term plan needs a proceed/stop gate: 1 MiB replay frame times on the
Pixel for the xterm 4.0 fork vs xterm2 5.2.0. Proceed with the Rust crate only
if xterm2 misses the frame budget or consistency demands it.

Both packages export a flutter-free core (`package:xterm/core.dart`,
`package:xterm2/core.dart` — verify the latter), so the headless comparison can
run under plain `dart`, JIT and AOT. Different package names mean both deps
coexist in one pubspec: hosted `xterm2: ^5.2.0` next to the `xterm` git
override. No dep swap needed.

Measurement order matters. Headless first: if xterm2 fails the budget on parse
alone, the gate answers "proceed" with no widget work. If xterm2 passes
headless, render cost is the remaining risk and a widget frame bench
(integration_test timeline on the Pixel) decides. Desktop iteration first for
speed; the absolute budget needs the slowest target.

Payload must mimic the real replay path: SGR-heavy agent output at the native
256 KiB budget and the 1 MiB web budget, one-shot (history replay) and 8 KiB
chunks (live stream). Terminal sized like the product (check `maxLines` the
native pane uses) so buffer-trim costs are realistic.

## Plan

1. Add hosted `xterm2: ^5.2.0` to the spike pubspec; `flutter pub get`.
2. Write `tool/parse_bench.dart` (pure Dart): deterministic SGR payload
   generator; arms = {xterm4, xterm2} × {one-shot, 8 KiB chunks} × {256 KiB,
   1 MiB}; warmup + interleaved rounds; report median ms + MiB/s.
3. Run JIT + AOT (`dart compile exe`) on host. Record numbers in the devlog.
4. If xterm2 misses budget headless: gate = proceed, stop benchmarking.
5. Else: widget frame bench via integration_test timeline (visible
   `TerminalView` per package, 1 MiB replay) on desktop, then Pixel.
   Gate = stop (xterm2 swap) if it holds the frame budget; proceed otherwise.
6. Record the decision + numbers in the devlog; commit, push, open PR.
