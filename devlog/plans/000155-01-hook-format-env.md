# 000155-01 — Hermetic hook format detection

## Thinking

`detect_format` mixes two inputs: the hook payload (a pure function of its
argument) and the ambient process environment (`TRIAGE_HOOK_FORMAT`,
`--format=` argv, `CLAUDE_CODE_VERSION`/`CLAUDE_PROJECT_DIR`,
`MUSE_TOOL_USE_ID`). The payload-signature unit tests assert pure-payload
behavior but run with the ambient environment inherited, so they fail
whenever that environment names an agent: inside a Muse session
(`MUSE_TOOL_USE_ID` set) every payload detects as Muse, and inside Claude
Code the Muse/Antigravity assertions would fail symmetrically.

Scrubbing the vars in the tests is the small diff but the wrong fix: env
mutation is process-global and racy under parallel tests, and it silently
breaks when a future test needs the vars set. Splitting the env read from
the decision keeps production behavior identical (one call site builds the
env snapshot) while tests drive the pure function with explicit env —
hermetic under any ambient environment, with no new dependencies.

## Plan

1. Add a `FormatEnv` snapshot struct (`argv_format`, `env_format`,
   `claude_env`, `muse_env`) with `from_process()` reading `std::env`.
2. Move the decision into `detect_format_with_env(val, env)`; keep
   `detect_format(val)` as the thin wrapper used by the production call
   site.
3. Switch the payload-signature tests to `FormatEnv::default()` (empty env)
   and add override tests through the seam (env/agent flags win over
   payload fields).
4. Validate: `cargo fmt`, clippy `-D warnings`, `cargo test -p triage-hook`
   with and without `MUSE_TOOL_USE_ID` set.
