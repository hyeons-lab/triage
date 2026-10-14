# 000156-01 — Broadcast live output when ingest fails

## Thinking

`handle_output` matches `self.output.ingest(&bytes)`: Ok broadcasts to
clients, Err only warns. The log write lives inside ingest, so a full disk
silently freezes every attached terminal: output never reaches clients and
typing echoes nothing. Bursts (19k failures/hour) align with the reported
typing-lag windows.

The fix decouples liveness from persistence: on ingest error, still
broadcast the raw bytes with the current sequence. Unlogged bytes become
live-only and vanish from served tails on resync, which the client already
handles via full replay. That gap is strictly better than a frozen
terminal.

Design questions to settle from the code: what `ingest` mutates before
failing (output_seq bumped or not), what the broadcast needs
(output_seq, cwd, summarizer tick), and how existing session-actor tests
construct the harness (for the regression test: failed log write still
yields a broadcast).

## Plan

1. Read `OutputState::ingest` + `SessionEvent::Output` consumers; note what
   the Err arm can safely reuse.
2. Implement: Err arm warns (keep diagnostics) then broadcasts live bytes.
3. Add a focused regression test: ingest failure still broadcasts.
   Prove it fails pre-fix if runnable, then green post-fix.
4. `cargo fmt --check`, `cargo clippy -p triaged --all-targets -- -D
   warnings`, focused `cargo test -p triaged`.
5. Devlog, commit, push with explicit refspec, open PR.
