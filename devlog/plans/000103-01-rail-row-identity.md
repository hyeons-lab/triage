# Plan 000103-01 — Side-rail row identity

## Thinking

### The problem, stated precisely

Sessions are hard to tell apart *when several are on the same repo*. That is an
intra-repo disambiguation problem, and the rail currently makes it worse in two
specific ways.

**1. The two strongest lines both lead with the repo.** `SessionVm.displayTitle`
(`main.dart:367`) renders `"repo · worktree"`, and `_SessionListTileState._gitMeta`
(`main.dart:3943`) renders `"repo · branch · worktree"` directly beneath it. Two
sessions in the same repo therefore open with identical text on both lines, and
the field that actually differs — the branch/worktree — is buried mid-string on
each. The rail spends its two most prominent lines re-stating the thing the
sessions have in common.

**2. The one genuinely distinguishing field is styled as the least important.**
The LLM snippet is what tells you *which* of two same-branch sessions you want.
It renders last, italic, 12px, in the dimmest grey on the tile
(`main.dart:4100-4110`). For two agents on one branch it is the only
differentiator that exists, and it is the easiest thing on the row to miss.

Neither fix needs the daemon, a protocol change, or a grouping model.

### Why this comes before grouping

An earlier draft of this work led with grouping sessions by repo. Grouping
addresses *clutter*, which is a real but separate complaint; it does not address
finding the right session, because it collects the indistinguishable sessions
into one bucket and then hides them behind a disclosure control. The row-level
fixes here are strictly cheaper and attack the stated problem directly. Whether
grouping is still wanted afterwards is deliberately left open.

### Activity time: what is actually available

There is no activity timestamp on the wire. `SessionSnapshot`
(`triage-core/src/session.rs:100`) carries `output_seq` and `bytes_logged` but no
time, and the daemon's `last_tick_at` (`triaged/src/session.rs:1849`) is an
`Instant`, which is not serializable.

However `session_snippet_updated` is a **push event applied to any session by
id**, not only the attached one (`main.dart:2079`). The client can stamp
`DateTime.now()` on receipt and get a real activity signal for background rows at
zero protocol cost.

Its limits have to be stated honestly, because they decide the rendering rule:

- Granularity is the summarizer's, not the pty's.
- Nothing at all when summarization is disabled.
- **No backfill.** On connect or reconnect the client has no history, so a row
  shows no time until it next moves.

Given no backfill, the rule is: render nothing when there is no stamp. A missing
timestamp is honest; an invented or misleading one is worse than blank. A true
`last_activity_at` needs a `SessionSnapshot` field plus daemon and TUI plumbing,
and is out of scope here.

### Why the rail needs its own title getter

`displayTitle` has two call sites: the rail tile (`main.dart:3361`) and the
workspace header (`main.dart:4552`). In the header, `"repo · worktree"` is
correct — it is the only place that states what you are currently inside, and
there is no sibling row to disambiguate against. Only the rail has the
redundancy problem. So this adds a rail-specific getter and leaves
`displayTitle` and the header untouched.

### Keyboard: decided, and deliberately not here

The jump palette is a separate PR. Its binding model was settled while planning
this one and is recorded in the devlog so it is not re-litigated: the Flutter
client uses platform application chords (`⌘K` / `Ctrl+Shift+K`), which the pty
cannot encode and therefore cannot collide with. A tmux-style leader plus sticky
mode is deferred to its own TUI-driven piece of work. A pre-existing TUI defect
found during this planning — `key_to_command` (`crates/triage/src/main.rs:1581`)
unconditionally swallowing `Ctrl+W`, `Ctrl+N`, `Ctrl+Q`, PageUp/PageDown and
F2–F4 from the shell with no passthrough — is filed in the devlog to be fixed
alongside that leader work.

## Plan

### 1. Rail title leads with the workstream

- Add `SessionVm.railTitle`: the branch, else the distinct worktree leaf, else
  the cwd leaf, else `title`. Never leads with the repo name.
- Leave `displayTitle` and the workspace header (`main.dart:4552`) unchanged.
- Point the rail tile (`main.dart:3361`) at `railTitle`.

### 2. Meta line stops repeating the title

- Rework `_gitMeta` (`main.dart:3943`) to render the repo as context, dropping
  whichever component was promoted into `railTitle`, so no component appears
  twice on one tile.
- Keep the existing cwd fallback for sessions with no git context.

### 3. Promote the snippet

- Move the snippet above the status line and lift its colour and weight out of
  the dimmest tier. It stays single-line and ellipsised in the ordinary case.

### 4. Sibling collision handling

- When two or more rows share a repo *and* branch, the snippet is the only
  differentiator. Those rows render the snippet across two lines instead of one
  so it cannot ellipsise down to nothing.
- Detection is a pure function over the session list; it does not mutate
  `SessionVm`.

### 5. Relative activity time

- Add `SessionVm.snippetUpdatedAt`, stamped in the `session_snippet_updated`
  handler (`main.dart:2079`).
- Render a compact relative time ("2m") on the row. Render nothing when the
  stamp is absent — no backfill exists, so blank is the honest state.
- Formatting is a pure function, unit tested at boundaries.

### 6. Tests

- Unit: `railTitle` precedence across repo/worktree/branch/cwd/no-context.
- Unit: `_gitMeta` never repeats a component promoted into the title.
- Unit: relative-time formatting boundaries; null stamp renders empty.
- Unit: sibling-collision detection (same repo+branch, same repo different
  branch, different repos, missing context).
- Widget: two same-repo sessions produce visibly different leading lines.
- Widget: two same-branch sessions both show a non-truncated snippet.
- Widget: header (`main.dart:4552`) still renders `displayTitle` — a regression
  guard on the deliberate split.

### Out of scope

- Grouping repo worktrees into a single rail entry.
- The ⌘K jump palette (its own PR).
- A wire-level `last_activity_at`, and any real attention signal (needs daemon
  work; the natural next step after these two).
- The TUI keybinding defect and the leader/sticky-mode grammar.
