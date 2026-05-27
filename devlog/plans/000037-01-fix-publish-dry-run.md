# Plan: Fix Publish Dry Run

## Thinking
The crates.io publish dry-run failed because subosito/flutter-action was configured with an invalid version '3.12.0' (which is the Dart SDK version, not a Flutter version).
Additionally, we need to:
1. Lock Flutter SDK floor version to 3.44.0.
2. Filter file includes in `crates/triaged/Cargo.toml` to stay under the 10 MiB limit.
3. Use `cargo package` with path overrides in `publish.yml` for dry-run verification so that unpublished crates.io internal dependency checking is bypassed safely.

## Plan
1. Update `.github/workflows/publish.yml` to specify `flutter-version: '3.44.0'` and replace the publish dry-run steps with `cargo package` overrides.
2. Restrict the include path filter in `crates/triaged/Cargo.toml`.
3. Update environment constraints in `flutter/triage_client/pubspec.yaml` and `pubspec.lock`.
