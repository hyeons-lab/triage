# fix/devlog-collision

## Agent
- Claude (claude-opus-4-7) @ argus branch fix/devlog-collision

## Intent
- Two devlog/plan sets both used sequence number `000016`, violating the AGENTS.md "one zero-padded sequence per devlog, increment the highest" convention. Renumber the later duplicate so the sequence is unique and monotonic.

## What Changed
- 2026-05-16T21:51-0700 `devlog/000016-fix-tui-shift-tab-input.md` → `devlog/000020-fix-tui-shift-tab-input.md` and its plan `devlog/plans/000016-01-tui-shift-tab-input.md` → `devlog/plans/000020-01-tui-shift-tab-input.md` — resolve the `000016` collision by moving the later set to the next free number.
- 2026-05-16T21:51-0700 This branch's own devlog/plan renumbered `000020` → `000021` (and `000020-01` → `000021-01`) so they sit above the renumbered shift-tab set.

## Decisions
- 2026-05-16T19:23-0700 Renumber the `fix-tui-shift-tab-input` set, not `codex-code-review-graph-files` — by merge commit date the code-review-graph set landed first (PR #20, 08:39) and the shift-tab set second (PR #22, 10:50), so the shift-tab set is the later duplicate.
- 2026-05-16T21:51-0700 Target `000020`, not `000019`. The open PR #24 (`feat/session-context`) already claims `000019` and predates this branch, so moving shift-tab to `000019` would just recreate the collision once both merge. `000017` (PR #21), `000018` (PR #23), and `000019` (PR #24, open) are taken, so the next free number is `000020`; this branch's devlog moves to `000021`.
- 2026-05-16T19:23-0700 Pure `git mv` rename — none of the files reference their own sequence number in their body, so no content edits are needed beyond this devlog/plan.

## Commits
- 2f4492e — fix: renumber duplicate 000016 devlog to 000019
- HEAD — fix: re-point renumber to 000020 to avoid PR #24 conflict

## Next Steps
- Update PR #25 description to match the corrected numbering; devlog-only, no code or CI-relevant changes.
