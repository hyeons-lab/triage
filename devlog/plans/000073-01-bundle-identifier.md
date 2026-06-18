## Thinking

The macOS app shipped with the Flutter template placeholder bundle identifier
`com.example.triageClient`. A grep across `flutter/triage_client` (excluding
`build/`) shows `com.example` placeholders on every platform, but they use
different identifier conventions:

- Apple (macOS + iOS): `com.example.triageClient` — the CFBundleIdentifier.
- Android: `com.example.triage_client` as `namespace`/`applicationId`.
- Linux: `com.example.triage_client` as `APPLICATION_ID`.
- Windows: `com.example` as the `.rc` CompanyName/LegalCopyright.

The request is to change "the bundle identifier" to `com.hyeons-lab.triageClient`.
Hyphens are valid in an Apple CFBundleIdentifier but NOT in an Android `namespace`
(which must be a valid Java/Kotlin package — `hyeons-lab` would be illegal). The
given value (`triageClient`, camelCase, with a hyphen) is unambiguously the Apple
form, so this change is scoped to the Apple bundle identifiers. Android/Linux/
Windows need different, valid identifiers and are out of scope here.

Scope: macOS app + macOS RunnerTests, iOS app + iOS RunnerTests. The copyright
placeholder (`com.example.`) is a separate string, not a bundle id, and is left
alone.

Implication: the default Keychain access group is derived from the bundle id, so
`flutter_secure_storage` entries saved under `com.example.triageClient` won't be
visible to the renamed app — users re-pair once after upgrading. Acceptable.

## Plan

1. Replace `com.example.triageClient` → `com.hyeons-lab.triageClient` in:
   - `macos/Runner/Configs/AppInfo.xcconfig` (PRODUCT_BUNDLE_IDENTIFIER)
   - `macos/Runner.xcodeproj/project.pbxproj` (RunnerTests, 3×)
   - `ios/Runner.xcodeproj/project.pbxproj` (app 3×, RunnerTests 3×)
2. Verify with `flutter build macos --release` and confirm the built app's
   `CFBundleIdentifier` is `com.hyeons-lab.triageClient`.
3. Devlog + commit + PR. Note the Keychain re-pair implication and the
   still-placeholder Android/Linux/Windows identifiers as follow-ups.
