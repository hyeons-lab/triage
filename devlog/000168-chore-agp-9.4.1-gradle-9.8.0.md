# 000168: chore/agp-9.4.1-gradle-9.8.0

## Intent

Upgrade the Flutter Android project's Android Gradle Plugin (AGP) to 9.4.1 and Gradle Wrapper to 9.8.0 with pinned SHA-256 distribution verification and transient download retry resilience.

## What Changed

- Plan: `devlog/plans/000168-01-agp-9.4.1-gradle-9.8.0.md`.
- 2026-10-18T21:56-0700 `flutter/triage_client/android/settings.gradle.kts`: bumped `com.android.application` plugin from `8.11.1` to `9.4.1`.
- 2026-10-18T21:56-0700 `flutter/triage_client/android/gradle/wrapper/gradle-wrapper.properties`: bumped `distributionUrl` from Gradle `8.14` to `9.8.0`, pinned `distributionSha256Sum`, enabled `validateDistributionUrl=true`, and configured `retries=3` with `retryBackOffMs=500`.

## Decisions

- 2026-10-18T21:56-0700 Pin `distributionSha256Sum` for `gradle-9.8.0-all.zip` and set `retries=3` so wrapper downloads verify integrity and survive transient CI network resets.

## Commits

- 1e8110c: chore(client): bump AGP to 9.4.1 and Gradle to 9.8.0
- HEAD: docs(devlog): add 000168 devlog/plan and enable gradle wrapper retries

## Progress

- 2026-10-18T21:56-0700: rebased onto `fix/session-reload-flicker`, verified `gradle-9.8.0-all.zip` SHA-256 and AGP 9.4.1 coordinates, enabled wrapper retries (`retries=3`), and added branch devlog and plan.
