## Thinking

The Rust crates all inherit `version.workspace = true`, so the release version should be bumped at the workspace root. The workspace dependency declarations also pin internal crates at `0.1.0`, so those declarations need to move with the package version to keep publish metadata consistent. The Flutter client has its own `1.0.0+1` app version and is not part of the Cargo crate release bump.

## Plan

1. Update the workspace package version from `0.1.0` to `0.1.1`.
2. Update internal workspace dependency version pins for `triage-core`, `triage-transport-ws`, and `triaged`.
3. Refresh the lockfile package entries for the local Triage workspace crates.
4. Run focused Cargo validation that checks the manifest and lockfile remain coherent.
5. Record the completed version bump in the branch devlog.
