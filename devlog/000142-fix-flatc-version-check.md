# 000142: fix/flatc-version-check

**Agent:** Claude Code (claude-opus-5) @ triage branch fix/flatc-version-check

## Intent

Fail the `triage-core` build with an actionable message when the host `flatc` belongs to a
different FlatBuffers generation than the pinned `flatbuffers` runtime, instead of letting the
mismatch surface as a wall of rustc type errors inside generated code.

## What Changed

- 2026-09-06T12:12-0700 `crates/triage-core/build.rs`: checks the generation of the located `flatc`
  before compiling the schema. Older than the pinned runtime is a hard error naming both versions
  and how to install a matching compiler; newer is a warning, since that direction usually works
  but can also drift. The pinned major is read from the workspace manifest rather than duplicated
  in a constant, so the check cannot fall out of step with the pin, and the manifest is registered
  with `rerun-if-changed` so a bump re-runs it.

## Decisions

- 2026-09-06T12:12-0700 Read the pin from `../../Cargo.toml` rather than hardcoding the expected
  major. A constant would have to be updated in lockstep with the dependency, and the failure mode
  of forgetting is exactly the silent incompatibility this check exists to catch.
- 2026-09-06T12:12-0700 An unreadable version is a warning, not an error. A compiler that does not
  answer `--version` may still generate fine, and the compile itself is the next check anyway;
  blocking there would turn a diagnostic into a new way to fail a working build. Same for an
  unreadable manifest.
- 2026-09-06T12:12-0700 Newer than the pin warns rather than fails. Generator and runtime are meant
  to match, but a newer generator is usually compatible, and an error would block builds on hosts
  that are merely ahead.

## Issues

- 2026-09-06T12:12-0700 The check keys on the major version alone. FlatBuffers versions by year, so
  that catches the distribution-package case that motivated this (Ubuntu ships 2.0.x) but would not
  catch an incompatibility introduced between two releases of the same year.

## Commits

- HEAD: fix(build): reject a flatc that cannot generate code for the pinned runtime

## Progress

- [x] Add the generation check with an actionable error
- [x] Verify all four paths: matching, older, newer, unreadable
- [ ] Open PR

## Next Steps

- Open a PR against main.
