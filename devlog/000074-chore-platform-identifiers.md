# 000074 — chore/platform-identifiers

**Agent:** Claude (claude-opus-4-8) @ triage branch chore/platform-identifiers

## Intent

Follow-up to #84: replace the remaining `com.example` Flutter-template
placeholders on the non-Apple platforms with platform-appropriate identifiers.

## What Changed

2026-06-17T21:27-0700 android/app/build.gradle.kts — `namespace` and
`applicationId` → `com.hyeonslab.triage_client` (no hyphen; valid Java package).

2026-06-17T21:27-0700 android/app/src/main/kotlin/.../MainActivity.kt — moved from
`com/example/triage_client/` to `com/hyeonslab/triage_client/` (git rename) and
updated the `package` declaration to match the namespace.

2026-06-17T21:27-0700 linux/CMakeLists.txt — `APPLICATION_ID` →
`com.hyeonslab.triage_client`.

2026-06-17T21:27-0700 windows/runner/Runner.rc — `CompanyName` → `Hyeons Lab`;
`LegalCopyright` → `Copyright (C) 2026 Hyeons Lab. All rights reserved.`

2026-06-17T21:27-0700 macos/Runner/Configs/AppInfo.xcconfig — `PRODUCT_COPYRIGHT`
→ `Copyright © 2026 Hyeons Lab. All rights reserved.` (the macOS bundle id itself
was handled in #84).

## Decisions

2026-06-17T21:27-0700 Used `com.hyeonslab` (no hyphen) for Android/Linux
reverse-DNS identifiers because a hyphen is illegal in an Android Java-package
`namespace`; the Apple bundle id (#84) keeps the hyphenated `com.hyeons-lab`
since hyphens are valid there. Human-readable company/copyright fields use the
display form `Hyeons Lab`.

## Verification

2026-06-17T21:27-0700 `flutter build apk --debug` (Java 21 Zulu) succeeded —
confirms the renamed namespace, Kotlin package, and on-disk directory agree.
Linux/Windows are not buildable on macOS; their edits are string-only (APPLICATION_ID
and `.rc` version strings) and cannot affect compilation.

## Commits

HEAD — chore(client): rebrand non-Apple platform identifiers off com.example
