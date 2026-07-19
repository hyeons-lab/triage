# 000091 — build/auto-build-flutter-web

## Intent

Building `triaged` never built the Flutter web client it embeds. `build.rs` only *detected* a
bundle: it set `embed_packaged_client` for a staged `dist/`, `embed_real_client` for
`flutter/triage_client/build/web`, and otherwise silently fell back to the `web_fallback/`
placeholder. Forgetting the manual `flutter build web` step therefore produced a daemon serving
a stale client — or the placeholder — with no signal that anything was wrong.

## What Changed

- `crates/triaged/build.rs` now rebuilds the web bundle when it is missing or stale:
  - Staged `dist/` short-circuits everything (release packaging path, never rebuilt).
  - Source mtimes under `flutter/triage_client/` (`lib/`, `web/`, `assets/`, `fonts/`,
    `pubspec.yaml`, `pubspec.lock`) are compared against `build/web/index.html`; if any is
    newer, run `flutter build web --release`.
  - Skips with a warning when `flutter` is absent from `PATH` or the client sources aren't
    present; `TRIAGE_SKIP_FLUTTER_BUILD=1` is an explicit opt-out.
  - A failing `flutter build web` panics the build script rather than falling back silently.
- `AGENTS.md` documents the behavior and the opt-out under "Build and test commands".

## Decisions

- **Build script over a wrapper script/cargo alias.** The reported problem is *forgetting* the
  step; anything opt-in still has to be remembered. The cost is an mtime scan on each build of
  `triaged` and a ~1m Flutter build when Dart actually changed.
- **`--release`, matching `publish.yml`.** Local builds embed the same bundle shape as shipped
  ones, so the dev loop can't diverge from the released client.
- **Fail loudly on a broken Dart build.** Silently embedding a stale bundle is the exact failure
  mode being fixed, so a broken client build must not be papered over. `TRIAGE_SKIP_FLUTTER_BUILD=1`
  is the escape hatch when the daemon needs to build regardless.
- **Watch sources, not build outputs.** Emitting `rerun-if-changed` for `build/web` (as the old
  script did) marks the crate dirty right after the build script regenerates it. Source mtimes
  determine the bundle's content anyway, so watching them alone is sufficient and stable.
- **`.dart_tool` is excluded** from the watch walk — Dart tooling rewrites it constantly, which
  would defeat the staleness check.

## Issues

- Found and fixed a pre-existing bug: `build.rs` unconditionally emitted
  `cargo:rerun-if-changed=dist`, but `dist/` only exists during release packaging. Cargo treats a
  watched path that is missing as permanently dirty, so `triaged` recompiled on *every* build.
  Confirmed via `CARGO_LOG=cargo::core::compiler::fingerprint=info`
  (`stale: missing .../crates/triaged/dist`). `dist` is now watched only once it exists, with the
  crate root watched so staging a `dist/` is still noticed. Steady-state `cargo check -p triaged`
  went from ~2.1s (recompiling) to ~1.0s (no work).

## Progress

- 2026-07-18T20:30-0700 — Verified each branch of the new logic:
  - bundle missing → runs Flutter build (1m24s), emits `embed_real_client`
  - sources unchanged → no Flutter invocation, no recompile
  - Dart source touched → rebuilds (~40-77s)
  - `TRIAGE_SKIP_FLUTTER_BUILD=1` with stale sources → skips
  - staged `crates/triaged/dist/` with stale sources → packaged path, no Flutter invocation

  Validated with `cargo fmt --all -- --check`, `cargo clippy -p triaged --all-targets` (clean),
  `cargo test -p triaged` (124 passed, 1 ignored), and `cargo build -p triaged`.

## Next Steps

- None required. If the ~1m release build proves too slow for Dart-heavy iteration, a debug-mode
  bundle for local builds is the obvious follow-up, at the cost of diverging from `publish.yml`.
