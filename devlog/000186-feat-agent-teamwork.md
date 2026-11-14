# Portable agent teamwork

## Intent

Any supported agent runtime can coordinate workers in any other supported runtime. Keep the skill in Triage alongside the managed-session tools and install it for Muse, Claude Code, Codex, and AGY/Gemini.

## Decisions

- 2026-11-13T21:43-0800 Stack on open PR #217, which provides managed worker groups. Keep agent-review-loop unchanged; remove the empty worktree created there before the repository clarification.
- 2026-11-13T21:43-0800 Add agent-teamwork as the portable coordinator workflow. Use native helpers only when the requested runtime/model and isolation are supported; use configured Triage profiles for other CLI runtimes. Preserve exact requested runtimes and models.
- 2026-11-13T21:43-0800 Keep one parent/topic group for external workers, durable task results and cleanup. Native workers remain owned by their native host; never pretend they share a Triage inbox or AGY board.
- 2026-11-13T21:43-0800 Ship backend references with the skill so installation does not depend on another repository's skills. Test copied and linked bundles under a fake home, plus independent orchestration scenarios and the required max review loop.

## Progress

- [x] Fetch, create Triage worktree, remove upstream and record plan.
- [x] Implement portable skill, backend references and installer integration.
- [x] Validate packaging and realistic routing/recovery scenarios.
- [x] Complete full local gates and max review loop.
- [x] Prepare commit and stacked PR publication.

## What Changed

- 2026-11-13T22:04-0800 Added agent-teamwork with portable coordinator/worker contracts, exact runtime/model routing, nested ownership, results, recovery and cleanup. Packaged native/Triage references include AGY board relay supervision and explicit owned parent context for outside coordinators.
- 2026-11-13T22:04-0800 Triage installer now ships both skills and their backend references to every supported runtime; fake-home checks cover copied/linked bundles, upgrades, repair and reference-directory symlink refusal. CI runs the bundle checks.
- 2026-11-13T22:04-0800 Updated discovery metadata and README/MCP guidance. Fixed the inherited unquoted colon in triage-coordination frontmatter after the skill validator rejected it.

## Research & Discoveries

- 2026-11-13T22:04-0800 Independent simulations routed all 16 coordinator/worker CLI pairs: four native matching-runtime cases and twelve matching Triage profiles. AGY-hosted model names did not substitute for requested external CLIs.
- 2026-11-13T22:04-0800 Recovery simulation preserved exact retry arguments, recovered an explicitly owned group outside a Triage terminal, deferred pending adoption, and treated exit without result as interrupted work. Board simulation used a native relay, preserved nested parent identities, deferred missing review capability, and cancelled only the requested subtree.
- 2026-11-13T22:04-0800 Added exact receive/wait/ack argument names after simulation identified schema gaps. Native schemas remain intentionally discovered from the host's actual tools.
- 2026-11-13T22:04-0800 Installer 47 checks, both skill validators and shellcheck pass. Full Rust CI gates pass 929 tests (one prior ignore); Flutter analysis, 746 VM/76 Chrome tests, bindings and Android release pass. Simulations did not launch or bill real providers; live configuration/authenticated model turns remain rollout checks.

## Review Completion

- 2026-11-13T22:54-0800 Max review found one cleanup-authority defect: a nested coordinator inherited a shared group but received whole-group cleanup guidance. All four instruction surfaces now reserve whole-group cleanup for the root or explicit delegate; helpers clean their owned child subtrees, stay alive to report, and leave their closure to the parent. Fresh nested-completion simulation confirms that scope.
- 2026-11-13T22:54-0800 Full confirmation and independent verification are clean across all eight canonical pillars, with no remaining findings or source coverage debt. No live provider run is claimed. The managed-worker parent PR's remote CI also passed.

## Commits

HEAD — feat(skills): add portable agent teamwork
