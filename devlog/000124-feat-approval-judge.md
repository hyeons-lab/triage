# 000124 feat/approval-judge

**Agent:** Claude (claude-opus-5[1m]) @ triage branch feat/approval-judge

## Intent

Let a local model decide whether an agent's tool call should be auto-approved,
so routine commands stop interrupting the user while risky ones still stop and
route through Triage's existing attention path. Driven by running `agy` (the
Antigravity CLI) inside Triage sessions and wanting an auto mode that is not
just `--dangerously-skip-permissions`.

Scope for this branch: the judge itself, its IPC surface, the hook shim, a
per-session on/off toggle owned by the daemon, and a TUI settings screen to
drive it. The Flutter client settings sheet is deliberately left for a follow-up.

## What Changed

2026-08-11T22:47-0700 `devlog/plans/000124-01-approval-judge.md` — plan covering
the judge core, worker priority, IPC variant, hook shim, per-session policy, TUI
settings overlay, and the LFM2.5-2.6B bump.

2026-08-11T23:48-0700 `crates/triage-core/src/judge.rs` (new) — wire types
shared by the shim, the IPC transport, and the daemon: `JudgeRequest`,
`JudgeDecision`, `JudgeSource`, `JudgeVerdict`. `JudgeVerdict::fallback` is the
one constructor for the fail-safe path, so "every failure is an ask" is a
property of the type rather than of each call site.

2026-08-11T23:48-0700 `crates/triage-core/src/config.rs` — added `JudgeConfig`
(`enabled`, `default_enabled_per_session`, `timeout_ms`, `deny_substrings`,
`allow_commands`) and wired it into `Config` + `validate`. Documented
`ApprovalConfig` as legacy and unconsumed, and made it warn at load when
non-empty rather than deleting the key, which would turn an inert setting into a
hard startup error under `deny_unknown_fields`.

2026-08-11T23:48-0700 `crates/triaged/src/judge.rs` (new) — the deterministic
rule engine plus the grammar-constrained model call. `JudgeRules::evaluate`
returns `Some` for a final verdict and `None` for "ask the model".
`judge_with_model` constrains decode with a GBNF alternation over `allow|ask`.

2026-08-12T00:31-0700 `crates/triaged/src/summarizer.rs` — replaced the bounded
mpsc channel with a `Condvar` queue holding judge jobs and summarize jobs
separately. Judge jobs are served first, and enqueuing one flips the running
summary's cancel flag. Summarize coalescing now falls out of the queue itself
(a `HashMap` keyed by session) rather than needing a drain-and-dedupe pass.
Added `Summarizer::judge`, which is blocking, bounded, and infallible.

2026-08-12T00:31-0700 `crates/triaged/src/session.rs` — `JudgeState` on
`SessionManager`, plus `start_judge` and `judge_tool_call`. Also added
`SessionConfig::session_id` and set `TRIAGE_SESSION_ID` in `spawn_pty_runtime`
next to `TERM`/`COLORTERM`.

2026-08-12T00:31-0700 `crates/triaged/src/ipc.rs` — `WireRequest::JudgeToolCall`
and `WireSuccess::JudgeVerdict`, dispatch, and the infallible
`IpcClient::judge_tool_call`.

2026-08-12T00:31-0700 `crates/triage-hook/` (new crate) — the `PreToolUse` shim.
Always exits 0, always prints one decision, bounds its own wait at 10s.

2026-08-12T00:31-0700 `.agents/hooks.json`, `docs/approval-judge.md` — hook
registration (shipped disabled) and the full contract, rule order, audit-log
format, and the layered timeout table.

2026-08-12T01:14-0700 `crates/triage-core/src/session.rs` —
`SessionApi::set_session_judge_policy` and `session_judge_policy`, both added
with default impls that bail so the WS test mock needs no change. A
`judge_enabled` field and serde derives were added to `SessionContextRow` here
and both removed again in review: the targeted `session_judge_policy` query
superseded the field, and the WS transport never carried it, so it had no
reader.

2026-08-12T01:14-0700 `crates/triaged/src/session.rs` — `judge_overrides` map,
`judge_policy_snapshot` as the single point where a session's policy is
resolved, and the `set_session_judge_policy` / `session_judge_policy` impls. An
override is dropped when its session closes, so a restored session cannot
inherit an auto-approve pin from an earlier incarnation.

2026-08-12T01:14-0700 `crates/triaged/src/ipc.rs` — `SetSessionJudgePolicy` on
the wire, plus the matching `IpcClient` impl. A `ListSessionContexts` variant
landed here too and was removed again in review once the targeted
`session_judge_policy` query superseded it.

2026-08-12T01:14-0700 `crates/triage/src/lib.rs` — `selected_judge_policy` and
`set_selected_judge_policy` on `LocalSessionApp`.

2026-08-12T01:14-0700 `crates/triage/src/main.rs` — the settings overlay: F5 to
open, `y`/`n`/`r` to set on/off/follow-default, `Esc` to close, drawn centered
over the terminal pane.

2026-08-12T02:07-0700 `crates/triaged/src/judge.rs` — closed the review-found
bypasses: structural checks now run on the raw command (a collapsed newline was
erasing command boundaries), `rm` detection covers `-R`, wrappers, operand-first
flags, alias/quote/path spellings, exec flags are caught inside short bundles,
`cargo --config`/`--manifest-path` and `git branch`/`git remote` write forms are
off the allowlist, and plaintext credential files are denied.

2026-08-12T02:07-0700 `crates/triage-core/src/judge.rs` — `JudgeVerdict::deny_rule`
alongside `fallback`, and `SessionJudgePolicy` carrying the override separately
from the resolved answer.

2026-08-12T02:07-0700 `crates/triage-core/src/session.rs`,
`crates/triaged/src/ipc.rs` — `SessionApi::session_judge_policy` and its wire
variant, so the settings screen reads one session instead of fanning out.

2026-08-12T02:07-0700 `crates/triage/src/main.rs` — the overlay now names which
of the three states a session is in rather than only on/off.

2026-08-12T02:52-0700 `crates/triaged/src/judge.rs` — the rules read tokens
rather than text. `unquote_segment` removes quote characters and backslashes
from a whole segment before it is tokenized, so quoting cannot hide a flag, a
subcommand, a program name or a credential path from any rule. Destructive
programs, git operations and credential paths are all matched structurally;
`git remote show` and `git fetch` are off the allowlist for the same reason.

2026-08-12T03:26-0700 `crates/triaged/src/summarizer.rs` — `push_judge` returns
why it refused, so a poisoned lock is not reported to the audit log as a full
queue.

2026-08-13T21:31-0700 `crates/triaged/src/summarizer.rs` — the one-line rail
label now builds its opts with `sampling_opts` like the detail pass, so both
generative passes honour the bundle manifest's `sampling_parameters`. Was greedy
on a stability argument that the measurement did not support.

