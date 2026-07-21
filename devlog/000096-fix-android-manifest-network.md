# 000096 — fix/android-manifest-network

## Agent

Claude Code (Opus 4.7, 1M context).

## Intent

Restore native-Android network access on release APKs. The CI-produced
`app-release.apk` (see `.github/workflows/ci.yml`) has no `INTERNET`
permission and no cleartext-traffic opt-in, so the phone app can't reach
`triaged` at all. Symptom: perpetual "Reconnecting..." in the UI and zero
connection attempts in `triaged.log` from the device.

## What Changed

- `flutter/triage_client/android/app/src/main/AndroidManifest.xml`
  - Added `<uses-permission android:name="android.permission.INTERNET"/>`
    at the manifest level.
  - Added `android:usesCleartextTraffic="true"` on `<application>`.

## Decisions

- **`src/main` rather than a new `src/release`**: the missing bits are
  needed by every non-debug build (release, profile, and any future
  variant). Duplicating them into a variant-specific manifest is the
  bug that got us here — the `debug` variant declared `INTERNET` and
  nothing else did.
- **Blanket `usesCleartextTraffic="true"` over `network_security_config`**:
  the daemon terminates no TLS by design (`docs/remote-access.md`), and
  the user configures daemon addresses at runtime via the multi-server
  switcher (PR #89), so an allowlist would need every host known ahead
  of time. Confidentiality on remote paths comes from the tailnet, not
  from HTTPS.

## Issues

Root cause is a Flutter template artefact: `flutter create` scaffolds
`INTERNET` only into the debug variant to keep hot-reload working. On
this project the runtime dependency on network access is the same for
every build, so the split was never right.

## Research & Discoveries

- Reproduced by pointing a Pixel 10 Pro Fold (`100.65.193.69`) at
  `100.85.83.15:7777`. The phone's browser loaded `/` and issued a
  pairing device code (log: `triage-flutter-client-b602b72d...`), so
  the daemon, tailnet, and Windows Firewall are all fine. The native
  app produced no log entries at all — confirming the OS blocked the
  socket before it left the phone.
- The debug variant's `INTERNET` line is preserved: removing it would
  regress `flutter run` on any device where the debug APK is installed
  first without the merged main declaration.

## Review

PR #114, first round: the devlog H1 omitted its `000096` prefix. Every other
file in `devlog/` opens `# 0000NN — <branch>`; corrected to match.

## Commits

- HEAD — fix(triage_client): allow network + cleartext in release Android manifest

## Progress

Manifest patched, devlog + plan added. Awaiting CI APK for
sideload-verification on the phone. Locally-built release APK against
the patched manifest is what we would install; CI reproduces the same
build.

## Next Steps

- Merge; download the CI APK from the run summary; sideload.
- If a follow-up hardens transport, revisit whether a
  `network_security_config` scoped to the tailnet CGNAT range
  (`100.64.0.0/10`) plus LAN literals is worth the maintenance cost.
