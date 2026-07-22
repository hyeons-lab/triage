# 000103 — feat/rail-row-identity

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/rail-row-identity

## Intent

Sessions in the side rail are hard to tell apart when several are running on the
same repo. Make an individual rail row carry enough identity to pick the right
session at a glance, without introducing grouping.

Scoped from a longer design conversation that considered restructuring the rail
to group repo worktrees under one entry. That grouping work is deliberately
deferred — see Decisions.

## What Changed

- 2026-07-22T08:40-0700 `flutter/triage_client/lib/main.dart` — `SessionVm.railTitle`
  (branch, else worktree, else repo, else cwd leaf, else title) now feeds the rail tile,
  leaving `displayTitle` and the workspace header repo-first; `_gitMeta` renders the repo
  as context and drops any component the title already promoted, so no component appears
  twice on a tile; the LLM snippet moved above the status line and out of the dimmest
  tier; `SessionVm.snippetUpdatedAt` is stamped in the `session_snippet_updated` handler
  and rendered as a compact relative time, blank when absent. Adds the pure helpers
  `worktreeEchoesBranch`, `indistinguishableRailRows` and `formatRelativeActivity`, and a
  `glanceTitle` on `SessionListTile` so the hover card keeps the repo-first name.
- 2026-07-22T08:40-0700 `_RelativeActivityText` runs a 30s ticker so the label ages from
  "2m" to "3m" in place, gated behind the existing `runningUnderFlutterTest()` because a
  never-ending periodic timer fast-forwards fake-async time and hangs `pumpAndSettle`.
  An earlier draft added a third env probe (`periodicUiTickersEnabled`) for this; review
  showed it was `!runningUnderFlutterTest()` spelled differently, so it was dropped and
  `platform_env_{io,web}.dart` are untouched.
- 2026-07-22T08:40-0700 `flutter/triage_client/test/session_rail_identity_test.dart` (new)
  and `test/widget_test.dart` — unit coverage for each helper's boundaries, plus three
  widget guards on the split itself: the workspace header still renders `displayTitle`,
  the rail's tiles carry `railTitle`, and a repo session whose meta line empties is not
  rendered as pathless. Each is verified by mutation — reverting the behaviour it guards
  makes it fail — rather than assumed to bite.
- 2026-07-22T09:08-0700 `flutter/triage_client/lib/main.dart` — second review round: the
  tile's `Semantics(label:)` and the collapsed rail's tooltip both take the repo-first
  name, `railTitle`'s tail delegates to `displayTitle` instead of restating its fallbacks,
  and four doc comments were corrected or trimmed.

## Decisions

- 2026-07-21T16:03-0700 Row identity before grouping — Grouping by repo
  addresses clutter, not findability: it collects the indistinguishable sessions
  into one bucket and hides them behind a disclosure control. The stated problem
  ("hard to find the right session when several are on the same repo") is
  intra-repo disambiguation, which is a row-level concern. Row fixes are also
  strictly cheaper — no daemon, protocol, or new interaction model. Whether
  grouping is still wanted afterwards is left open on purpose.

- 2026-07-21T16:03-0700 Rail gets its own title getter rather than changing
  `displayTitle` — `displayTitle` has two call sites: the rail tile
  (`main.dart:3361`) and the workspace header (`main.dart:4552`). Only the rail
  suffers the repo-first redundancy; in the header "repo · worktree" is correct,
  since it is the sole statement of where you currently are and has no sibling
  to disambiguate against. Splitting keeps the header intact.

- 2026-07-21T16:03-0700 Activity time from `session_snippet_updated`, with no
  backfill, renders blank — There is no timestamp on the wire:
  `SessionSnapshot` (`triage-core/src/session.rs:100`) carries `output_seq` and
  `bytes_logged` only, and the daemon's `last_tick_at`
  (`triaged/src/session.rs:1849`) is a non-serializable `Instant`. But
  `session_snippet_updated` is pushed for *any* session by id, not just the
  attached one (`main.dart:2079`), so stamping it client-side gives background
  rows a real signal for free. It has no history, so after a connect or
  reconnect a row has no stamp until it next moves. Rendering nothing in that
  case is honest; a fabricated or stale-looking time is worse than blank.