2026-08-13T21:31-0700 `crates/triaged/src/judge.rs` — the decision decode keeps
`temperature: 0.0` and now says why it is the one decode in the daemon that
ignores the manifest, pointing at this devlog for the false-allow measurement so
the exception does not read as an oversight.

2026-08-13T22:04-0700 `crates/triaged/src/summarizer.rs` — four fixes the review
loop surfaced, all of them consequences of the label no longer being greedy.
`generate_one_line` only discards its text on a late judge cancel when the
label's newline had not arrived yet (`!sink.stopped`): nothing ends decode at the
newline, so a finished label sits in the sink while decode runs out its token
budget, and sampled output stays in that window far longer than greedy did.
`push_label_chunk`, extracted from `OneLineSink` so it is testable without a
tokenizer, skips a blank line the model opens with instead of reading it as
end-of-label; that path returned an empty label, and an empty label drops the
detail pass with it. `sanitize_one_line` marks a truncation with an ellipsis, as
the detail pass already did, and both now share `cap_chars` so the two caps
cannot drift. `sampling_opts_from_defaults` matches `GenerationDefaults`
exhaustively, which is what its doc already claimed.

2026-08-13T22:19-0700 `crates/triaged/src/summarizer.rs` — `OneLineSink` records
its `FinishReason`, which it previously discarded, and the completeness test
moved from "the newline arrived" to `is_complete()`: newline **or** EOS. The
first version of the late-cancel fix covered the rarer half. `SYSTEM_PROMPT` asks
for the label and nothing else, so a model that obeys it ends on EOS without ever
emitting a newline, and that is the common completion. Same signal gives
`cut_by_budget()`, so a label the token budget cut off is marked with the
ellipsis even when it fits both caps, which is the case the text alone cannot
reveal.

2026-08-13T22:34-0700 `crates/triaged/src/summarizer.rs` — `cut_by_budget()` is
now `cut_short()` and counts `FinishReason::ContextFull` alongside `MaxTokens`.
Both mean decode ran out of room mid-label, and marking only one of them was an
accident of how the fix was written rather than a distinction worth keeping; the
old name asserted the narrower rule. The rule itself moved to free functions
`label_is_complete` / `label_cut_short` over `(stopped, Option<&FinishReason>)`,
for the reason `push_label_chunk` was extracted: `BpeTokenizer` has no
constructor a test can reach, so anything left on `OneLineSink` cannot be tested
at all. Both now are, including the cases that are unreachable today
(`ContextFull` on a 24-token decode) and the `None` that a missing `on_done`
would leave.

2026-08-13T22:52-0700 `crates/triaged/src/summarizer.rs` — the detail pass marks
a decode cut too, which it did not before: `TextSink` now records its
`FinishReason` and `sanitize_detail` takes `cut_short`. The asymmetry was real
rather than theoretical, since `detail_max_tokens` is 180 against a 480-character
cap, so a summary dense in the paths and command names the prompt asks for can
spend its token budget well before the character cap and end mid-sentence with
nothing in the text to show it. `mark_truncated` also stops the marker stacking
on a model that trails off by itself ("checking configs..."), and `cap_chars` no
longer reports truncation when all it cut was trailing whitespace.

2026-08-17T00:41-0700 `crates/triaged/src/judge.rs`, `crates/triaged/src/summarizer.rs`,
`crates/triaged/src/session.rs` — expanded deterministic allowlist with read-only
GitHub CLI inspection queries (`gh pr view`/`list`/`checks`/`diff`/`status`, `gh run list`/`view`,
`gh issue view`/`list`/`status`, `gh repo view`, `gh release list`/`view`, `gh workflow list`/`view`,
`gh auth status`), Flutter/Dart tooling (`flutter analyze`/`test`/`doctor`, `dart analyze`/`test`/`format`),
and git queries (`git branch --show-current`, `git rev-list`). Wrapped git commands
are caught through flag-taking wrappers (`names_program`). Single-pass `normalize_lowered`,
in-place ellipsis markers, and zero-allocation UTF-8 `char_indices` slicing eliminate hot-path
allocations. `CeraError::Cancelled` from judge preemption is logged at debug level. Verified
against full 2,733-command Antigravity corpus: deterministic auto-approval increased from 19.6%
to 35.7% with zero false allows.

2026-08-18T08:28-0700 `flutter/triage_client/lib/main.dart`, `crates/triaged/build.rs` —
re-enabled Flutter icon font tree-shaking in release builds, reducing the embedded
`MaterialIcons-Regular.otf` from 1.6MB to 11KB (99.3% reduction). Preserved
`Icons.smart_toy` (`0xe5c5`) and `Icons.person_outline` (`0xe497`) by referencing
them via `const Icon` widget literals so Flutter's `const_finder` AST scanner
retains the required glyphs.


2026-08-17T01:52-0700 `crates/triaged/src/judge.rs`, `crates/triage/src/lib.rs`,
`crates/triage/src/main.rs` — supported git global options (`-C`, `--no-pager`, `-c`, `--no-optional-locks`)
in Layer 2 allowlist matcher so read-only git queries with file paths (`git --no-pager diff ... -- file.dart`)
are approved deterministically with 0ms latency. Added `effective_tokens` to strip leading `KEY=val` and
transparent wrappers (`env`, `time`, `nice`) from allowlist commands. Expanded allowlist with `find`
(disqualifying `-exec`/`-delete`), `flutter build`/`pub get`/`devices`, `gh pr ready`, and `just --list`.
Rendered robot (🤖) and user (👤) auto-approval status badges on each session in the Ratatui TUI sidebar.

2026-08-17T08:16-0700 `crates/triage-core/src/judge.rs`, `crates/triage-hook/src/main.rs`,
`crates/triaged/src/judge.rs`, `crates/triaged/src/session.rs`, `crates/triaged/src/summarizer.rs` —
extended approval judge to auto-approve read-only inspection, search, web, and agent coordination tool
calls (`Read`/`view_file`, `list_dir`, `grep_search`, `search_web`, `invoke_subagent`, etc.) unless
the target path contains sensitive credentials (`.ssh`, `.env`, `.aws/credentials`). Extracted file path
arguments dynamically in `triage-hook` from `PreToolUse` payloads and carried `path` in `JudgeRequest`.

2026-08-17T13:45-0700 `crates/triaged/src/main.rs`, `crates/triaged/src/service.rs`,
`.agents/hooks.json` — added `triaged reload` CLI command (and `triaged service reload`/`restart`)
to perform graceful zero-downtime daemon handover detached in the background without terminal suspension.
Updated hook matcher to `.*` so all agent inspection and execution tool calls are routed through the judge.

