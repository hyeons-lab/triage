# fix/devlog-collision

## Agent
- Claude (claude-opus-4-7) @ argus branch fix/devlog-collision

## Intent
- Two devlog/plan sets both used sequence number `000016`, violating the AGENTS.md "one zero-padded sequence per devlog, increment the highest" convention. Renumber the later duplicate so the sequence is unique and monotonic.

## What Changed
- 2026-05-16T19:23-0700 `devlog/000016-fix-tui-shift-tab-input.md` → `devlog/000019-fix-tui-shift-tab-input.md` and its plan `devlog/plans/000016-01-tui-shift-tab-input.md` → `devlog/plans/000019-01-tui-shift-tab-input.md` — resolve the `000016` collision by moving the later set to the next free number.

## Decisions
- 2026-05-16T19:23-0700 Renumber the `fix-tui-shift-tab-input` set, not `codex-code-review-graph-files` — by merge commit date the code-review-graph set landed first (PR #20, 08:39) and the shift-tab set second (PR #22, 10:50), so the shift-tab set is the later duplicate. `000017` (PR #21) and `000018` (PR #23) are already taken, so the next free number is `000019`.
- 2026-05-16T19:23-0700 Pure `git mv` rename — neither file references its own sequence number in its body, so no content edits are needed.

## Commits
- HEAD — fix: renumber duplicate 000016 devlog to 000019

## Next Steps
- Open PR; no code or CI-relevant changes (devlog-only).