- 2026-07-21T16:03-0700 Jump palette binds platform application chords, not a
  leader — Settled while planning this branch so it is not re-litigated when the
  palette PR opens. A pty cannot encode Cmd and cannot distinguish
  `Ctrl+Shift+K` from `Ctrl+K`, so GUI application chords collide with the shell
  by construction — which is exactly why iTerm2, Terminal.app, GNOME Terminal
  and Windows Terminal all use that space. The palette therefore needs no mode
  and no leader. A tmux-style leader plus sticky mode is still wanted, but is
  driven by the TUI, which has no spare modifier space; designing it against the
  harder client is the right order, and the Flutter client can honour the same
  leader afterwards for parity. Browser caveat recorded below.

- 2026-07-21T16:03-0700 Palette and grouping are separate PRs — Independent
  changes, and they review far better apart.

## Issues

- 2026-07-21T16:03-0700 **Pre-existing TUI defect, filed for the leader work.** `key_to_command`
  (`crates/triage/src/main.rs:1581`) is evaluated *before* `key_to_input` (line
  1618) and unconditionally claims `Ctrl+W` (readline unix-word-rubout),
  `Ctrl+N` (next-history), `Ctrl+Q` (XON/flow control), PageUp/PageDown
  (scrollback in any full-screen app inside the session — vim, less, htop) and
  F2–F4 (mc, htop). There is no passthrough, so **there is currently no way to
  send `Ctrl+W` to your shell through the Triage TUI.** Not fixed here; it is
  pre-existing and orthogonal to the rail. To be fixed when the leader grammar
  lands, which must include literal passthrough (double-press) and a binding
  that disables client chords entirely.