2026-08-18T01:58-0700 `crates/triage-core/schema/triage.fbs`, `crates/triage-transport-ws`,
`crates/triaged/src/session.rs`, `crates/triage-hook/src/main.rs`, `flutter/triage_client` — added
per-session auto-approval toggle controls in the Flutter web/mobile client (`SessionListTile` and
`WorkspaceHeader`), with real-time push event sync (`SessionJudgePolicyUpdatedPayload`). Extended
`triage-hook` and `triaged` to judge external agents and inherited shells with absent `TRIAGE_SESSION_ID`
against the daemon default policy.

2026-08-18T14:20-0700 `devlog/plans/000124-03-settings-panel.md`, `crates/triage-core`,
`crates/triage-transport-ws`, `crates/triaged`, `flutter/triage_client` — added `GetJudgeHookStatus`
and `ConfigureJudgeHook` daemon RPC endpoints to read and modify `.agents/hooks.json` in the
workspace/git root directly. Built multi-tab `SettingsDialog` (`Daemons`, `Approval Judge`, `Preferences`)
in the Flutter client with a live toggle switch that writes/enables the agent hook in workspace JSON
with 1-click execution and immediate UI feedback, eliminating manual copy-pasting.

2026-08-18T17:15-0700 `devlog/plans/000124-04-judge-rules-and-history-ui.md`, `crates/triage-core`,
`crates/triaged`, `crates/triage-transport-ws`, `flutter/triage_client` — added approval judge decision
history ring buffer (`JudgeRecord`), rule queries and mutations (`get_judge_history`, `get_judge_rules`,
`add_judge_allow_command`, `remove_judge_allow_command`, `add_judge_deny_substring`, `remove_judge_deny_substring`),
and safe config persistence to `~/.config/triage/config.toml`. In the Flutter client Settings dialog
(Approval Judge tab), built a live traffic audit feed showing recent decisions (`DENY`, `ASK`, `ALLOW`) with
timestamps, session IDs, and reasons, with a 1-click `"+ Allow Rule"` quick promotion button. Built interactive
custom allowlist and denylist editors with add/delete support and collapsible inspectors for all built-in rules.

