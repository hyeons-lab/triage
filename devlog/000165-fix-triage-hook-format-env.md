# 000165: fix/triage-hook-format-env

## Intent

Fix the pre-existing `triage-hook` failure
`tests::detects_antigravity_and_claude_signatures` (fails on pristine main when ambient agent session environment variables are set).

## What Changed

- Plan: `devlog/plans/000165-01-hook-format-env.md`.
- `crates/triage-hook/src/main.rs`: added `FormatEnv` snapshot with
  `from_process()` and `from_os_parts()`, moved the decision into pure
  `detect_format_with_env`; `detect_format` is now a thin wrapper.
  `from_os_parts()` uses `args_os()` and `var_os()` non-empty checks so
  non-UTF-8 arguments never panic and empty environment variables (`KEY=""`)
  do not falsely activate session overrides.
  Payload-signature tests run through `detect_payload_format` (empty env);
  added `session_env_forces_its_agent_over_payload_fields`,
  `explicit_format_override_wins_over_everything`, and
  `format_env_from_os_parts_ignores_empty_vars_and_tolerates_non_utf8`.

## Decisions

- Split `detect_format` into a thin process-env reader plus a pure
  `detect_format_with_env(payload, env)` decision function, instead of
  scrubbing env vars in tests: env scrubbing is process-global mutation that
  races under parallel tests and breaks the moment any test needs the vars
  set.
- 2026-10-18T21:40-0700 Use `args_os()` and `var_os()` non-empty checks in
  `FormatEnv::from_os_parts`: `std::env::args()` panics on non-UTF-8 OS
  arguments (violating `triage-hook`'s fail-open exit-0 contract), and
  `std::env::var(...).is_ok()` treats cleared empty strings (`KEY=""`) as
  set while rejecting non-UTF-8 paths in `CLAUDE_PROJECT_DIR`.

## Commits

- 409f530: fix(hook): make format detection hermetic to ambient env
- HEAD: fix(hook): use panic-free OsString args/env lookup and renumber devlog

## Progress

- 2026-09-25T19:06-0700: worktree + branch created, plan written. Root cause
  identified: `MUSE_TOOL_USE_ID` set in the ambient environment (any Muse
  session) forces every payload to `AgentFormat::Muse`.
- 2026-09-25T19:10-0700: fix implemented. `cargo fmt --check`, clippy
  `-D warnings`, `cargo test -p triage-hook` 42/42 green under three
  environments (ambient Muse session, hostile CLAUDE+bogus-override env,
  clean env). Binary smoke-tested on a Claude payload (allows `ls`).
- 2026-10-18T21:40-0700: rebased onto `feat/scrollback-serve`, renumbered
  devlog/plan to `000165`, switched `FormatEnv::from_process` to `args_os`
  and non-empty `var_os` checks via `from_os_parts`, and added unit tests for
  empty and non-UTF-8 OS inputs.
