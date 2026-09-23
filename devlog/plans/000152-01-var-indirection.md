# 000152-01: Resolve shell variable program indirection in the approval judge

## Thinking

Muse agents routinely pin toolchains via shell variables:

```bash
export ANDROID_HOME=~/Library/Android/sdk \
  && G95=$(echo ~/.gradle/wrapper/dists/gradle-9.5.1-bin/*/gradle-9.5.1/bin/gradle) \
  && cd <project> \
  && $G95 :app:ktfmtFormat :app:ktfmtCheck ... 2>&1 | grep ... | head -n 12
```

The judge asks on this while literal `gradle :app:ktfmtFormat` allows, because
`$G95` in program position matches no allow rule. Probes through the installed
`triage-hook` confirm: literal allows, `VAR=literal && $VAR ...` asks, and
`VAR=$(echo literal) && $VAR ...` asks.

The fix is single-hop variable resolution inside `JudgeRules::evaluate`:

1. Walk the `&&`/`;`-chained segments of the cleaned command, recording
   `NAME=literal`, `export NAME=literal`, and `NAME=$(echo literal)` assignments.
   `$(...)` values are restricted to `echo` (an identity function over its literal
   argument); every substitution in the command has already been recursively judged
   Allow by the existing pass before segments are evaluated.
2. When a segment's program token (after `effective_tokens`) is exactly `$NAME` or
   `${NAME}` with `NAME` in the map, substitute the literal and run the substituted
   tokens through the unchanged `has_disqualifying_argument` /
   `matching_allow_rule` checks.
3. Propagation barriers keep resolution sound (judge X ⟺ shell runs X):
   - gaps containing `|`, single `&`, `(`, `)`, `{`, `}`, or `;;` break propagation
     (pipeline subshells, background races, conditional branches);
   - a segment records assignments only when neither adjacent gap is a barrier;
   - any control keyword (`if`, `then`, `elif`, `else`, `fi`, `for`, `while`,
     `until`, `do`, `done`, `case`, `esac`, `select`, `function`) as a standalone
     word anywhere disables substitution for the whole command;
   - `unset NAME` drops `NAME` from the map;
   - values containing `$`, backticks, quotes, backslashes, whitespace, or
     delimiter characters are rejected (glob/`~` metacharacters are inert because
     the value is matched opaquely via `program_name`, never re-parsed).
4. Segment alignment between the cleaned and sanitized commands is verified by
   count; on mismatch, substitution is skipped and behavior is unchanged.
5. The matched-rule reason records the indirection (`<rule> (via $NAME)`) so audit
   logs show what was resolved.

Substitution strictly adds Allow verdicts for program tokens that can never match
today (`$` is forbidden in custom rules and absent from builtin tables), so no
existing verdict can change from Allow to anything else.

## Plan

1. **Implement in `crates/triage-core/src/judge_rules.rs`**:
   - Add `is_var_barrier_gap`, `is_shell_identifier`, `recording_blocked` helpers
     plus a `resolve_var_substitutions(cleaned, sanitized)` precompute returning a
     per-segment optional `(name, value)` substitution.
   - Wire it into `JudgeRules::evaluate`'s segment loop: substitute
     `tokens[0]`, then run existing checks; suffix the reason with `via $NAME`.
2. **Add unit tests** in `judge_rules.rs`: literal/var/braced/export/echo-substitution
   allows, the full clipboard-shaped command, and bypass regressions (pipe,
   subshell, `||`, background, conditional branches, non-echo inners, chained
   `$A=$B`, env-prefix non-persistence, unset, reassignment).
3. **Validate**: `cargo fmt`, `cargo clippy --all-targets --all-features -- -D
   warnings`, `cargo test --workspace` (with `TRIAGE_SKIP_FLUTTER_BUILD=1` for the
   Rust-only loop if needed).
4. **Live-verify**: build `triage-hook` and replay the clipboard payload plus the
   bypass cases through it.
5. **Document**: brief paragraph in `docs/approval-judge.md`.
6. Commit, push with explicit refspec, open a draft PR.
