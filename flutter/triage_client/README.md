# triage_client

A Flutter-based cross-device remote client for **Triage**, the attention-routing
terminal supervisor.

## Overview

This is the human-interface remote client for Triage. From a single codebase it
targets **Web (PWA), iOS, Android, macOS, Windows, and Linux**. It connects to
the `triaged` daemon over a WebSocket, observes live terminal sessions, and
drives input through Triage's one-writer input-lease model. The pairing token is
kept in secure storage, so the client reconnects on later launches without
re-pairing.

## Getting the client

### Prebuilt desktop builds

Native desktop builds (macOS, Windows, Linux) are attached to every
[GitHub release](https://github.com/hyeons-lab/triage/releases) as
`Triage-<os>-v<version>` archives. These builds are **unsigned**, so each OS
warns before running them — see
[Prebuilt desktop clients](../../crates/triaged/README.md#prebuilt-desktop-clients)
in the `triaged` docs for the per-platform unzip / unquarantine / "Run anyway"
steps.

### Build from source

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(stable channel; the project builds with Flutter `3.44.0` / Dart `>=3.11`).

```bash
cd flutter/triage_client
flutter pub get

# Run on a connected device or desktop target:
flutter run -d macos        # or: windows, linux, chrome, <ios/android device id>

# Or produce a release build:
flutter build macos         # or: windows, linux, web, apk, ipa
```

## Connecting to a daemon

On first launch, enter the address of your `triaged` daemon. The field accepts:

- a bare host or IP — `host` → `ws://host:7777/ws`
- `host:port`, or a bracketed IPv6 literal — `[::1]:7777`
- a full URL — `ws://`, `wss://`, `http://`, or `https://` (http→ws, https→wss;
  the path defaults to `/ws` and the port to `7777`)

The default is `ws://127.0.0.1:7777/ws` (a daemon on the same machine).

When the daemon has pairing enabled (the default), the client completes a
one-time device-code + PIN exchange before it can attach: it shows a device
code, you approve it on the daemon host and read back a PIN, and the client
stores the resulting bearer token for future launches. See
[Pairing](../../crates/triaged/README.md#pairing) in the `triaged` docs for the
full flow and the remote/Tailscale approval options.

> Triage serves plain HTTP/WebSocket and terminates no TLS itself. For `wss://`
> from another device, front the daemon with a reverse proxy (e.g. Caddy or
> nginx), as described in the `triaged` docs.

## Development

```bash
flutter analyze
flutter test
```

Both run in CI (the "Flutter (analyze + test)" job).
