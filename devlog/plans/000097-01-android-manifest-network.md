## Thinking

The release Android APK produced by CI cannot open any network socket, so
the app on a Pixel loops "Reconnecting..." forever while the daemon log
records zero connection attempts from the phone. Two independent Android
manifest defaults hit at once:

1. **`INTERNET` is declared in every variant except the one that ships.**
   `android/app/src/debug/` and `android/app/src/profile/` both declare
   it; `src/main` does not. Debug and profile installs therefore have
   network access, and only a release build — which merges `src/main`
   alone — comes out without it. `flutter build apk --release`, what CI
   runs and uploads as an artifact, produces an APK Android refuses to
   give a socket to. Silent by design: no permission dialog, no log
   entry.

2. **Cleartext traffic is blocked on `targetSdk >= 28`**. `triaged`
   terminates no TLS (`docs/remote-access.md`), so the client speaks
   plain `ws://`. Without `usesCleartextTraffic="true"` (or a
   `network_security_config`) Android drops the connect before the
   syscall reaches the socket.

Bug pattern is the same as PR #101's manifest churn: the `main` variant
is the one that ships. Fix belongs there.

## Plan

- `flutter/triage_client/android/app/src/main/AndroidManifest.xml`:
  - Add `<uses-permission android:name="android.permission.INTERNET"/>`
    as a sibling of `<application>` (Android convention).
  - Add `android:usesCleartextTraffic="true"` to `<application>`. The
    daemon has no TLS termination and the app talks to it over Tailscale
    or LAN, so this is intended, not a lapse.
- Leave `src/debug/AndroidManifest.xml` alone. Its `INTERNET` line has a
  comment justifying it as a Flutter-tooling requirement, and the merged
  result is idempotent.
- No `network_security_config.xml` — a per-host allowlist would need to
  know every daemon address ahead of time, which the multi-server
  switcher (PR #89) makes user-configurable at runtime.
- Verify: `flutter build apk --release` produces an APK whose merged
  manifest includes both attributes; sideload on device, confirm the
  daemon log shows an accepted TCP connection from the phone's tailnet
  IP.
