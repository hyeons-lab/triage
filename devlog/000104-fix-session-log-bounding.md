# 000104 — fix/session-log-bounding

**Agent:** Claude Code (claude-opus-4-8[1m]) @ triage branch fix/session-log-bounding

## Intent

Investigate why `triaged` was killing sessions and stalling the machine, then fix
the causes. Three independent causes were found; see
`devlog/plans/000104-01-crash-causes-and-log-bounding.md` for the full
derivation and evidence.

1. macOS SIGKILLed the daemon with `CODESIGNING / Launch Constraint Violation`
   because the adhoc-signed binary was replaced in place (same inode).
2. `launchd` amplified a single bad launch into 22 respawns — unconditional
   `KeepAlive`, no `ThrottleInterval`.
3. Session output logs grow without bound and are read *whole* into memory on
   adopt/restore, while only the last 1 MiB is ever served to a client.

## Research & Discoveries

2026-07-22T10:05-0700 Both crash reports on this machine are
`EXC_CRASH / SIGKILL (Code Signature Invalid)`, `namespace CODESIGNING`,
`indicator "Launch Constraint Violation"`. Binary is adhoc/linker-signed, so
macOS caches the code directory hash per inode; writing new bytes into the live
inode invalidates it. Installed-binary mtime `07:27:01` immediately precedes the
`07:27:44` crash, and `session-73.log` / `session-80.log` mtimes are frozen at
`Jul 21 23:15`, the minute of the earlier crash.

2026-07-22T10:07-0700 `launchctl print gui/$(id -u)/com.hyeons-lab.triaged`
reported `runs = 22`. The `Address already in use (os error 48)` entries in
`triaged.err.log` are respawns racing the listener socket.

2026-07-22T10:10-0700 `~/.local/state/triage/sessions/` held 1.5 GB across 126
logs dating to May 31; nothing in the daemon ever deletes a session log. The two
largest were ~100 MB. The 14:27 handover adopted 13 sessions through the
full-file `fs::read` replay path, which explains 9m54s of CPU consumed in 9m22s
of wall time, ~2 GB RSS, and the logged `gap_ms: 25747` Phase-2 handover gap.

2026-07-22T10:12-0700 `bytes_logged` is not a persisted field — `PersistedSession`
has no such member and restore re-derives it by replaying the file. It is
therefore always "current length of the log file", and absolute output offsets
already rebase across daemon restarts. `raw_output_start` reaches clients only
paired with the `raw_output` it describes, and the Dart client forwards it
without cross-snapshot arithmetic. This is what makes front-truncating rotation
safe, provided `bytes_logged == current file length` is maintained.

## What Changed

2026-07-22T10:48-0700 `crates/triaged/src/service.rs` — LaunchAgent plist gains
`ThrottleInterval` (`THROTTLE_INTERVAL_SECS`, 30s), above launchd's 10s default,
so a binary that cannot launch backs off instead of storming 22 respawns.
`KeepAlive` deliberately stays `true` (see Decisions), with a comment recording
why the conditional form is wrong here. New test
`plist_keeps_alive_unconditionally_and_throttles_respawns` pins both.

2026-07-22T10:22-0700 `crates/triaged/src/session.rs` — bounded every replay
path. Added `REPLAY_TAIL_CAP` (== `MAX_SESSION_LOG_BYTES`, 16 MiB) and
`read_replay_tail`, and replaced all four full-file reads with it: the
handover-adopt path, `HistoricalSession::restore`, the
`LogInitialization::ReplayExisting` live-restore path, and `reflow_from_log`
(which re-read the whole log on *every resize*). New `OutputState::replay_tail`
sets `bytes_logged` to the log's true length while replaying only the tail, so
`read_raw_output_tail`'s absolute offsets stay correct.

2026-07-22T10:24-0700 `crates/triaged/src/session.rs` — capped log growth.
`MAX_SESSION_LOG_BYTES` (16 MiB) / `SESSION_LOG_RETAIN_BYTES` (12 MiB), with
`trim_session_log` rewriting the retained tail and `ingest` calling
`trim_log_if_oversized`. `OutputState` gained `log_path`, `trim_disabled`, and
the two bounds as fields
(the latter so tests can drive the real trim path without writing megabytes).
The size bounds are pinned in order by `const _: () = assert!(…)`.

