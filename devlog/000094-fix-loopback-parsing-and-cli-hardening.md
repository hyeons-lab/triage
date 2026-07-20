# 000094 — fix/loopback-parsing-and-cli-hardening

## Intent

Follow-up to #107. A max-effort review pass over that branch surfaced findings
that arrived after it had already been pushed; #107 merged without them. This
lands them against current `main`.

Numbered 000094 rather than 000093 because #108 (`docs/remote-access`) already
claims 000093 and is still open.

## What Changed

### Loopback host detection (`flutter/triage_client/lib/main.dart`)

Two divergent predicates existed: a top-level `_isLoopbackHost` matching
`localhost` / `127.0.0.1` / `::1` / `[::1]`, and a `_isLocalVerificationHost`
method on the state class matching a broader set including
`startsWith('127.')`. The weaker one gated the dev-server fallback; the broader
one gated whether a clickable pairing URL is offered.

Unified into one predicate, with the prefix test replaced by a parsed
dotted-quad check.

### `triaged` CLI hardening (`crates/triaged/src/main.rs`)

- Argument parsing moved ahead of `logging::init`, so `--help` and `--version`
  work when the state directory is unusable.
- `parse_args` takes `OsString`, so a non-UTF-8 argument is a usage error
  rather than a panic inside `env::args()`.
- Bare `version` accepted as a first token, matching bare `help`; both are now
  documented in the usage text.
- `unreachable!()` in `run` replaced with `anyhow::bail!`.

## Decisions

- **`startsWith('127.')` is not a loopback test.** `127.example.com` and
  `127.0.0.1.evil.com` are legal DNS names — only the final label is barred
  from being all-numeric. The prefix test classified both as this machine. On
  the dev-server path that means dialing loopback and missing the daemon; on
  the pairing path it means rendering an attacker-controlled URL as a trusted
  "Verification URL" button carrying the device code. The latter was
  pre-existing on `main`, not introduced by #107.
- **`int.tryParse` alone is not enough either.** With no `radix` it accepts
  `0x7f`, a leading `+`/`-`, and surrounding whitespace, so `0x7f.0.0.0x1` —
  itself a legal DNS name — parsed as `127.0.0.1`. Octets are matched with
  `^[0-9]{1,3}$` before parsing. Dart's `$` is string-anchored and, unlike
  Python's, does not match before a trailing newline, so `'127\n'` is
  correctly rejected; verified rather than assumed.
- **The `127.1` shorthand is deliberately no longer "local".** `inet_aton`
  accepts it, but reimplementing that is what the prefix test was groping
  toward and how the bug arose. The failure direction is safe: the convenience
  pairing-URL button is withheld and the "Local approval required" fallback
  shown.
- **`Restart=on-failure` and the `service`-requires-HOME behavior left alone.**
  The reorder argument ("a command shouldn't fail because the log directory is
  unusable") applies to `service` too, but changing it broadens scope beyond
  the review findings.

## Issues

The fixes were produced by a review loop run *after* #107 was opened, so they
missed the merge. Project convention is to run the review before opening a PR;
doing it after meant the work landed a PR late. The findings themselves were
sound — one was a real bug introduced mid-loop and caught by the next round.

A test added mid-loop (`service_mode_still_yields_to_help`, in #107) asserted
buggy behavior and so locked a regression in rather than catching it. It was
replaced during #107's review. The lesson generalizes: a test is only evidence
if the asserted behavior was checked against what the callee actually does.

## Research & Discoveries

- Dart's `Uri.host` strips brackets from IPv6 literals (`http://[::1]/` →
  `::1`) and does not normalize between spellings, so `0:0:0:0:0:0:0:1` and
  `::ffff:127.0.0.1` must be matched literally. The old `'[::1]'` branch was
  therefore dead code.
- `flutter run -d chrome` binds loopback on its own port, which is why the
  dev-server fallback keys on "loopback host, non-daemon port" rather than on
  the port alone.

## Progress

- Rust: 266 workspace tests pass (11 arg-parser tests).
- Dart: 139 tests pass; `flutter analyze` reports no errors and nothing new in
  the changed regions.
- Verified end-to-end: `triaged --help` with `HOME` and `USERPROFILE` unset
  prints usage and exits 0; a non-UTF-8 argument reports a usage error instead
  of panicking; `triaged service help` still reaches the service CLI.
- The pairing-path regression test was confirmed to *fail* against the previous
  predicate before being kept, rather than assumed to be meaningful.

## Commits

- HEAD — fix(triage_client): parse loopback hosts instead of prefix-matching

## Next Steps

- #109 tracks the remaining gap from the same review: a stale persisted
  web-origin server entry defeats the same-origin fix for users who already
  loaded the client behind a proxy.
- `main` carries two devlogs numbered 000091 (from #105 and #106, which
  branched before the other landed). Renaming one would restore the sequence.
