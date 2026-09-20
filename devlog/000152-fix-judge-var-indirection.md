# 000152: Fix approval judge prompts on shell variable program indirection

- **Agent:** Muse Code (muse-spark) @ triage branch fix/judge-var-indirection
- **Agent:** Antigravity (gemini-2.5-pro) @ triage branch fix/judge-var-indirection (2026-09-21T22:45-0700)
- **Intent:** Auto-approve judge verdicts for commands that invoke allowlisted programs
  through shell variables (e.g. `G95=$(echo <gradle-path>) && $G95 :app:ktfmtFormat`),
  which currently fall through to Ask.

## What Changed

- **2026-09-20T11:02-0700** Created worktree and authored plan
  (`devlog/plans/000152-01-var-indirection.md`).
- **2026-09-20T11:34-0700** `crates/triage-core/src/judge_rules.rs`: resolve
  `$NAME`/`${NAME}` program tokens from visible `NAME=literal`,
  `export NAME=literal`, and `NAME=$(echo literal)` assignments in
  `JudgeRules::evaluate`; re-run substituted text through the sensitive,
  credential, network-pipe, and per-segment deny checks; record the indirection
  in the reason (`gradle (via $G95)`). Added 4 unit tests (allows, the reported
  toolchain command, 21 barrier cases, smuggling checks).
- **2026-09-20T11:34-0700** `docs/approval-judge.md`: documented variable
  resolution semantics and limits.
- **2026-09-20T11:34-0700** Validation: `cargo fmt --check`, `cargo clippy
  --all-targets --all-features -- -D warnings`, and `cargo test --workspace`
  (579+ tests) all pass; live-verified the built hook against the reported
  payload (allows) and four smuggling probes (all ask).
- **2026-09-21T22:45-0700** `crates/triage-core/src/judge_rules.rs`: addressed
  findings from multi-agent code review loop at effort max:
  - Rebuilt substituted commands preserve wrapper prefixes (such as `timeout 5`
    and `env`) by replacing the program token in place within word slices.
  - Vetoed variable resolution when wrapper arguments or command arguments
    contain `$` or dynamic substitution placeholders (`SUBST_PLACEHOLDER`).
  - Added subshell and brace scope tracking (`subshell_depth`, `brace_depth`),
    isolating nested block assignments from outer execution chains.
  - Evaluated `denied_segment_rule` prior to `has_disqualifying_argument` for
    indirected segments, preserving specific diagnostic fallback reasons.
  - Consolidated custom deny and built-in sensitive pattern checks into
    `check_denied_command_patterns` on both raw and rebuilt commands.
  - Expanded `is_quoted_or_escaped_var` to catch partial quoting and escaped
    dollar variations (`'$'G`, `"$"G`, `$\G`, `$"G"`, `$'G'`).
  - Added non-vacuous regression tests covering wrapper preservation, argument
    check precedence, credential path protection on indirected programs,
    scope depth isolation, and quoted variable suppression.

## Decisions

- **2026-09-20T11:02-0700 Resolve variables, not tasks**: the reported `ktfmtFormat`
  prompts are not a Gradle grammar gap (literal `gradle :app:ktfmtFormat` already
  allows per `test_gradle_build_commands_are_allowed` and live daemon logs). The Ask
  comes from `$VAR` in program position after `VAR=$(echo <path>)` assignment, so the
  fix is single-hop variable resolution in `JudgeRules::evaluate`, not new task names.
- **2026-09-20T11:02-0700 Soundness over coverage**: substituted tokens are judged by
  the identical allow/deny checks as literal text, so resolution can only reproduce a
  literal verdict, never invent one. Propagation stops at pipe, conditional,
  background, subshell, and control-keyword boundaries so the judge never evaluates
  program X while the shell executes program Y.
- **2026-09-20T11:34-0700 Split record/use barriers**: assignments record only on
  straight-line chains, but uses keep the map across pipes, conditionals, and
  grouping (subshells inherit) and drop it only across background races. A use
  after `|` with a pre-pipeline binding resolves to the true runtime value.
- **2026-09-20T11:34-0700 Arg veto and substituted re-checks**: a program
  resolves only when its arguments carry no `$` references, and substituted
  text re-runs the sensitive-substring, credential, network-pipe, and
  per-segment deny predicates, closing `$G publish`, `curl|$S`, and
  `$G reset --hard` smuggling that the unsubstituted pre-checks cannot see.
- **2026-09-20T11:34-0700 Walk sanitized structure**: the resolver walks
  sanitized segments (whose gaps describe outer-shell flow exactly) and pairs
  `NAME=_subst_` values with extractor output left-to-right, disabled when a
  literal `_subst_` appears in the source. Unquoted `${VAR}` still asks: braces
  are segment delimiters, and only quoted braced references survive intact.

## Commits

- HEAD: fix(judge): resolve shell variable program indirection in allow rules

## Progress

- [x] Worktree and plan initialized
- [x] Implement variable resolution in `triage-core`
- [x] Unit tests including bypass regressions
- [x] Workspace fmt, clippy, and tests pass
- [x] Live verification with `triage-hook`

## Next Steps

- Open a PR; after merge, reinstall the hook and reload the daemon so the
  running judge picks up the new rules.
