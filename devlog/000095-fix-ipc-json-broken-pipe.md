# 000095 — fix/ipc-json-broken-pipe

## Intent

Recover the one still-relevant fix from the abandoned
`feat/flutter-web-terminal-spike` branch: a client that disconnects mid-write
is logged as an unexpected IPC warning rather than recognized as a normal
disconnect.

Numbered 000095 because 000094 is claimed by the still-open #110.

## What Changed

`is_closed_socket_error` in `crates/triaged/src/ipc.rs` now also recognizes a
closed socket when the root cause is a `serde_json::Error` wrapping the io
error, not only a bare `io::Error`. The kind check is factored into
`is_closed_socket_error_kind` so both paths share it.

Added `json_closed_socket_errors_are_expected_client_disconnects`, which drives
the real `write_json_line` through a writer that returns `BrokenPipe` rather
than asserting against a hand-built error.

## Decisions

- **Kept `root_cause()` rather than walking `error.chain()`.** The original
  spike commit switched to `chain()`, which is broader: it would match an
  `io::Error` anywhere in the chain. `closed_socket_detection_only_matches_root_cause`
  exists to keep a merely *formatted-in* error from counting, and narrowness
  there is deliberate. Adding a second downcast on the root cause fixes the
  real gap without widening the predicate. That test still passes unchanged.
- **Ported by hand rather than cherry-picked.** The source commit (`d1fb470`,
  2026-05-22) is written against `crates/argus-daemon`, which predates the
  rename, and `is_closed_socket_error` has since diverged.
- **Left the rest of the spike branch behind.** Its other two commits add and
  then fix `flutter/argus_client/`, a scaffold superseded the next day by
  `experiment/flutter-spike` (`devlog/000026-experiment-flutter-spike.md`, which
  did land) and long since replaced by the shipped client.

## Issues

The bug reached `main` because the JSON write path had no test. `write_json_line`
goes through `serde_json::to_writer`, so a mid-write disconnect surfaces as a
`serde_json::Error` and the `io::Error` downcast returns `None`. Both existing
tests build their error from a bare `io::Error`, so neither could catch it.

Confirmed against `main` before writing the fix, by calling the real function:

```
PROBE chain: encoding JSON line
PROBE is_closed_socket_error = false
```

## Research & Discoveries

- `feat/flutter-web-terminal-spike` was never opened as a PR and its worktree
  directory was already gone; only the branch ref survived. It was found while
  cleaning up merged worktrees, and kept back from deletion precisely because
  it held unmerged commits.
- `serde_json::Error::io_error_kind()` is the accessor that makes this
  detectable; it returns the underlying `ErrorKind` when the error came from an
  io failure rather than a syntax problem.

## Progress

- 266 workspace tests pass, including all 7 `ipc::tests`.
- `cargo fmt --check` clean; `cargo clippy --workspace --all-targets
  --all-features --locked -- -D warnings` exits 0.
- The pre-existing `closed_socket_detection_only_matches_root_cause` passes
  unchanged, confirming the predicate was not widened.

## Commits

- HEAD — fix(triaged): treat a JSON-encoded broken pipe as a client disconnect

## Next Steps

- `feat/flutter-web-terminal-spike` can be deleted once this merges; nothing
  else on it is still relevant.
- `worktrees/auto-build-flutter-web` can be cleaned up once #111 merges.
