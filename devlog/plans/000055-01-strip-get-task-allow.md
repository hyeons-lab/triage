# Plan 000055-01 — Strip get-task-allow from the released macOS client

## Thinking

A user installed the released `Triage-macos-v0.1.3.zip` and hit a repeating macOS
Keychain prompt — "Triage wants to use your confidential information stored in ..."
— 4+ times on every launch, with "Always Allow" never sticking.

Diagnosis (on the installed app):

- `codesign -dvv` showed the app is **ad-hoc signed** (`flags=0x2(adhoc)`,
  `TeamIdentifier=not set`, bundle id `com.example.triageClient`).
- `codesign -d --entitlements -` showed `com.apple.security.get-task-allow = true`.
- The repo's `macos/Runner/Release.entitlements` does **not** contain that key — it
  only has app-sandbox + network.client. So the entitlement is being injected at
  build/sign time, not authored.

Why it breaks the Keychain: `get-task-allow` marks the app as debuggable. macOS
refuses to persist an "Always Allow" ACL decision for a debuggable app (a debugger
could attach and exfiltrate), so it re-prompts every launch. The client stores its
bearer token + client id in the **legacy file-based keychain** on purpose
(`lib/services/storage_native.dart` sets `MacOsOptions(usesDataProtectionKeychain:
false)` because a sandboxed ad-hoc app with no team-prefixed keychain-access-group
can't use the data-protection keychain). The file-based keychain is exactly the one
that shows these ACL dialogs, once per item read/write → the "4+" prompts.

Why the released build has get-task-allow even though CI runs `flutter build macos
--release`: the runner has no Developer ID certificate, so signing falls back to
ad-hoc, and Xcode's base-entitlement injection adds `get-task-allow` for ad-hoc/local
signing regardless of the Release configuration.

Fix options considered:

1. **Developer ID signing + notarization** — the "proper" fix. No get-task-allow, no
   quarantine warning, no prompts. Needs an Apple Developer account and CI secrets.
   Out of scope for this change.
2. **Post-build re-sign that strips get-task-allow** (chosen) — free, no secrets.
   Re-sign the built `.app` with the repo's `Release.entitlements` (which omits
   get-task-allow). App stays ad-hoc (users still clear quarantine on first launch)
   but is no longer debuggable, so "Always Allow" persists after one grant.

Verified the fix locally on the installed `/Applications/Triage.app`:
`codesign --force --deep --sign - --entitlements Release.entitlements` → entitlement
gone (`grep -c get-task-allow` == 0), signature still valid and satisfies its DR.

## Plan

1. Add a `Strip get-task-allow` step to the `build-macos` job in
   `.github/workflows/publish.yml`, between `Build Triage.app` and
   `Package Triage.app`:
   - `codesign --force --deep --sign - --entitlements
     macos/Runner/Release.entitlements <built .app>`
   - Hard-fail the build if `get-task-allow` survives the re-sign (regression guard).
   - `codesign --verify --strict` the result.
2. Validate the workflow YAML.
3. Devlog + plan + workflow change committed together; open PR.

Not in scope: Developer ID signing / notarization (tracked as the proper follow-up).
