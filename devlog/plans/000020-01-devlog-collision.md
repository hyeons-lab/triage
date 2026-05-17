# Devlog Collision Fix

## Thinking

The `git pull` of origin/main merged several branches whose devlogs were authored in parallel worktrees. Two of them independently picked `000016`:

- `000016-codex-code-review-graph-files.md` (+ plan) — merged via PR #20 at 2026-05-16 08:39.
- `000016-fix-tui-shift-tab-input.md` (+ plan) — merged via PR #22 at 2026-05-16 10:50.

`000017` (PR #21) and `000018` (PR #23) are already used, so the only correct fix is to move the later duplicate to `000019`. The code-review-graph set keeps `000016` because it landed first. Neither devlog nor plan references its own number in its body, so renaming the files is sufficient.

## Plan

1. `git mv` the `fix-tui-shift-tab-input` devlog and plan from `000016`/`000016-01` to `000019`/`000019-01`.
2. Add this branch devlog (`000020`) and plan.
3. Commit devlog + plan + rename together, push, open PR.
