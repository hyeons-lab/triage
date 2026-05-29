# fix/flutter-session-loading-placeholders

## Agent

Codex

## Intent

Address follow-up review findings from the merged macOS shortcut/session-loading PR. The Flutter client should not drop daemon output that arrives while a listed session is still attaching, and replacing a loading placeholder should not destroy the mounted terminal instance for the same terminal id.

## Progress

- 2026-05-28T18:19-0700: Created follow-up branch from `origin/main` after the original PR merged. The project code-review graph tools were not available in this session, so local inspection was used after checking for them.
- 2026-05-28T18:26-0700: Implemented the Flutter session-loading follow-up fixes and verified the client test suite.

## What Changed

- Loading daemon placeholders now remain visible but are treated as not event-ready, so live session events are buffered until attach completes.
- Same-title placeholder replacement no longer destroys the cached `TerminalPane` session, preserving the mounted xterm instance while rebinding to the loaded session controller.
- Daemon reload now avoids destroying terminal caches for sessions that are retained as loading placeholders.
- Added widget regression coverage for output that arrives while a daemon session placeholder is still loading.

## Decisions

- Keep the fix scoped to placeholder replacement and event routing in the Flutter client.
- Preserve the existing placeholder title so sidebar labels remain stable, but treat `status == 'loading'` sessions as not ready for live events.

## Verification

- `flutter test`

## Commits

- HEAD — fix: preserve Flutter loading placeholders

## Next Steps

- Push the follow-up branch and open a PR.