2026-07-22T10:26-0700 `crates/triaged/src/session.rs`, `crates/triaged/src/main.rs`
— reclaimed leaked logs. `shutdown_session` deletes the log of the session it
removed from the manifest (`remove_session_log`), using the session's own
recorded `log_path` and refusing any path not named `{session_id}.log`.
`SessionManager::purge_orphaned_logs` reclaims logs that neither the live session
map nor the on-disk manifest references and that are older than
`ORPHANED_LOG_RETENTION` (7 days); `main` calls it on a background thread once
startup has settled. Matching is by file name, since a manifest path and a
freshly scanned one can spell the same location differently.

2026-07-22T10:29-0700 `scripts/install.sh` — new. Builds and installs via a
temp file in the destination directory plus `mv`, so each install allocates a
fresh inode rather than rewriting a live one, then verifies the installed
`triaged` launches (the only one of the three that parses `--version`). Header
documents the codesigning failure mode this prevents; `README.md` points at it.

2026-07-22T10:20-0700 `flutter/triage_client/lib/main.dart` — the header refit
button now runs `_refitAndFocusActiveSession`, which refits *and* reclaims
keyboard focus, so the pane is typable without a further click.
`_refocusActiveSessionOnResume` renamed to `_refocusActiveSession` now that it
has a second caller.

## Issues

2026-07-22T10:27-0700 First run of the new trim test produced
`6789\0\0\0\0\0\0ab` — a sparse hole in the middle of the log. Cause: not every
session log handle is opened in append mode. The `LogInitialization::Truncate`
path (a freshly created session) opens a plain `write(true).truncate(true)`
handle that keeps its own file offset, so after trimming shortened the file, its
stale offset wrote past the new end. Fixed by seeking the handle to
`SeekFrom::End(0)` after a successful trim. Would have silently corrupted the
logs of every newly created session, so worth the test that caught it.

2026-07-22T10:28-0700 Two of the new tests initially failed because
`test_output_state` opens its log with `truncate(true)` — writing the fixture
*before* constructing the state wiped it. Fixtures are now written after.

2026-07-22T10:28-0700 `session_manager_enforces_input_lease_before_writing` began
failing with `NotFound`: it read the session log after `shutdown_session`, which
now reclaims it. Reordered to read before shutdown, and it additionally asserts
the log is gone afterwards.

2026-07-22T10:30-0700 The one-off cleanup's `while IFS= read -r` loop silently
skipped its last entry (`session-99.log`, 92 MB) because the victims file had no
trailing newline. Removed separately.

2026-07-22T10:47-0700 Review round 1 (4 reviewers, max effort) found two real
invariant breaks in `read_replay_tail`. It was built on `read_raw_output_tail`,
which reports an unreadable log as *empty history* — correct when serving a
snapshot, but here it returned `Ok((len, []))`, callers skipped the replay, and
`bytes_logged` stayed 0 while the file held data. It also took its length from a
separate `fs::metadata` call, which can disagree with the subsequent read because
a session log is still being written during handover adoption. Rewritten to do
its own open/seek/read, propagate I/O errors, and derive the length from the
bytes actually read so offset and length are consistent by construction.

2026-07-22T10:51-0700 Review also caught that the failed-`seek` branch after a
trim only warned and then still assigned `bytes_logged`, which is precisely the
sparse-hole corruption the seek exists to prevent. First attempt folded the seek
into the trim's `Result` so a seek failure failed the whole trim — which round 2
then showed was itself wrong (the truncation is already committed to disk by
then, so skipping the rebase broke the invariant instead of protecting it).

2026-07-22T11:34-0700 Final shape of the post-trim handle repositioning, after
three rounds converged on it: rebase `bytes_logged` and clear `log_cache`
immediately once `trim_session_log` returns, since the truncation is already
durable at that point and nothing after it may leave the two disagreeing; then
seek the handle to the end; if that fails, reopen it `read(true).append(true)`
(safe because `OutputState::log` is only ever written and flushed, never read);
and only if the reopen also fails, latch `trim_disabled` so the multi-megabyte
rewrite is not retried on every subsequent chunk of output.

2026-07-22T11:14-0700 Review round 2 found a defect introduced by round 1's own
fix: folding the post-trim `seek` into the trim's `Result` meant that when the
seek failed, `bytes_logged` was never rebased — but `trim_session_log` had
already committed the truncation to disk, so the invariant broke in exactly the
branch meant to protect it. Rebasing now happens immediately after the trim
succeeds, before anything else can fail.

