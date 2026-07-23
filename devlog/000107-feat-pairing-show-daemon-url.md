# 000107 — feat/pairing-show-daemon-url

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/pairing-show-daemon-url

## Intent

When pairing a browser/client against a **remote** daemon, the pairing screen
showed the device code but no URL — only "Local approval required / Use the
daemon host pairing page or run triage pair". You had to already know to open
`http://127.0.0.1:<port>/pair` on the daemon machine. Always show the device
code **and** the daemon-host URL to visit.

## What Changed

- 2026-07-22T21:47-0700 `flutter/triage_client/lib/main.dart` — added
  `_daemonHostPairingUri`, which always returns
  `http(s)://127.0.0.1:<wsPort>/pair?device_code=<code>` — the URL to open on the
  machine running triaged. `_PairingView` gained a `daemonHostUri` and its remote
  branch (formerly "Local approval required") now renders that URL as a
  selectable instruction with a "Copy pairing URL" button, plus a reworded
  header sentence. The loopback branch — the existing clickable "Verification
  URL" button via `_verificationUriForClient` — is unchanged.
- 2026-07-22T21:47-0700 `flutter/triage_client/test/widget_test.dart` — the two
  remote-case tests now assert the instruction shows `127.0.0.1:7777/pair` +
  `device_code=…` and is **not** a clickable button, while keeping the security
  guard that the daemon's *claimed* host (a LAN IP, or `127.0.0.1.evil.com`) is
  never rendered. The local clickable-case test is untouched.

- 2026-07-22T21:57-0700 `flutter/triage_client/lib/main.dart` +
  `test/widget_test.dart` — review follow-up. `_daemonHostPairingUri` now
  returns `Uri?` and yields null when the connection carries no explicit port
  (e.g. a `wss://host/ws` reverse proxy on 443): the daemon's real loopback
  listen port is unknowable from the client, so printing one would name the
  proxy's public port and not resolve on the daemon box. The remote header
  sentence became three-way so it never promises "the URL below" when the
  fallback ("Use the daemon host pairing page or run triage pair.") is shown.
  Added a widget test for the no-port proxy case.

- 2026-07-22T22:11-0700 `flutter/triage_client/lib/main.dart` — PR #126 review
  (Copilot). `_requestPairingChallenge` now clears the prior challenge
  (`_pairingDeviceCode`, both pairing URIs, expiry) when a new request starts, so
  a refresh renders the loading spinner instead of the previous device code and
  its now-embedded pairing URL — a stale URL would point at a challenge that no
  longer exists. Also replaced redaction-token placeholder text that had leaked
  into the `_daemonHostPairingUri` doc comment and the plan file with the real
  `127.0.0.1` literal / generic wording; the token round-trip had failed across a
  session boundary, leaving placeholder text in the committed source.

## Decisions

- 2026-07-22T21:30-0700 Fixed loopback literal, never the claimed host — `/pair`
  only authorizes a same-host (loopback) request, so `127.0.0.1:<port>` is the
  correct address to open on the daemon box regardless of how the client reached
  it. Echoing the daemon's *claimed* host would reintroduce the exact attack the
  existing "127.0.0.1.evil.com is not local" test guards against (rendering an
  attacker-influenced name as a pairing URL carrying the device code). The port
  is the one the user typed to connect; the device code is already on screen —
  so the instruction leaks nothing new.
- 2026-07-22T21:30-0700 Clickable only on loopback — a clickable link opens the
  browser to the URL; on a remote client `127.0.0.1` is the *client's own*
  loopback, the wrong box. So the remote case shows the URL as copyable
  instruction text, and only the genuine loopback case (client on the daemon
  machine) keeps the clickable button. Kept `_verificationUriForClient` as-is so
  the local path and its tests don't change.

## Verification

`flutter analyze` clean for the change (the one remaining `verificationUri!`
warning is verbatim in `origin/main`, pre-existing); `flutter test` — 189 pass;
`dart format` clean. `/review-fix-loop max` ran two reviewers: the sole
actionable finding (reverse-proxy port) is fixed above; remaining items were
comment nitpicks (applied) and an intentional helper-duplication kept for
security clarity (skipped).

## Commits

- HEAD — feat(triage_client): always show the daemon-host pairing URL