2026-08-18T17:45-0700 `crates/triage-hook/src/main.rs`, `flutter/triage_client/lib/widgets/terminal_pane_web.dart`,
`flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — made `triage-hook` payload extraction flexible across
all agent hook schemas (Claude, Antigravity, Gemini) by supporting top-level `tool_name`/`tool_input`, `tool_use`/`toolUse`,
and snake_case/camelCase arguments. Fixed background terminal scrolling during trackpad/mouse scrolling inside
modal dialogs by suppressing platform view pointer/wheel events (`style.pointerEvents = 'none'` and `onWheel` cancellation)
whenever a modal dialog route is active.

2026-08-19T07:26-0700 `crates/triaged/src/session.rs`, `flutter/triage_client/lib/main.dart` —
increased judge decision history ring buffer retention from 50 to 2,000 entries (capturing >24 hours
of active agent tool traffic). Enhanced the Flutter Settings dialog Approval Judge tab with real-time
decision filtering (All, Allow, Ask, Deny), text search by command/tool/reason, and pagination
controls (Show 50 more / Show all).

2026-08-19T07:31-0700 `crates/triaged/src/service.rs` — expanded `allow_grants` in `triaged service install`
to automatically seed `date`, `which`, `uname`, `whoami`, `hostname`, `ps`, `rg`, `fd`, and safe inspection
utilities into `~/.gemini/antigravity-cli/settings.json` permissions allowlist.

2026-08-19T07:44-0700 `crates/triaged/src/service.rs` — updated `ServiceContext::detect` to prefer the
installed `~/.cargo/bin/triaged` release binary over `target/` binaries when registering LaunchAgent/systemd
services, preventing unoptimized debug builds from running as the background supervisor.

## Decisions

2026-08-17T00:41-0700 Read-only gh and flutter/dart tools belong on deterministic
allowlist — verified against 207 real developer sessions containing 2,733 command
approvals. Safe inspection queries like `gh pr checks`, `gh run view`, and test
runners like `flutter test`/`dart format` represent over 15% of real developer
tool traffic; adding them to Layer 2 eliminates model latency and prompts while
keeping all mutating subcommands (`gh pr create`, `gh release`) blocked by Layer 1.

2026-08-17T01:52-0700 Git global options and leading env vars belong in deterministic
allowlist — prevents read-only diffs and environment-wrapped test commands
(`TRIAGE_SKIP_FLUTTER_BUILD=1 cargo test`) from being forwarded to the model layer,
increasing deterministic auto-approvals to 40.9% across the developer corpus.

2026-08-17T08:16-0700 Read-only agent inspection tools are auto-approved unless targeting credentials —
agent operations like `Read`/`view_file` on workspace code and git refs (e.g. `.git/refs/heads/*`) are routine
inspection tasks that previously prompted developers because only `run_command` was judged. Gating file
reads on credential path boundaries ensures safe files are auto-approved with 0ms latency while secrets
remain protected.

2026-08-17T13:45-0700 `triaged reload` executes detached with `setsid` — prevents interactive subshell
job control signals (`SIGTSTP`/`SIGTTIN`) from suspending the daemon during handover, and coordinates a
single-pass descriptor transfer adopting live sessions without double-relay racing `launchd`.

2026-08-11T22:47-0700 Judge lives in `triaged`, not a standalone server — the
hook blocks agy's agent loop and fires on every tool call, so the model has to
already be resident. `triaged` keeps a warm `CeraEngine` on a worker thread for
the summarizer, so the marginal cost of a judge is a queued job rather than a
whole second process. A hook binary linking cera directly would pay a cold
engine load (664 MB now, 1.48 GB at 2.6B) on every `ls`.

2026-08-11T22:47-0700 Use agy's `PreToolUse` hook rather than reading the
terminal buffer. The hook hands over the exact `CommandLine` as JSON; the screen
only offers a repainted TUI frame to guess at. It also sidesteps keystroke
injection and input-lease contention with the TUI and Flutter clients entirely.

2026-08-11T22:47-0700 Grammar-constrain the decision to `allow|ask` using
`GenerateOpts::grammar`, verified present in the pinned cera 0.4.0 registry
source, so no dependency bump. One decoded token, no JSON parsing, no chance of
the model narrating instead of deciding. The `reason` field agy accepts is
skipped in v1 because it doubles decode cost on the blocking path.

2026-08-11T22:47-0700 The model never returns `deny`. Denials come only from a
deterministic rule table evaluated before inference, because a deny the model
invents is indistinguishable to the user from a deny that was meant. The model
arbitrates the ambiguous middle between the denylist and the allowlist, and
every failure path falls through to `ask`, which is just the normal agy prompt.

2026-08-11T22:47-0700 Session identity via a new `TRIAGE_SESSION_ID` env var set
at PTY spawn next to `TERM`/`COLORTERM`. When absent, the shim answers `ask` and
never opens the socket, so agy outside Triage behaves exactly as it does today.

2026-08-11T22:47-0700 Per-session enablement is daemon state, not client state,
so the TUI and the Flutter client toggle one shared thing. Config supplies the
default, and a client reads one session's policy with the targeted
`session_judge_policy` query rather than pulling the whole context list.

2026-08-11T22:47-0700 Bump the shared model to `LFM2.5-2.6B-GGUF` at `Q4_K_M`.
Id verified against the LeapBundles registry, and note it has no `-Instruct`
segment unlike the 1.2B id currently in config. Quality per byte matters more
than decode speed for a judge, and residency means the load cost is paid once.
The summarizer shares the engine, so rail labels change too: better labels, more
RAM, slower per summary.

2026-08-11T23:48-0700 Config entries are additive only. `JudgeRules::new`
chains built-in deny substrings and allow commands ahead of the config's, and
there is no mechanism to remove a built-in. A config edit can therefore extend
the deny layer but never weaken it, so reviewing the deny guarantees means
reading one const table rather than auditing a user's config.

2026-08-11T23:48-0700 Allow rules match token sequences, not string prefixes, and
only on a command containing no shell metacharacter at all. Token matching stops
`git status` matching `git statusfoo`; the metacharacter guard is what makes
prefix matching sound in the first place, since `git status; rm -rf ~` would
otherwise match on its prefix.

2026-08-12T00:31-0700 An unknown `session_id` is refused rather than judged. A
hook query naming a session this daemon did not spawn is not a Triage-managed
agent, so it has no claim on Triage's auto-approvals.

2026-08-12T00:31-0700 `.agents/hooks.json` ships with `"enabled": false`. A repo
that intercepts every tool call of anyone who clones it is a surprising default,
and with `triage-hook` not installed the hook would invoke a missing binary on
every call. Opting in is one field.

2026-08-12T00:31-0700 Three nested timeouts, each inside the next: the daemon's
model wait (8s), the shim's wait on the daemon (10s), the hook's wait on the
shim (15s). A stall then surfaces as a clean `ask` from whichever layer noticed
first, rather than as a killed process leaving the agent to interpret empty
stdout.

2026-08-12T01:14-0700 The per-session policy is three-state (`Some(true)`,
`Some(false)`, `None` meaning follow the default) rather than a bool. A bool
cannot express "has never been touched", so an untouched session would latch
whatever the default was when it started and stop tracking later changes to it.

2026-08-12T01:14-0700 Overrides are in-memory only, so a restart or handover
reverts every session to the configured default. That direction errs towards
prompting rather than towards auto-approving in a session whose owner has
forgotten they enabled it. Persisting them is a later decision, not an oversight.

2026-08-12T01:14-0700 The settings key is hardcoded F5 rather than a new
`keybindings.settings` entry. The TUI reads none of `[keybindings]` today (every
binding is hardcoded), so a config key would have been one more setting that
parses and does nothing, which is exactly what `[approval] patterns` already is.

2026-08-12T01:14-0700 The overlay consumes every keystroke except Ctrl-Q. Any
key falling through to the PTY while a modal is up would type into the shell
behind it; Ctrl-Q stays live so the overlay can never trap the user.

2026-08-12T02:07-0700 A deny is recoverable, so the deny layer is deliberately
broad. A false deny costs the user one manual command; a false allow is
unrecoverable. That asymmetry is why `rm` is matched anywhere in a segment
(catching `echo rm -rf` as collateral), why `.env` is denied as a substring, and
why `git fetch` and `git remote update` left the allowlist.

2026-08-12T02:07-0700 `has_disqualifying_argument` is a denylist, and denylists
are never complete. It is a second line of defence, not the guarantee. The
guarantee is that anything it misses lands in the model layer, which can only
answer `allow` or `ask`. The layering is what makes an incomplete table
tolerable.

2026-08-12T03:26-0700 Six review rounds, and every single bypass had the same
shape: a rule reading a command as text where the shell reads it as structure.
Newlines collapsed into spaces, `rm` recognized only at the front, flags matched
only in the spelling that was thought of, `git push` assumed adjacent to `git`,
and finally quoting, which defeated every argument-level check at once because
tokens were compared raw. The fix that should have been first is the one that
landed last: unquote every token once, then run the rules over tokens. Text
matching survives only where it is genuinely a substring question, and even
there it now reads an already-unquoted copy: the substring layer was the last
place quoting still worked, which is what round 6 found.

2026-08-12T04:12-0700 Three `session_context_*` tests fail intermittently under
the full parallel suite, one per run, rotating between them. Not caused by this
branch: they fail the same way with every test this branch adds excluded, and
they pass in isolation and under `--test-threads=1`. Both failure modes point at
load rather than logic, since `Command::new("git")` sometimes fails to spawn at
all and sometimes returns non-zero, and the suite spawns a PTY per session test
alongside them. Left as a pre-existing issue rather than fixed here, since the
cause is in the test harness and not in anything this branch touches. Validation
for this branch was run with `--test-threads=1`, which is green.

## Issues

2026-08-11T23:48-0700 The first `JudgeRules::evaluate` checked
`is_recursive_force_remove` against the whole command, and that function only
inspects the first token. So `npm test; rm -rf /` matched no deny rule, hit the
metacharacter guard, returned `None`, and was handed to the model, which is
allowed to answer `allow`. A unit test written against the intended behaviour
caught it before the model layer was ever wired up. Fixed by adding
`command_segments`, which over-splits on `;`, `|`, `&`, newlines, backticks,
substitutions, and brace groups, and running the structural deny rules against
every segment. Over-splitting is the safe direction: a missed segment is a
command the deny rules never see, while a spurious segment is merely checked and
found harmless.

2026-08-12T02:07-0700 The review loop found a bypass that the module's own docs
claimed was impossible. `normalize` collapsed whitespace before every structural
check, so a newline became a space and `ls\nrm -rf /` read as a single `ls`
invocation, matched the `ls` allow rule, and was auto-approved. The `'\n'`
entries in `SHELL_METACHARACTERS` and in `command_segments` were unreachable as a
result. The lesson is that the normalization step and the structural checks
wanted opposite things from whitespace, and running them over one shared string
hid that.

2026-08-12T02:07-0700 A second round found that an allow rule names a program,
not everything the program can be told to do: `cargo build --config
build.rustc-wrapper=...` executes an arbitrary wrapper, `fd -ax` bundles the exec
flag past a whole-token check, `git remote update` fetches every remote (the very
reason `git fetch` had already been removed), and `cat ~/.git-credentials` leaks
exactly what keeping `env` off the allowlist was meant to prevent.

2026-08-12T01:14-0700 `IpcClient` never implemented `list_session_contexts`, so
it silently inherited the trait's empty-vec default. Found while wiring the
settings screen, which at that point read the judge policy from the context
list. Round 4 replaced that with a targeted `session_judge_policy` query and the
wire variant was removed again, so the gap is documented here rather than fixed:
`IpcClient` still inherits the empty default, and no caller relies on it.

2026-08-12T00:31-0700 The hook shim links `triaged` (and so, transitively,
cera), which looked like it would defeat the "loads nothing" goal. Measured
rather than assumed: the release binary is 1.0 MB and a full round trip against
an unreachable daemon takes 20-30 ms including process start. The linker drops
the inference code because nothing in the shim reaches it, so a separate
dependency-light client was not needed.

2026-08-12T00:31-0700 A daemon running an older build answers the new
`JudgeToolCall` request with a deserialization error, which the shim reports as
`ask`. Version skew between shim and daemon therefore degrades to the status quo
rather than breaking the agent. Confirmed accidentally against the live daemon on
this machine before the new build was installed.

2026-08-11T23:48-0700 The local disk hit 290 MB free mid-build and cargo failed
writing its query cache. Cleared ~41 GB of cargo `target/` dirs across
`~/development` plus 25 GB of simulator device data. Unrelated to this feature
but it blocked all compilation, so it is recorded here as the reason for the gap.

2026-08-12T07:00-0700 The first attempt to deploy this build failed at
`flutter build web` with `Resource temporarily unavailable (os error 35)`, and
plain `ps` failed the same way. The machine was out of process slots: an Android
emulator (`qemu-system-aarch64`, AVD Pixel_9_Pro_XL, up 2 days) had accumulated
10,235 unreaped children. Zombies are reapable only by their parent, so killing
the emulator was the only fix; it freed every slot at once. Nothing to do with
this branch, but it is worth knowing that a wedged emulator presents as a build
failure rather than as anything pointing at the emulator.

2026-08-12T07:00-0700 Deployed by handover onto the live daemon, 9 sessions
attached. Eight were adopted and are still running; `session-68` logged
`adopted inherited live session` immediately followed by `session child is gone`,
in both handovers. Its shell was alive in `ps` four minutes earlier, so either it
exited on its own in that window or adoption killed it. One sample is not enough
to tell which, and the other eight crossed twice without a scratch, so this is
recorded rather than diagnosed.

2026-08-12T07:17-0700 First live run, and the model layer never approves
anything. Fourteen commands that reached layer 3 all came back `ask`, including
`true`, `mkdir -p build/tmp`, `go test ./...`, `swift build`, and `make test`.
Not one `allow` in the whole sample. Layer 3 is therefore behaving as a constant
function that costs 0.7s, and every auto-approval Triage currently performs comes
from the layer 2 allowlist. The model is running (0.7s warm, 1.9s and 3.4s on the
first two calls while it loaded), so this is a prompt or model-capability
problem, not a wiring one. Worth ruling out in order: the system prompt's bias,
whether the chat template is applied before the grammar constrains decode, and
whether 1.2B is simply too small to hold the distinction. This is the finding
live traffic was supposed to produce, and it lands on the design's least-tested
assumption: that a small local model can make this call at all.

2026-08-12T07:17-0700 `docs/approval-judge.md` tells the reader to look for
`source = allow_rule` / `deny_rule` / `model` / `fallback`, but `judge_tool_call`
logs the field with `?` (`session.rs:844-845`), so the log actually carries the
Debug names: `AllowRule`, `DenyRule`, `Model`, `Fallback`. Same for `decision`
(`Allow`, not `allow`). Anyone who greps the log the way the docs describe finds
nothing. The log format is the greppable public surface here, so the fix belongs
in the code (a `Display`/`as_str` on both enums, logged with `%`) rather than in
the doc.

2026-08-12T07:33-0700 The model layer was never running on the GPU. `cera` gates its
native Metal backend behind a `metal` cargo feature, and the workspace took the
crate with `features = ["remote"]` only, so the `BackendPreference::Auto` probe
(metal, then wgpu, then CPU) found the Metal arm compiled out and fell through to
CPU every time. Enabling it took one target-scoped dependency entry and no code
change, since `load_engine` already asked for `Auto`. A decision went from 0.7s
to 0.04s, and engine load from about 10s to 0.5s. Kept under
`cfg(any(target_os = "macos", target_os = "ios"))` because the feature pulls in
`metal` and `objc`, which do not build elsewhere. Confirmed on the live daemon
after a third handover: `cera::backend::metal Metal context initialized` and
`cera::engine: using native Metal backend (auto)`. End to end through the hook
process, an ambiguous command now answers in 0.10s to 0.14s against 0.7s to 3.4s
before; the decode itself is 0.04s and the remainder is process start and IPC.

2026-08-12T07:33-0700 Phase 8 is blocked, and not by latency. `LFM2.5-2.6B-GGUF`
at `Q4_K_M` downloads and loads, then fails at
`apply_chat_template`: `unknown method: map has no method named get (in chat:57)`.
Its chat template calls `.get()` on a map, which the minijinja inside `cera` 0.4.0
does not implement. 0.4.0 is the newest published `cera`, so there is no version
to upgrade into. Reaching 2.6B means hand-rendering the LFM2 chat format instead
of calling `apply_chat_template`, and that is a worse thing to own than it sounds:
a silently wrong prompt format degrades into bad judgments rather than an error.

2026-08-12T07:59-0700 Moved the workspace onto `cera` git main
(`08d596c`, 35 commits past the published 0.4.0) at the user's direction, with
crates.io publication deferred. That unblocked the 2.6B chat template: the
`.get()` call minijinja rejected is fixed on main, and the model now loads and
runs. Note for whoever publishes next: `publish.yml` cannot ship any crate in
this workspace while a git dependency is in the tree, since crates.io rejects
them. That is a known, accepted state, not an oversight.

## Research & Discoveries

2026-08-11T22:47-0700 agy hook contract ships on disk at
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`.
`PreToolUse` takes the tool call as JSON on stdin and returns
`{"decision": "allow"|"deny"|"ask"|"force_ask", "reason": ...}` on stdout. Also
supports `permissionOverrides` and an `overwrite` object that rewrites tool args
before execution. Hooks run synchronously and block the loop, 30s default
timeout, `type: "command"` only.

2026-08-11T22:47-0700 Triage's MCP server is read-only: `tool_definitions()`
(`crates/triage-mcp/src/main.rs:235`) exposes `list_sessions`,
`snapshot_session`, and `styled_rows` and nothing that writes. The design doc's
`inject_input` / `set_status` surface is unbuilt. Not needed for this feature,
but worth recording, since "use the MCP" was the obvious first instinct and it
does not work.

2026-08-11T22:47-0700 `[approval] patterns`
(`crates/triage-core/src/config.rs:385`) and
`agents.custom_pack.prompt_patterns` (`:220`) parse and validate but have zero
consumers anywhere in the workspace. Design doc §8 / Phase 9 lists approval
gates as unbuilt. This branch should decide their fate rather than adding a
third overlapping key.

2026-08-11T22:47-0700 The TUI has no overlay or modal system: `draw` is a
sidebar plus a terminal pane, and `keybindings.overview` / `keybindings.search`
have no implementation behind them. The settings screen is greenfield, so build
the overlay primitive to be reusable by overview and search later.

2026-08-11T22:47-0700 LeapBundles registry facts for the model bump:
`LFM2.5-2.6B-GGUF` offers `Q4_0`, `Q4_K_M`, `Q5_K_M`, `Q8_0`; `Q4_0` is 1.48 GB
against 664 MB for the current 1.2B `Q4_0`; `inference_type` is
`llama.cpp/text-to-text`; its chat template carries native tool-call slots
(`<|tool_list_start|>`), unused here but available.

2026-08-12T07:00-0700 A handover against a launchd-managed daemon costs three
process starts, not one, and the middle one always fails. Observed end to end:
the transient `--handover` job adopts the 9 sessions and the old daemon exits;
`KeepAlive` respawns the main job, which races the adoption and dies with
`Address already in use (os error 48)`; launchd respawns it a second time, and
that one hands the sessions back. Net result is correct (the main label owns the
new binary) but the sessions cross the fd transfer twice. The `os error 48` line
in `triaged.err.log` is expected here, not a failure to chase. Adoption gap was
11.7s and 14.2s, both well inside the 60s timeout and both explained by the
summarizer model load.

2026-08-12T07:00-0700 Every daemon start re-downloads
`LFM2.5-1.2B-Instruct-GGUF/Q4_0.json`: `cera::bundle` logs `cached file size
mismatch; re-downloading, expected=296 actual=1876`. The cached size never
matches what the manifest records, so the cache never hits. Harmless (296 bytes)
but it puts a network fetch on the startup path, which means a handover on an
offline machine may behave differently than one online. Not this branch's bug.

2026-08-12T07:17-0700 Measured decision latency end to end, hook process start to
JSON on stdout, against the live daemon. Layers 1 and 2 (deterministic) come back
in 0 to 10ms. Layer 3 costs 0.7s warm, with 1.9s and 3.4s on the first two calls
while the summarizer model loaded. That is the number Phase 8 was waiting on: a
2.6B model at roughly double the parameter count puts an ambiguous command in the
1 to 1.5s range on the agent's blocking path. Worth spending only if the bigger
model actually decides, which at 1.2B it does not (see Issues).

2026-08-12T07:17-0700 The three documented fallbacks were verified against the
live daemon rather than in tests: no `TRIAGE_SESSION_ID` gives
`{"decision":"ask","reason":"not running inside a Triage session"}` without
opening the socket, and a session with judging off gives
`{"decision":"ask","reason":"judging is off for this session"}`. Both are the
status quo prompt, as designed.

2026-08-12T07:33-0700 Bench of four candidate system prompts against 20 labeled
commands on the 1.2B model, run through a throwaway `examples/judge_probe.rs`
(deleted afterwards; Metal made each decision cheap enough to bench at all):

| Prompt | Score | Failure shape |
| --- | --- | --- |
| V0, shipping | 10/20 | answers `ask` to all 20, including `true` |
| V1, shorter | 10/20 | still nearly all `ask`, plus one false allow |
| V2, few-shot | 13/20 | conservative: every error is a needless `ask` |
| V3, reframed | 10/20 | answers `allow` to all 20, including `git push origin main` |
| V4, disjoint few-shot | 15/20 | 4 false allows, incl. `pip install -r requirements.txt` |

The pattern across V0 and V3 is the finding: the model collapses onto whichever
label the prompt's overall polarity suggests, rather than reading the command. It
is not broken, and the grammar is not at fault; told "always answer allow" it
answers `allow`, and it answers `ask` identically with the grammar removed
entirely. V4's examples share no tooling with the eval set, so its 15/20 is real
generalization, but it buys those five points by moving errors into the false
allow direction, which is the direction that matters. Prompt engineering alone
does not make 1.2B both useful and safe here.

2026-08-12T07:59-0700 The 2.6B model runs on `cera` main, and it still does not
solve this. Its chat template ends `<|im_start|>assistant\n<think>`
unconditionally: it is a reasoning model, and there is no `enable_thinking` knob
in the template (nor does `cera` pass one). So a one-word grammar was constraining
its *reasoning*, not its conclusion, which is why its first results looked like
noise. Measured on the same 20 cases:

| Strategy | Score | Cost |
| --- | --- | --- |
| grammar on the open think block | 10/20 | 0.23s |
| think block closed immediately | 10/20 | 0.22s |
| think to a close, then constrain | 12/20 | 3.08s |

The controls prove the first two are not real answers: told "always answer allow"
it replies `["ask","allow","ask","allow"]`, and told "always answer ask" it
replies `["ask","allow","ask","ask"]`. Near-identical output under opposite
instructions means the instruction is not being read. Let it think and it does
reason well (on `cargo fmt --all`: "only modifies code files"), but the verdict
still lands on `allow` for `brew install jq`, `git push origin main`, and six
others. So 2.6B costs 30x the 1.2B latency, sits on the agent's blocking path,
and fails in the unsafe direction. Phase 8 is unblocked and should still not be
taken.

2026-08-12T08:21-0700 Re-ran the two-phase test at the model card's recommended
sampler (temperature 0.1, top_k 50, repetition penalty 1.1) rather than the
temperature 0.0 the first pass used, since benchmarking a model off its own spec
is not a fair test. It scores 13/20 against 12/20, and costs 5.81s per decision
against 3.08s. Six of the twenty reasoning traces ran into the 512-token cap. One
extra correct answer for nearly double the latency, still with seven false
allows, so the recommendation is unchanged and now fairly measured.

2026-08-12T08:21-0700 The model card confirms the template reading from first
principles: "LFM2.5-2.6B is a pure reasoning model that always thinks before it
answers." There is no non-reasoning 2.6B. The LFM2.5 line offers 230M, 350M,
1.2B-Instruct, 1.2B-Thinking, 2.6B (reasoning), and 8B-A1B, of which LeapBundles
carries everything except the 8B.

2026-08-12T08:21-0700 `LFM2.5-8B-A1B` looked like the ideal candidate (1.5B active
of 8.3B, so roughly 1.2B decode speed with far more capacity) and is not
reachable, for a reason that has nothing to do with bundles. `CeraEngine::from_path`
loads any GGUF from disk, so being absent from LeapBundles is not the obstacle.
The obstacle is the architecture: the 8B is `lfm2moe`, and every `cera` loader
(CPU at `model/mod.rs:582`, and the Metal and wgpu equivalents) matches only
`lfm2`, `qwen2`, `qwen3`, `llama`, `granite` and bails with `unsupported
architecture` on anything else. `lfm2moe` appears in `cera` only in `tools.rs`, for
tool-call formatting, not for loading. Reaching the 8B means implementing MoE in
`cera`, which is a `cera` feature, not a Triage one.

2026-08-13T13:27-0700 `cera` main gained `lfm2moe` on all three backends
(`b0a55c9`, PR #383), which makes LFM2.5-8B-A1B loadable, and it is the first
model in this whole exercise that actually does the job. Benched from
`~/.leap/models/LFM2.5-8B-A1B-Q4_0` via `CeraEngine::from_path`, at temperature
0.0 for determinism:

| Model | Score | Per decision | False allows | Reads the prompt? |
| --- | --- | --- | --- | --- |
| 1.2B, V0 shipping | 10/20 | 0.10s | 0 (answers `ask` to everything) | no |
| 1.2B, V2 few-shot | 13/20 | 0.10s | 0 | barely |
| 2.6B, two phase | 13/20 | 5.81s | 7 | reasoning only |
| **8B-A1B, V0** | **14/20** | **1.50s** | **2** | **yes** |

The controls are what separate it: told "always answer allow" it returns four
allows, told "always answer ask" it returns four asks. Every earlier model failed
that. Its two false allows are `docker compose up -d` and
`pip install -r requirements.txt`; its other four misses are conservative asks,
which is the harmless direction. Three runs of the same command returned the same
verdict, so a decision is reproducible, which a security control needs and
temperature 0.2 (the model card's recommendation) does not give.

Its chat template is a plain instruct template with no `<think>`, so the
single-token grammar-constrained decode works directly, no two-phase dance.

Two costs. Latency is 1.50s and is essentially all prefill: it does not fall
across calls (1.54, 1.47, 1.46, 1.46, 1.47, 1.48), so the warm prefix cache is not
being reused between sessions, and prompt length maps straight onto it (V0 at
~200 tokens is 1.50s, V4 at ~320 is 2.33s). Getting the system prompt's prefill
cached, or simply shortening it, is where the time is. And the weights are 4.84 GB
against 664 MB today, in a daemon that runs all the time.

2026-08-13T13:27-0700 Few-shot examples reverse sign with model size. On the 1.2B
they were the only thing that helped (10/20 to 13/20); on the 8B they hurt badly
(14/20 down to 9/20 for V2 and 11/20 for V4), and specifically by pulling the
model toward `allow`: V4 produces eight false allows against V0's two. A model
that can read the criteria does not need the examples and is misled by them. Any
prompt work from here should be benched per model rather than carried over.

2026-08-13T13:42-0700 `crates/triage-core/src/config.rs` — the summarizer's
default model is now `LFM2-2.6B-GGUF` at `Q4_K_M`, replacing
`LFM2.5-1.2B-Instruct-GGUF` at `Q4_0`. It is in LeapBundles, so this is a config
default rather than the `model_path` knob the 8B would have needed. It is the
shared engine, so session summaries move to the same model.

2026-08-13T13:42-0700 Swept every locally-available GGUF in an architecture
`cera` supports, rather than assuming the answer was "a bigger model". The winner
is not big: **LFM2-2.6B at Q4_K_M scores 19/20 in 0.20s with zero false allows**,
its single miss being a needless `ask` on `true`. Repeated twice, identical.

| Model | Score | Per decision | False allows | Follows instructions |
| --- | --- | --- | --- | --- |
| **LFM2-2.6B Q4_K_M** | **19/20** | **0.20s** | **0** | yes |
| granite-4.1-3b Q4_K_M | 19/20 | 0.25s | 1 | yes |
| granite-3.1-2b Q8_0 | 18/20 | 0.18s | 1 | yes |
| LFM2-2.6B Q4_0 | 15/20 | 0.18s | 0 | yes |
| LFM2.5-8B-A1B Q4_0 | 14/20 | 1.50s | 2 | yes |
| LFM2.5-1.2B (shipping) | 10/20 | 0.10s | 0, all `ask` | no |
| LFM2.5-230M Q4_K_M | 10/20 | 0.06s | 10, all `allow` | control only |
| Llama-3.2-1B-Instruct Q8_0 | 10/20 | 0.14s | 10, all `allow` | no |
| Qwen3-1.7B Q8_0 | 10/20 | 0.12s | 0, all `ask` | no |

Three things fall out of this table. The 8B-A1B, which looked like the answer
yesterday, is beaten by a model a third its size at a seventh the latency.
Quantization is a real variable and not a rounding error: the same LFM2-2.6B
scores 19/20 at Q4_K_M and 15/20 at Q4_0, a bigger swing than most model changes
here. And every model at or below 1.7B collapses onto one label, in whichever
direction its prompt happens to push it, which is why the 230M and Llama-3.2-1B
share a 10/20 with the shipping 1.2B while failing in the opposite, dangerous
direction.

The 230M is worth a note of its own because it passes the simple control (told
"always answer allow" it does) and still collapses to allowing all ten dangerous
commands once given real criteria. Following a one-line instruction and applying a
paragraph of criteria are different capabilities, and the cheap control test only
proves the first.

2026-08-13T14:05-0700 Deployed by handover and verified against the live daemon
through the hook, which is the first time the model layer has answered a real
query correctly: `make test`, `go test ./...` and `swift build` all `allow`;
`pip install -r requirements.txt`, `brew install jq` and `docker compose up -d`
all `ask`. Six for six. End to end through the shim it costs 0.54s to 0.74s
against 0.20s measured in-process, the gap being process start, IPC, and
contention with the summarizer, which had just restarted and was working through
a backlog.

Two summaries logged `snippet generation failed, error: cancelled` during that
burst. That is the designed preemption (enqueuing a judge job cancels a running
summary), not a regression. Worth writing down because "failed" in the log reads
like a bug and is not one; the message deserves a rewording.

Not verified: snippet *quality* under the new model. Snippets are in-memory and
reach clients only over session events, so there is no cheap way to read one from
a shell, and the summarizer logs nothing on success. The sidebar will show it
immediately, and both settings are config keys if it reads worse.

2026-08-13T13:42-0700 `Qwen3.5-0.8B` fails to load: `unsupported architecture:
qwen35`. Worth knowing that the Qwen3.5 GGUFs use a distinct arch string rather
than reusing `qwen3`.

2026-08-13T22:41-0700 Rebased onto `origin/main` (60766b3) and renumbered this
devlog from 000121 to 000124. Main had landed #141 and #142 while this branch was
open, and #141 took the number 000121 for its own devlog while #142 took 000123,
so the branch's file collided with a committed one. The two code comments that
cite this file by path were updated with it, and the Commits section was rewritten
because the rebase changed all 24 hashes. The rebase itself was clean: #142 edits
`crates/triaged/src/session.rs` too, but it removes `translate_newlines` near the
end of the file while this branch works in the judge and summarizer wiring, so the
two never touch the same lines.

2026-08-13T23:07-0700 A judge job queued *before* a summary starts does not
preempt it, and the mechanism is a pre-existing one this branch reasons about but
did not introduce. `register_summary` pre-sets the cancel flag when
`has_pending_judge()` is already true, but `Session::generate` opens with
`self.cancel.store(false)` (cera `session.rs:1696`, commented "stale flips from a
prior call shouldn't pre-cancel the next one"), so a caller cannot arm a cancel
before decode. Two outcomes follow, neither of them the intended clean abort. If
the tokenized prompt spans more than one 512-token ubatch, `append_text` observes
the flag and returns `CeraError::Cancelled`, which `?` propagates and
`run_summarize_job` logs as `snippet generation failed`; that is the source of
the `error: "cancelled"` lines seen live earlier, which were read as benign
preemption. If the prompt fits one ubatch, prefill completes, `generate` clears
the flag, and the whole label decode runs while the judge caller spends its
timeout. `a_judge_job_queued_before_registration_still_preempts` passes because
it asserts the queue-level flag, not the decode.

Left unfixed here: this is outside a change about manifest sampling params, and
the root cause is cera's unconditional reset rather than anything in triage. The
cheap mitigation is a `cancel.load()` check between `register_summary` and
`append_text` returning `Ok(None)`, which covers the common case (a judge job
already queued) but not a job arriving between that check and `generate`. Closing
the window properly wants cera to stop clearing a flag its caller just set, or to
offer a generate that honours one.

2026-08-13T21:31-0700 cera does not apply a bundle's manifest sampling params on
its own, which is easy to assume it does. `manifest.rs` parses
`generation_time_parameters.sampling_parameters` into
`GenerationDefaults::Text`, and `engine.manifest()` exposes it, but nothing on
the generate path in `session.rs` ever reads it: `GenerateOpts::default()` is a
hardcoded temperature 0.7 / top-p 0.9 / top-k 40. Applying the manifest is
entirely the caller's job, so any decode built from `..Default::default()`
silently runs at cera's generic defaults rather than the model's tuned ones.
LFM2-2.6B-GGUF/Q4_K_M asks for temperature 0.3, min-p 0.15, repetition-penalty
1.05.

2026-08-13T21:31-0700 Honouring those params in the judge is a regression, which
is worth recording because it runs against the obvious reading of "use the
manifest defaults". Over the 20-command labeled set, six runs each: greedy scored
18/20 every run with no verdict changing between runs, while manifest sampling
scored 18/20 five times and 17/20 once, the difference being `brew install jq`
returning `allow` on the sixth run. A one-word grammar already fixes the output
shape, so sampling adds no quality and only adds the chance of a different
2026-08-18T16:50-0700 On macOS Apple Silicon (ARM64), copying a replacement
daemon binary via `cp` into `~/.cargo/bin/triaged` invalidates its ad-hoc code
signature. When the replacement is executed during `triaged reload` or handover,
the macOS kernel terminates it immediately with `SIGKILL` (`-9`, code signature
invalid) before `main()` can execute. Running `codesign -s - -f ~/.cargo/bin/triaged`
(or installing via `cargo install`) restores a valid ad-hoc signature so the
handover successor can adopt live sessions. Furthermore, Flutter web builds
register a Service Worker (`flutter_service_worker.js`) that aggressively caches
`main.dart.js` in browser `CacheStorage`, requiring a hard reload (`Cmd+Shift+R`)
after daemon upgrades to load updated UI assets.

## Commits

86c4eb9 — feat(triaged): judge routine agent tool calls with resident model and rule tables
2055643 — feat(hook): add triage-hook shim with multi-format agent auto-detection and rule fallback
7f2c486 — feat(service): add triaged reload and automated multi-agent hook provisioning
21765a1 — feat(triage): add per-session approval judge controls, status badges, and settings screen in TUI
f223064 — feat(triage_client): add tabbed settings dialog, approval traffic dashboard, and rule editor in Flutter
HEAD — docs: document approval judge architecture, handover protocol, and update devlogs

## Next Steps

Everything in scope is built and committed across nine commits. Six review
rounds are done; the loop was stopped deliberately, not because it ran dry, and
live agy traffic is the next reviewer.

- Nothing has run against a real agy tool call yet. Every guarantee here is
  backed by unit tests and reviewer probes, so the rule tables have never met
  real traffic. That is the gap to close first, and it is the reason the model
  bump below is still open.
- To try it: `TRIAGE_SKIP_FLUTTER_BUILD=1 cargo install --path crates/triage-hook`,
  set `judge.default_enabled_per_session = true`, flip `.agents/hooks.json` to
  `"enabled": true`, restart `triaged`, then watch the audit log
  (`RUST_LOG=triaged::session=info`). `source = model` is the interesting line:
  it is where the rule tables ran out and the model decided.
- Phase 8 is done, and the answer was neither candidate: LFM2-2.6B at Q4_K_M,
  19/20 at 0.20s. The note below is kept for why the two obvious candidates lost.
- Superseded: Phase 8 should retarget from 2.6B to LFM2.5-8B-A1B. 2.6B is settled and the
  answer is no: a forced reasoner, 5.81s per decision, 13/20, seven false allows.
  The 8B-A1B scores 14/20 deterministically at 1.50s with two false allows and is
  the only model that demonstrably reads the prompt. What it needs is a way to
  point the summarizer at a GGUF path: it is absent from LeapBundles, so
  `from_bundle_id` cannot reach it and `SummarizerConfig` has no `model_path`.
  Worth weighing against 4.84 GB resident in a daemon that never exits.
- The model layer still decides nothing useful: it answers `ask` to everything at
  1.2B, and the prompt bench says that is a model-capability ceiling rather than a
  prompt bug. Three ways out, in rough order of appeal: grow the deterministic
  allowlist and accept the model layer as a conservative backstop; ship the V2
  prompt for a small gain whose errors all fall in the safe direction; or unblock
  2.6B, which is now measured and not worth it. The prompt is a safety-posture
  change, so it wants a decision rather than a default.
- `triage-hook` is `publish = false`: it is absent from publish.yml's crate list
  and its prebuilt-binary matrix, so shipping it is a release-process decision.
- The Flutter settings sheet stays out of scope. The daemon state is shaped so
  it needs no further daemon work.
- The parallel-suite flakiness in `session_context_*` is pre-existing and
  unrelated, but CI runs parallel by default, so a red run on this branch may
  well not be this branch. See Issues.