2026-07-22T11:16-0700 Round 2 also found `shutdown_session`'s `Live` arm still
re-deriving `log_dir/{id}.log` despite the comment claiming otherwise;
`ManagedSession::Live` carries `launch.log_path`, which for a handover-adopted
session comes from the handover payload and need not match. It would have
unlinked nothing and leaked the real log — the leak this change exists to fix.

2026-07-22T11:18-0700 Round 2 flagged that `purge_orphaned_session_logs` compared
whole `PathBuf`s between manifest-recorded paths and freshly scanned ones. Those
can spell the same location differently (symlinked `$HOME`, macOS `/var` →
`/private/var`), and a mismatch would classify *every* referenced log as an
orphan — with the age guard no help, since historical logs are exactly the stale
ones. Now matched by file name.

2026-07-22T11:40-0700 Review round 4 caught a corruption bug introduced by round
3's own fix. Round 3 added a trim to `HistoricalSession::restore`, reasoning that
an exited session never ingests again and so would never otherwise be trimmed.
But restore runs during a handover *before* the adoption byte, while the outgoing
daemon is still fully serving and writing those same logs — `main.rs` documents
exactly this. Trimming there would truncate a live writer's file: a `write(true)`
handle resumes at its pre-truncation offset and punches a sparse hole, an
`append(true)` one leaves the other daemon's `bytes_logged` past EOF. Worst of
all it was reachable precisely in the migration case that motivated the change —
the first handover after installing the fix, with the largest logs. Removed, with
the reasoning recorded at the call site so it is not re-added. An oversized log
is now trimmed when its session next produces output.

2026-07-22T11:20-0700 `scripts/install.sh` exited 1 on success: its `cleanup`
EXIT trap ended with a failing `[[ -n "$staged" ]]`, which under `set -e` became
the script's status. Reproduced directly, fixed with an explicit `return 0`.

## Decisions

2026-07-22T10:12-0700 Keep the invariant `bytes_logged == current file length`
rather than introducing a persisted `log_start_offset` — the codebase already
treats absolute offsets as per-daemon-run, so rotation is the same class of
event as a restart and needs no new persisted state.

2026-07-22T10:24-0700 Cap at 16 MiB retaining 12 MiB rather than trimming to a
hard limit on every write. The gap between the bounds is what amortises the
cost: one rewrite buys 4 MiB of further output, so trimming is rare rather than
per-write.

2026-07-22T10:31-0700 Left the systemd unit alone — it already uses
`Restart=on-failure` and systemd applies its own
`StartLimitIntervalSec`/`StartLimitBurst` crash-loop protection, so it never had
either defect.

2026-07-22T10:48-0700 Reverted the `KeepAlive: {SuccessfulExit: false}` idea and
kept `KeepAlive: true`, adding only `ThrottleInterval`. Review caught that the
post-handover respawn is load-bearing: `devlog/000085` designed the daemon to
"self-settle once the launchd-owned process owns the socket", and `main.rs`'s
refused-teardown path explicitly documents relying on being respawned regardless
of exit status. Making `KeepAlive` conditional would have left the surviving
daemon unsupervised after every handover. The throttle alone fixes the actual
defect (the 22-respawn storm) without touching that design.

2026-07-22T10:49-0700 Disable trimming for a session after the first failure
instead of retrying. `bytes_logged` stays above the max on failure, so an
unconditional retry re-attempts a multi-megabyte read/write on every subsequent
chunk of PTY output — turning a full disk into an I/O storm on the actor's hot
path. An un-trimmed log is the lesser failure.

2026-07-22T10:50-0700 Source the orphan purge's referenced set from the
*manifest* rather than from the restored session map, using each entry's own
`log_path`. A session whose `HistoricalSession::restore` fails is warn-skipped
from the map, so keying off the map would have made its log an "orphan" and
deleted it — destroying exactly the session most likely to need recovery.

2026-07-22T10:52-0700 Set `REPLAY_TAIL_CAP == MAX_SESSION_LOG_BYTES` rather than
picking a smaller tail. Replay rebuilds terminal *modes* (bracketed paste,
alternate screen, cursor-key and charset state) and recovers the OSC 7 cwd, all
of which are set early in a session rather than in its tail — so a strictly
smaller cap would silently drop them. Making the cap match the trim ceiling means
any log the new code manages replays in *full*, so replay stays exactly as
complete as the full-file read it replaces while still bounding the worst case
(a legacy 100 MB log costs one 16 MiB pass, not 100).

