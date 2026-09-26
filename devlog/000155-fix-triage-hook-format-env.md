# 000155 — fix/triage-hook-format-env

Uses 000155 rather than 000154: that number belongs to the unmerged
`feat/flutter-client-ux-trio` branch, and reusing it would collide on merge.

## Agent

Muse Code powered by Meta Muse Spark. Session fern-metis, 2026-09-25T19:06-0700.

## Intent

Fix the pre-existing `triage-hook` failure
`tests::detects_antigravity_and_claude_signatures` (fails on pristine main).

## What Changed

- Plan: `devlog/plans/000155-01-hook-format-env.md`.
- `crates/triage-hook/src/main.rs`: added `FormatEnv` snapshot +
  `from_process()`, moved the decision into pure
  `detect_format_with_env`; `detect_format` is now a thin wrapper.
  Payload-signature tests run through `detect_payload_format` (empty env);
  added `session_env_forces_its_agent_over_payload_fields` and
  `explicit_format_override_wins_over_everything`.

## Decisions

- Split `detect_format` into a thin process-env reader plus a pure
  `detect_format_with_env(payload, env)` decision function, instead of
  scrubbing env vars in tests: env scrubbing is process-global mutation that
  races under parallel tests and breaks the moment any test needs the vars
  set.

## Issues

## Commits

- HEAD — fix(hook): make format detection hermetic to ambient env

## Progress

- 2026-09-25T19:06-0700: worktree + branch created, plan written. Root cause
  identified: `MUSE_TOOL_USE_ID` set in the ambient environment (any Muse
  session) forces every payload to `AgentFormat::Muse`.
- 2026-09-25T19:10-0700: fix implemented. `cargo fmt --check`, clippy
  `-D warnings`, `cargo test -p triage-hook` 42/42 green under three
  environments (ambient Muse session, hostile CLAUDE+bogus-override env,
  clean env). Binary smoke-tested on a Claude payload (allows `ls`).
  Left uncommitted for review.

## Research & Discoveries

## Lessons Learned

## Next Steps

- Implement the split, make the payload-signature tests hermetic, add
  env-override tests through the new seam.
- `cargo fmt`, clippy, `cargo test -p triage-hook` — including with
  `MUSE_TOOL_USE_ID` set, which is the failing condition.
