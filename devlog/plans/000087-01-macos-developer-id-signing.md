## Thinking

The macOS client is a Flutter app released via `.github/workflows/publish.yml`
(`build-macos` job). Today it is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`),
re-signed only to strip `get-task-allow`, then ditto-zipped and attached to the
GitHub release. Users must clear quarantine manually; Gatekeeper shows the app as
from an unidentified developer.

The user has an Apple Developer account and wants the client Developer-ID-signed +
notarized so it launches without quarantine gymnastics, wired into CI so every
future release is covered.

For distribution outside the App Store the requirements are:
1. Developer ID Application certificate.
2. Sign with hardened runtime (`--options runtime`) + secure timestamp
   (`--timestamp`). Apple will not notarize without hardened runtime.
3. Notarize via `xcrun notarytool submit --wait` (App Store Connect API key).
4. Staple the ticket (`xcrun stapler staple`) so it verifies offline.

The sandbox entitlements (`app-sandbox`, `network.client`) in
`macos/Runner/Release.entitlements` are compatible with Developer ID + hardened
runtime; no entitlement change is needed. Because we sign with a real identity and
hardened runtime, `get-task-allow` is never injected, so the existing strip step is
only needed on the ad-hoc fallback path.

Design choice: keep the ad-hoc path as a fallback when signing secrets are absent
(forks, or before secrets are configured), so the multi-platform release job does
not break. Gate on the presence of `MACOS_SIGN_IDENTITY`. When present, import the
cert into an ephemeral keychain, sign inside-out, notarize, staple. Otherwise fall
back to the current ad-hoc strip step with a CI warning.

Secrets to add (all under repo Settings → Secrets and variables → Actions):
- `MACOS_CERT_P12_BASE64` — base64 of the Developer ID Application .p12 export.
- `MACOS_CERT_PASSWORD` — the .p12 export password.
- `MACOS_SIGN_IDENTITY` — e.g. `Developer ID Application: Name (TEAMID)`.
- `MACOS_NOTARY_KEY_BASE64` — base64 of the App Store Connect API .p8 key.
- `MACOS_NOTARY_KEY_ID` — the API Key ID.
- `MACOS_NOTARY_ISSUER_ID` — the API Issuer ID.

## Plan

1. In `publish.yml` `build-macos`, after Flutter setup, add a `signing` detection
   step that sets `enabled=true` when `MACOS_SIGN_IDENTITY` is set (warns + false
   otherwise).
2. Add an "Import Developer ID certificate" step (guarded by `enabled == true`)
   that creates an ephemeral keychain and imports the .p12.
3. Add a "Sign with Developer ID (hardened runtime)" step (guarded) that signs each
   item in `Contents/Frameworks` inside-out then the app bundle with the Release
   entitlements, verifies, and asserts no `get-task-allow`.
4. Add a "Notarize and staple" step (guarded) using notarytool + stapler.
5. Gate the existing ad-hoc "Strip get-task-allow" step on `enabled == false` so it
   only runs on the fallback path.
6. Leave packaging/upload unchanged.

## Deviations

This section supersedes the single-secret gating described in **Thinking**
(paragraph starting "Design choice…") and **Plan** step 1. The plan is
append-only; these are the changes made during review rather than edits to the
text above.

- **Gate on all six secrets, not just `MACOS_SIGN_IDENTITY`.** `enabled=true`
  only when every one of `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`,
  `MACOS_SIGN_IDENTITY`, `MACOS_NOTARY_KEY_BASE64`, `MACOS_NOTARY_KEY_ID`, and
  `MACOS_NOTARY_ISSUER_ID` is set. Gating on the identity alone let a partially
  configured repo enter the signed path and fail mid-job; the full-set check
  falls back to ad-hoc cleanly and the warning names the missing secrets.
- **Notarization asserts `Accepted` explicitly** and dumps `notarytool log` on a
  non-Accepted status, because `notarytool submit --wait` does not reliably exit
  non-zero on an Invalid submission.
- **Decoded secret temp files are removed via `trap … EXIT`** so a mid-step
  failure cannot strand the `.p12` / `.p8` on the runner.