- 2026-07-22T08:40-0700 This devlog was written as `000098` and had to be renumbered to
  `000102`. `000098` was already taken **twice** on `main` — `000098-fix-session-shell-fallback`
  (#115) and `000098-fix-adopted-master-fd-leak` (#116) both landed under it, so the
  collision is not hypothetical and has already merged. `000099`–`000101` are likewise
  spoken for (#117, #118, and the open #119). Picking a number when a branch *starts*
  reserves nothing: several branches in flight all read the same highest number and all
  choose the next one. The number is only safe once chosen against `main` immediately
  before the PR opens, which is what happened here.
- 2026-07-22T09:33-0700 …and `000102` collided anyway, which disproves the rule I had just
  written. PR #120 (`docs/adopted-master-drop-timing`) opened with
  `000102-docs-adopted-master-drop-timing.md` from the same `main`, so both PRs picked the
  next free number correctly and independently and still clashed. Choosing against `main`
  is not sufficient, because `main` cannot see open PRs; the only reliable check also
  enumerates in-flight branches (`git ls-remote --heads` / `gh pr list`, then the devlog
  names on each). Renumbered to `000103` — #120 opened first, so this branch is the one
  that moves. This is the third `000098`-class collision on this repo in a week; a
  numbering scheme that requires every author to poll every open PR is the actual defect,
  and a date- or branch-derived name would remove it entirely.
- 2026-07-22T08:40-0700 The work sat uncommitted in its worktree with no branch commit and
  no PR. Nothing was on the remote, so a `git worktree remove` — the routine cleanup after
  a merge — would have destroyed all of it, including the devlog and plan that record why
  the design is the way it is. Committing early costs nothing and is the only thing that
  makes the work survivable.
- 2026-07-22T08:52-0700 **Review found a real regression in the meta line.** `_gitMeta`
  drops any component the title already promoted, so a repo session whose `railTitle`
  *is* the repo — a detached HEAD in a main checkout, or a branch named after its repo —
  ends up with an empty meta line. `build()` was keying off `gitMeta != null` to decide
  between the git icon and the `folder_outlined` + absolute-cwd fallback, so those
  sessions rendered as though they had no git context at all. Fixed by keying that
  decision off `repoName` instead: an empty meta line and an absent repo are different
  facts and only the second should change the icon. The trap is that `_gitMeta` went from
  "the git summary" to "the git summary *minus what the title said*" without the
  null-check downstream being revisited — a returned null quietly changed meaning.
- 2026-07-22T08:52-0700 Two of three reviewers reported that `indistinguishableRailRows`
  joins its group key with a space and so could collide. It does not: the separator is a
  literal `\x00`, which renders invisibly in the source, and both reviewers read the
  gap as a space. Confirmed with `cat -v` (`^@`) — and `rg` flagging `main.dart` as a
  binary file is the same byte showing up. Left unchanged. Agreement between reviewers is
  not evidence when they share a way of misreading the input.
- 2026-07-22T08:52-0700 Review also caught that the plan's step-6 regression guard —
  "header still renders `displayTitle`" — was never written, while the devlog claimed it
  as delivered, and that the two existing widget tests asserted their own setup: they
  built a `SessionListTile` by hand, passed `a.railTitle` in, and asserted it came back
  out, which stays green if `SessionRail` reverts to `displayTitle`. Both are now covered
  against the real widgets.
- 2026-07-22T08:52-0700 Hosting `SessionRail` bare in a test harness does not work: its
  reorderable list throws `!childSemantics.renderObject._needsLayout` during the
  semantics pass and renders no tiles. The rail guard therefore runs against the full app
  (`TriageClientApp` + the fake client), which is how the pre-existing rail tests already
  do it. Worth knowing before trying to unit-test that widget again.
- 2026-07-22T08:52-0700 Nearly shipped a self-inflicted deletion: the regex removing
  `periodicUiTickersEnabled` from `platform_env_io.dart` was anchored on
  "/// False under `flutter test`", which is *also* the first line of
  `marqueeAnimationsEnabled`'s doc comment, so the non-greedy match started at the wrong
  function and took both. The compiler caught it immediately, but a text-level edit that
  matches on prose is only as unique as the prose — anchor on the identifier.

- 2026-07-22T09:08-0700 **The change quietly degraded screen-reader output**, and only a
  second review round caught it. The tile's `Semantics(label:)` passed `widget.title`,
  which used to be the repo-first `displayTitle` and is now a bare branch — so two rows on
  `main` in different repos announce identically, which is the exact failure this branch
  exists to fix, reintroduced on the one surface that has no meta line to compensate. The
  collapsed rail's tooltip had the same shape of problem. Both now take the repo-first
  name. The lesson: promoting a field in the visual hierarchy is not a visual-only change
  — every consumer of the old value inherits the new meaning, including the ones that
  render no pixels.
- 2026-07-22T09:08-0700 My own mutation-verification claim was overstated. Of the rail
  guard's two assertions only one could ever fail: the loop asserting no tile title starts
  with `"triage · "` is vacuous against these fixtures, which seed `context.branch` but no
  `repository_root`, so `displayTitle` degenerates to the stable title and can never
  produce that prefix. The guard held on the other assertion alone. Replaced with the
  string the fixtures actually produce. Running a mutation proves *a* test fails; it does
  not prove every assertion in it is live.
- 2026-07-22T09:08-0700 A third reviewer reported the `\x00` key separator as a space for
  the second round running, having been told in its brief that it was not. The byte is
  invisible in every normal view of the file — `sed`, an editor, a diff — so the misread
  is the default outcome and re-reading the same way reproduces it rather than correcting
  it. Only `cat -v` or a byte count settles it. An invisible character in source is a
  standing trap for reviewers; a named constant would have cost nothing and removed it.

- 2026-07-22T09:20-0700 A third round closed two coverage gaps of its own making. The
  semantics fix above had no guard — nothing visual can catch a label regression — and the
  "no stamp renders blank" rule was guarded only by the absence of the literal `4m`, which
  a fabricated `now` or `0m` would have satisfied. Both are now asserted, the second by
  matching the *shape* of any stamp rather than one value. Writing the fix and the guard
  in the same pass is not the same as having a guard: the a11y fix shipped guardless for a
  full round because the thing it protects is invisible to every assertion already there.
- 2026-07-22T09:20-0700 The tile's semantics label merges with its descendants, so
  `find.bySemanticsLabel('triage · feat/x')` matches nothing — the node's label is that
  string followed by the status, branch and snippet. Found by enumerating all 16 semantics
  nodes and printing their labels. The guard matches a `RegExp` within the merged label
  instead. Worth knowing before writing any other semantics assertion in this file.

## Commits

- HEAD — feat(triage_client): lead rail rows with the workstream, not the repo

## Research & Discoveries

- **The rail's two most prominent lines both lead with the repo.**
  `displayTitle` (`main.dart:367`) is `"repo · worktree"`; `_gitMeta`
  (`main.dart:3943`) is `"repo · branch · worktree"` immediately beneath it. Two
  same-repo sessions open identically on both lines, and the field that differs
  is buried mid-string in each.

- **The most distinguishing field is styled as the least important.** The LLM
  snippet renders last, italic, 12px, dimmest grey (`main.dart:4100-4110`). For
  two agents on one branch it is the *only* differentiator.

- **`repository_root` genuinely unifies linked worktrees.**
  `git_repository_root` (`triaged/src/session.rs:4150`) resolves via
  `--git-common-dir` and walks `<repo>/.git/worktrees/<name>` back to the main
  checkout. So a grouping key would work, *if* grouping is revisited. Caveats:
  it falls back to `worktree_root` for non-standard gitdir layouts (line 4138),
  submodules deliberately report themselves as roots (test at line 5106), and
  raw path-string equality is fragile under symlinks and macOS `/tmp` ↔
  `/private/tmp` aliasing — any future grouping key should be canonicalised.

- **The client's `status` field is connection state, not attention state.** The
  real vocabulary is `attached` / `idle` / `loading` / `exited` / `disconnected`
  / `load failed` (`main.dart:1181`, `1794`, `1844`, `2171`). The `'awaiting input'`
  value visible in the source is **demo seed data** constructed in `initState`
  (`main.dart:673`). Any future "needs attention" rollup badge requires a real
  daemon-side signal first — an earlier draft of this plan assumed one existed.

- **xterm.js handles the keyboard natively when focused.** `onData` is bound
  (`terminal_pane_web.dart:458-464`) and `attachCustomKeyEventHandler` (line
  489) intercepts *only* Tab, so Ctrl+D/R/L/W all reach the shell correctly. The
  `_keyboardEventToInput` path (line 767), which drops every ctrl/meta/alt chord
  except Ctrl+C, is the **fallback for when the platform view lacks DOM focus** —
  it is not the primary input path. Taking `Ctrl+K` would therefore genuinely
  steal readline's kill-line.

- **A capture-phase window listener already sees every keystroke first.**
  `html.window.addEventListener('keydown', _windowKeyDownListener, true)`
  (`terminal_pane_web.dart:~291`). If the palette ever needs to intercept a
  chord while the terminal holds DOM focus, that listener — not Flutter
  `Shortcuts` — is the deterministic hook, since Flutter's keyboard pipeline
  delivery is unreliable across a platform-view boundary.

- **Browsers claim part of the application-chord space.** `⌘T`, `⌘W` and `⌘N`
  are unreachable on web, and `⌘K` focuses the search bar in Firefox (it is free
  in Chrome and Safari). Installed-PWA mode frees most of them. The palette PR
  needs a per-browser audit and a documented fallback.

## Next Steps

- Cover the rail → tile wiring for `activityAt` and `indistinguishable`. Both helpers are
  unit-tested and the tile is widget-tested, but nothing asserts `SessionRail` actually
  passes them, so dropping either argument at the call site leaves the suite green — the
  same gap that was closed for `railTitle`. Left open deliberately: `SessionRail` cannot be
  hosted bare (see Issues), and the full-app route needs an `emitSnippetUpdated` on the
  fake client plus two fixtures sharing a branch, which means changing shared fixtures that
  other tests depend on. Worth doing as its own change rather than widening this one.
- Follow-up PR: ⌘K / Ctrl+Shift+K jump palette, including the browser-chord
  audit and the terminal-focus spike (a Flutter overlay may not receive typing
  until xterm's textarea is explicitly blurred).
- Later, needing daemon work: a wire-level `last_activity_at` on
  `SessionSnapshot`, and a real attention signal. Both are prerequisites for any
  rollup badge, and therefore for grouping.
- Later, TUI-driven: the leader + sticky-mode grammar, and the passthrough fix
  above.
