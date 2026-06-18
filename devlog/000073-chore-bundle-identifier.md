# 000073 — chore/bundle-identifier

**Agent:** Claude (claude-opus-4-8) @ triage branch chore/bundle-identifier

## Intent

Replace the Flutter template placeholder Apple bundle identifier
`com.example.triageClient` with `com.hyeons-lab.triageClient` so the macOS (and
iOS) app ships under the project's own identity instead of `com.example`.

## What Changed

2026-06-17T21:11-0700 flutter/triage_client/macos/Runner/Configs/AppInfo.xcconfig
— `PRODUCT_BUNDLE_IDENTIFIER` → `com.hyeons-lab.triageClient`.

2026-06-17T21:11-0700 flutter/triage_client/macos/Runner.xcodeproj/project.pbxproj
— macOS RunnerTests bundle id (3 build configs) →
`com.hyeons-lab.triageClient.RunnerTests`.

2026-06-17T21:11-0700 flutter/triage_client/ios/Runner.xcodeproj/project.pbxproj
— iOS app bundle id (3 configs) → `com.hyeons-lab.triageClient`; iOS RunnerTests
(3 configs) → `com.hyeons-lab.triageClient.RunnerTests`. Changed for parity with
macOS since both shared the identical placeholder.

## Decisions

2026-06-17T21:11-0700 Scoped to Apple bundle identifiers only — Android
(`namespace`/`applicationId`) and Linux (`APPLICATION_ID`) use
`com.example.triage_client`, and a hyphen (`hyeons-lab`) is invalid in an Android
Java package `namespace`; Windows uses `com.example` as an `.rc` CompanyName.
Those need separate, convention-valid identifiers and are left as follow-ups.

2026-06-17T21:11-0700 Left the `PRODUCT_COPYRIGHT` placeholder (`com.example.`)
untouched — it is not a bundle identifier; flagged as a follow-up.

## Issues

2026-06-17T21:11-0700 Changing the bundle id changes the default Keychain access
group, so `flutter_secure_storage` tokens saved under the old id are not visible
to the renamed app — users re-pair once after upgrading. Expected, acceptable.

## Verification

2026-06-17T21:11-0700 `flutter build macos --release` succeeded; the built
`Triage.app` reports `CFBundleIdentifier = com.hyeons-lab.triageClient`.

## Next Steps

- Rebrand the non-Apple placeholders with valid per-platform identifiers:
  Android `namespace`/`applicationId` + Kotlin package dir + `MainActivity.kt`,
  Linux `APPLICATION_ID`, Windows `.rc` CompanyName/LegalCopyright, and the macOS
  `PRODUCT_COPYRIGHT` string.

## Commits

HEAD — chore(client): set Apple bundle identifier to com.hyeons-lab.triageClient
