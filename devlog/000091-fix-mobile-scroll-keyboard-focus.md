# 000091 — fix/mobile-scroll-keyboard-focus

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/mobile-scroll-keyboard-focus

## Intent

On mobile, scrolling up through the terminal scrollback keeps handing focus to
the text input, which raises the soft keyboard. The keyboard insets the
Scaffold, so the scroll position jumps and the user has to fight the viewport
while scrolling. Fix scrolling so it never raises the keyboard.

Also add a CI job that builds the Android APK and uploads it as an artifact, so
every run's summary offers a downloadable APK — used here to sideload and verify
the scroll fix on-device. Bundled onto this branch (user's call) so this PR's CI
run produces a testable APK containing the fix.

## What Changed

2026-07-18T13:51-0700 flutter/triage_client/lib/widgets/terminal_pane_stub.dart —
`_handlePointerDown` called `_focusTerminal()` on every raw `Listener`
pointer-down, *before* the `_isMobile` early-return. On mobile the pointer-down
that begins a scroll swipe therefore requested focus on the xterm IME node
(mobile runs `hardwareKeyboardOnly: false`), raising the soft keyboard and
jumping the viewport. Guarded the focus call with `if (!_isMobile)` so it runs
on desktop only (click-to-focus before a mouse drag-select). Mobile tap-to-focus
is unchanged — it comes from the `GestureDetector(onTap: _focusTerminal)` that
wraps the view, which fires on a real tap, not a swipe.

2026-07-18T14:05-0700 .github/workflows/ci.yml — added an `android-apk` job:
JDK 17 (temurin, matching the gradle sourceCompatibility) + Flutter 3.44.0,
`flutter build apk --release`, then `actions/upload-artifact` publishes the
resulting `app-release.apk`. The release build is debug-keystore-signed (per the
release signingConfig in android/app/build.gradle.kts), so the artifact installs
directly without any release-signing secrets. Runs on the workflow's existing
triggers (push to main, every PR, workflow_dispatch), so any run's summary
carries a downloadable APK. Caching: `subosito/flutter-action`'s `cache: true`
already covers both the Flutter SDK and the pub cache; added
`gradle/actions/setup-gradle` to cache the Gradle user home (deps + wrapper +
build cache) for the Gradle that `flutter build apk` invokes — it writes the
cache only from the default branch, so PRs restore without polluting it.

## Decisions

- 2026-07-18T13:51-0700 Fix at the pointer-down seam, not by disabling
  `autofocus` or the scroll gesture — the only unwanted focus was the
  pointer-down one; `autofocus` (initial keyboard on session open) and
  tap-to-focus are both still desired. Keeping the change to the one offending
  call leaves desktop click-to-focus and all selection/drag paths untouched.
- 2026-07-18T14:05-0700 Residual (pre-existing, not in this diff): xterm's own
  `TerminalView._onTapDown` calls `requestKeyboard()` on mobile, so a *slow*
  press-then-scroll (tap deadline elapses before the drag claims the arena) can
  still raise the keyboard. A quick flick-scroll won't. The always-fires raw
  pointer-down path is what this fix removes; the xterm path lives in the
  third-party widget and can't be suppressed without wrapping it. Verify on-device.
- 2026-07-18T14:05-0700 APK CI job uses the debug-signed release build (no
  release-signing secrets) and a single universal APK, so the artifact is a
  one-file sideload from the run summary. Pinned actions/setup-java and
  actions/upload-artifact to commit SHAs (repo convention); subosito/flutter-action
  stays at `@v2` to match the existing `flutter` job.

## Issues

- None. `flutter analyze` clean on the changed file; full analyze + `flutter
  test` (132 passing) mirror CI. `actionlint` clean on ci.yml. APK built locally
  (`flutter build apk --release`, Java 21 Zulu) to confirm the gradle config
  produces `app-release.apk` at the path the artifact upload references.

## Commits

- f6d9315 — fix(client): stop mobile scroll from raising the soft keyboard
- HEAD — ci: build and upload the Android APK as a downloadable artifact

## Next Steps

- On-device confirm (iOS + Android): scrolling scrollback no longer raises the
  keyboard; tapping the terminal still does. Sideload the CI APK artifact to test.
