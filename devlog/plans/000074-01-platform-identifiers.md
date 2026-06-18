## Thinking

Follow-up to #84 (Apple bundle id). The remaining `com.example` placeholders use
non-Apple conventions, so they need platform-appropriate values rather than the
Apple `com.hyeons-lab.triageClient` string (a hyphen is invalid in an Android
Java-package `namespace`):

- Android `namespace` + `applicationId`: reverse-DNS Java package → `com.hyeonslab.triage_client`.
- Android Kotlin source: `package` declaration + on-disk directory must match the namespace.
- Linux `APPLICATION_ID`: reverse-DNS → `com.hyeonslab.triage_client`.
- Windows `.rc` CompanyName / LegalCopyright: human-readable → `Hyeons Lab`.
- macOS `PRODUCT_COPYRIGHT`: human-readable → `Hyeons Lab` (the bundle id itself is #84's).

## Plan

1. Android: `build.gradle.kts` namespace + applicationId → `com.hyeonslab.triage_client`;
   `git mv` `MainActivity.kt` from `com/example/triage_client/` to
   `com/hyeonslab/triage_client/` and update its `package` line.
2. Linux: `CMakeLists.txt` APPLICATION_ID → `com.hyeonslab.triage_client`.
3. Windows: `Runner.rc` CompanyName → `Hyeons Lab`; LegalCopyright → `Hyeons Lab`.
4. macOS: `AppInfo.xcconfig` PRODUCT_COPYRIGHT → `Hyeons Lab`.
5. Verify with `flutter build apk --debug` (Java 21) — confirms the namespace/
   package plumbing. Linux/Windows can't be built on macOS; their changes are
   string-only.