2026-07-22T10:53-0700 Skip the focus request on mobile in the refit button.
Mobile takes IME input, so focus raises the soft keyboard, which insets the
Scaffold and fires another fit at a smaller size — undoing the resize the button
exists to perform. Same viewport jump `devlog/000091` fixed for scroll swipes.

2026-07-22T11:12-0700 Plan step 1 called for making `KeepAlive` conditional on
`SuccessfulExit`; not done, for the reason above. Plan step 2 said
`scripts/install.sh` would be documented — done in `README.md`, so the
codesigning-safe install path is discoverable rather than referenced nowhere.

2026-07-22T11:22-0700 Accept that trimming loses terminal modes set before the
retained window. `REPLAY_TAIL_CAP == MAX_SESSION_LOG_BYTES` guarantees replay
never discards bytes the log still holds, but trimming drops the front, so a
session past 16 MiB does lose the early bytes where bracketed paste / alt-screen
/ charset modes and OSC 7 were set — the loss moves from replay time to trim
time rather than disappearing. That is the unavoidable cost of bounding the log;
shells and TUIs re-assert modes on the next repaint, and `last_known_cwd`
already outranks the replayed OSC 7 cwd. Documented on the constant rather than
left implied, since the earlier wording overclaimed.

2026-07-22T11:24-0700 Revised `devlog/triage-design-doc.md`, which still
specified "Rotation: 100MB per session, last 7 days" — never implemented, and
~6x looser than what landed. Recorded the revision and its effect on the planned
`rg` search scope rather than letting the spec silently contradict the code.

2026-07-22T14:18-0700 Addressed Copilot's review on the PR. Three findings, all
real:

- `remove_session_log` unlinked whatever path the manifest or handover payload
  recorded, without checking it. That path is *data*, not something this process
  derived, so a corrupted manifest could have made shutdown delete an arbitrary
  file. It now requires the name to be `{session_id}.log` and warns otherwise —
  leaking a stray log is recoverable, deleting the wrong file is not. Kept the
  recorded path rather than reverting to a derived one, since an adopted
  session's log legitimately comes from the handover payload.
- `read_replay_tail` could report a length past EOF. `start` is computed from the
  pre-read size, so a log trimmed below it in between (another daemon still owns
  the session mid-adoption) left the seek past the end, the read empty, and
  `start` describing a length the file no longer had. Now clamped to the
  post-read size.
- The orphan purge ran inside `restore_sessions`, before handover adoption, so a
  live-but-idle session whose log had not been written within the retention
  window could have had it deleted moments before adoption. This was the gap in
  my earlier reasoning: I had argued the manifest always lists live sessions, but
  that only holds if it was persisted after the last change — a stale manifest
  plus a handover defeats it.

2026-07-22T14:20-0700 Moved the purge out of `restore_sessions` into
`SessionManager::purge_orphaned_logs`, called from `main` once startup has
settled (after cold start, restore, and handover adoption all converge). It
treats a log as referenced if *either* the live session map or the on-disk
manifest points at it: the map misses failed-restore sessions, the manifest
misses anything adopted since it was last written, and only the union is safe.
If the manifest cannot be read the purge is skipped rather than run on half the
picture.

2026-07-22T14:26-0700 Ran the purge on a background thread rather than inline.
The call site sits below the handover commit point, where `main`'s own comment
notes that work is downtime — nothing is serving clients yet — and a directory
scan plus unlinks of multi-megabyte logs is exactly that. The purge needs no
ordering against what follows, and a session created while it scans is safe on
the age check, its log being seconds old.

2026-07-22T14:28-0700 Renumbered this devlog and its plan 000102 → 000104.
Both `000102` (docs, #120) and `000103` (rail row identity, #121) merged to main
while this branch was open.

## Commits

- HEAD — fix(triaged): bound session output logs and throttle launchd respawns

## Next Steps

- Resizing a Flutter *web* session does not reflow existing contents. The daemon
  reflows correctly (`SessionActor::resize` → `reflow_from_log` → broadcast), but
  the resize broadcast deliberately carries no `raw_output`, and the web pane
  renders through xterm.js's own buffer rather than the snapshot's styled rows —
  so the reflowed server state appears to be discarded on web. Needs in-browser
  confirmation before picking a fix; not addressed here.
