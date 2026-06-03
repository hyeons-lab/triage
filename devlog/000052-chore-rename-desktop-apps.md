# chore/rename-desktop-apps

## Agent
- 2026-06-02T20:11-0700 — Claude Code (claude-opus-4-8) @ triage branch chore/rename-desktop-apps — Branded the Windows and Linux desktop clients as "Triage" (display name) without colliding with the `triage` TUI executable.

## Intent
- Make the Windows and Linux Flutter clients display as "Triage" (matching macOS), while keeping the on-disk executable name from conflicting with the `triage` TUI binary.

## What Changed
- 2026-06-02T20:11-0700 `flutter/triage_client/windows/runner/main.cpp` — Window title `"triage_client"` → `"Triage"`.
- 2026-06-02T20:11-0700 `flutter/triage_client/windows/runner/Runner.rc` — `FileDescription` and `ProductName` → "Triage". Left `InternalName`/`OriginalFilename` as `triage_client`/`triage_client.exe` to match the actual executable.
- 2026-06-02T20:11-0700 `flutter/triage_client/linux/runner/my_application.cc` — Header-bar and window titles `"triage_client"` → `"Triage"`.

## Decisions
- 2026-06-02T20:11-0700 Keep the executable name `triage_client` (Windows `BINARY_NAME`/`OriginalFilename`, Linux `BINARY_NAME`) and only change display strings. The workspace ships a `triage` TUI binary; naming the desktop client `triage`/`Triage` would collide on case-insensitive filesystems (Windows, macOS). This mirrors macOS, where `Triage.app` displays "Triage" but its inner `Triage` binary is inside the bundle and never on PATH. Left `APPLICATION_ID` (`com.example.triage_client`) unchanged — it is an identifier, like the macOS bundle id.
- 2026-06-02T20:11-0700 No README or workflow change needed: the release artifacts still contain `triage_client(.exe)`, which the README already documents, and the publish workflow zips/tars the whole build-output directory regardless of binary name.

## Research & Discoveries
- 2026-06-02T20:11-0700 Workspace executables: `triage` (TUI, `triage` crate), `triaged` (daemon), and the desktop Flutter client `triage_client`. Renaming the desktop client to `triage`/`Triage` would conflict with the TUI; `triage_client` is distinct even case-insensitively.

## Commits
- HEAD — chore(client): brand Windows/Linux desktop apps as "Triage"
