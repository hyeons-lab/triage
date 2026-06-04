# 000055 — ci/macos-strip-get-task-allow

**Agent:** Claude (claude-opus-4-8) @ triage branch ci/macos-strip-get-task-allow

## Intent

Stop the released macOS Triage client from prompting "Triage wants to use your
confidential information stored in ... in your keychain" 4+ times on every launch,
with "Always Allow" never persisting.

## What Changed

2026-06-03T18:06-0700 `.github/workflows/publish.yml` — added a `Strip get-task-allow`
step to the `build-macos` job (between `Build Triage.app` and `Package Triage.app`).
It re-signs the built `.app` ad-hoc with `macos/Runner/Release.entitlements` (which
omits `get-task-allow`), hard-fails if the entitlement survives, and verifies the
signature. The CI runner has no Developer ID, so `flutter build macos --release` falls
back to ad-hoc signing and Xcode injects `get-task-allow`; macOS won't persist an
"Always Allow" Keychain ACL for a debuggable app, which is what caused the repeated
prompts.

2026-06-03T18:06-0700 `devlog/plans/000055-01-strip-get-task-allow.md` — plan +
root-cause analysis.

## Decisions

2026-06-03T18:06-0700 Re-sign to strip get-task-allow rather than set up Developer ID
signing + notarization — the re-sign is free and needs no secrets. Developer ID +
notarization (which would also remove the Gatekeeper quarantine warning) is the proper
follow-up but is out of scope here.

2026-06-03T18:06-0700 Added a hard-fail regression guard (`grep -q get-task-allow` →
`exit 1`) so a future Flutter/Xcode change that re-injects the entitlement can't
silently ship.

## Research & Discoveries

- The client deliberately uses the legacy file-based keychain
  (`lib/services/storage_native.dart`: `MacOsOptions(usesDataProtectionKeychain:
  false)`) because a sandboxed ad-hoc app with no team-prefixed keychain-access-group
  entitlement gets errSecMissingEntitlement (-34018) from the data-protection
  keychain. The file-based keychain is the one that shows ACL prompts.
- Fix verified locally on `/Applications/Triage.app`: after
  `codesign --force --deep --sign - --entitlements Release.entitlements`, the
  get-task-allow entitlement count dropped to 0 and the signature stayed valid.

## Commits

HEAD — ci(publish): strip get-task-allow from macOS client to fix Keychain prompts

## Next Steps

- Proper follow-up: sign the macOS client with a Developer ID certificate + hardened
  runtime and notarize it in CI (removes get-task-allow AND the Gatekeeper quarantine
  warning). Requires an Apple Developer account and CI secrets.
