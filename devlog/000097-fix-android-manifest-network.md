# 000097 — fix/android-manifest-network

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
  needed by every build, and `src/main` is the one manifest they all
  merge. Duplicating them per variant is the bug that got us here —
  `debug` and `profile` each declared `INTERNET` while `src/main` did
  not, so the only variant without it was the one that ships.
- **Blanket `usesCleartextTraffic="true"` over `network_security_config`**:
  the daemon terminates no TLS by design (`docs/remote-access.md`), and
  the user configures daemon addresses at runtime via the multi-server
  switcher (PR #89), so an allowlist would need every host known ahead
  of time. Confidentiality on remote paths comes from the tailnet, not
  from HTTPS.

## Issues

Root cause is a Flutter template artefact: `flutter create` scaffolds
`INTERNET` into the `debug` and `profile` variants — the two the tool
attaches to for hot reload and profiling — and leaves `src/main` alone,
on the assumption that an app needing the network in production will
declare it there itself. This project never did. Because the runtime
dependency on network access is identical for every build here, the
split was never right for it.

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

PR #114, first round: the devlog H1 omitted its number prefix. Every other
file in `devlog/` opens `# 0000NN — <branch>`; corrected to match.

Second round: the write-up had the prior state wrong. It said `INTERNET`
lived only in the `debug` variant, but `src/profile/AndroidManifest.xml`
declares it too — the template scaffolds both. That does not change the fix
(release still shipped without it, which is the bug), but it misdescribes
which builds were affected: profile builds had network access all along, and
release was the *only* variant without it. Corrected in the plan, the
Decisions bullet, and the Issues section.

Also documented the two manifest entries in place. `usesCleartextTraffic` in
particular reads like something to tidy up during a security pass, and the
reason it must stay lives in `docs/remote-access.md` where nobody editing the
manifest will see it. Verified the claim it rests on before writing it down:
`remote.tls_cert`/`tls_key` appear in `crates/triage-core/src/config.rs` only
to be validated, and nothing in the daemon ever reads them.

Renumbered 000096 -> 000097 after #113 merged and took 000096. Both branches
picked the same next number while running in parallel, which is why the repo
already carries several duplicates (000066, 000068, 000091). Since #113 landed
first, the convention's "highest in devlog/, incremented" now resolves to
000097 here.

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
