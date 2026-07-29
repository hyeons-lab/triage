# 000110 — fix/flatbuffers-transport

**Agent:** Claude (claude-opus-5[1m]) @ triage branch fix/flatbuffers-transport

## Intent

The checked-in Dart FlatBuffers bindings had drifted from the shared schema,
missing `ListSessionContextsRequest` and `SessionContextsResult` entirely, so
`list_session_contexts` had no request case and no result case. Regenerate them,
fill in the missing cases, stop the drift recurring, and make FlatBuffers the
negotiated default now that the binary path is actually complete.

Split out of `feat/rail-activity-grouping`, where this work was originally done:
it changes the encoding of every request and response, which is a far wider
blast radius than that branch's session-rail change, and it should land and be
observed on its own.

## What Changed

- 2026-07-29T08:29-0700 `flutter/triage_client/lib/generated/` — regenerated from
  `crates/triage-core/schema/triage.fbs`. Purely additive (246 insertions, 4
  deletions; the deletions are enum-tail punctuation and two `maxValue` bumps).
  Restores the missing `ListSessionContextsRequest`, `SessionContextsResult` and
  `SessionContextEntry` types.
- 2026-07-29T08:29-0700 `flutter/triage_client/lib/services/triage_websocket_client.dart`
  — added the `list_session_contexts` case to `_serializeFlatBuffersRequest` and
  `case 14: SessionContextsResult` to `_parseServerResult`, the latter shaped to
  match the JSON form exactly so `listSessionContexts` reads one map whichever
  transport produced it. Also `websocketSubprotocols`
  (`['triage-flatbuffers', 'triage-json']`), offered at connect.
- 2026-07-29T08:29-0700 `scripts/generate-dart-flatbuffers.sh` (new) +
  `.github/workflows/ci.yml` — regeneration script with a non-mutating `--check`
  mode (generates into a temp dir and diffs), run in the Flutter CI job with
  flatc pinned to match the Rust jobs.
- 2026-07-29T08:29-0700 `flutter/triage_client/analysis_options.yaml` — exclude
  `lib/generated/**` from analysis.
- 2026-07-29T09:20-0700 `flutter/triage_client/lib/services/flatbuffers_js_compat.dart`
  (new) — dart2js-safe uint64 read/write helpers, plus a patch step in
  `scripts/generate-dart-flatbuffers.sh` that rewrites every generated uint64
  call site to route through them. Without this the FlatBuffers default breaks
  the web client outright; see Issues.
- 2026-07-29T09:20-0700 `.github/workflows/ci.yml` — added a
  `flutter test --platform chrome` step over the transport tests, scoped to
  `triage_websocket_client_test.dart` and `flatbuffers_js_compat_test.dart`
  because the storage and widget suites have unrelated pre-existing web
  failures. Also dropped the redundant `version:` inputs on every setup-flatc
  call here and in `publish.yml`: the action already defaults to the pin, and
  the generator script now reads that same default, so 6 copies became 1.
- 2026-07-29T09:20-0700 `flutter/triage_client/lib/services/triage_websocket_client.dart`
  — `HelloResult` now carries `server_version`, `update_available` and
  `latest_version` (it dropped all three, so the self-update fields would have
  stopped arriving the moment binary became the default); added the
  `UpdateAvailablePayload` decode branch and the `update_available` dispatch
  branch; extracted `flatBuffersSubprotocol`/`jsonSubprotocol` constants; and
  made the unknown-payload fallthrough return a tagged `unknown` map with a
  debug assert instead of a bare `{}`.
- 2026-07-29T08:29-0700 `flutter/triage_client/test/triage_websocket_client_test.dart`
  — three tests: the offered subprotocol order, the request encoding to
  `ListSessionContextsRequest`, and a `SessionContextsResult` response decoding
  with a repo-less entry intact.

## Decisions

- 2026-07-29T08:29-0700 Keep `triage-json` as the second offer rather than
  dropping it. The daemon takes the first token it recognizes, so retaining JSON
  costs nothing when binary is available and leaves a daemon predating the format
  — or one ignoring the header — something to negotiate. No version check is
  needed on either side, because `isFlatBuffersNegotiated` reads the protocol the
  server *selected*, so declining the binary format falls back transparently.
- 2026-07-29T08:29-0700 Exclude the generated bindings from analysis rather than
  extending their `ignore_for_file` header, which `flatc` overwrites on every
  regeneration. Takes `flutter analyze` from 89 findings to 5; the rest are
  genuine and in hand-written code.
- 2026-07-29T08:29-0700 Add a CI drift gate rather than only regenerating once.
  The Rust bindings regenerate from `build.rs` on every compile while the Dart
  ones are checked in with no trigger — that asymmetry *is* the cause of the
  drift, so a one-off regeneration would leave it in place.
- 2026-07-29T08:29-0700 Rebuilt against `main`'s schema rather than cherry-picked
  from the rail branch. Those commits' regenerated bindings carry a
  `last_activity_ms` field added by that branch's schema change, so a cherry-pick
  would have dragged rail work in with them.

## Research & Discoveries

- 2026-07-29T08:29-0700 The bug was **latent, not live**. Control requests use
  FlatBuffers whenever the `triage-flatbuffers` subprotocol is negotiated, but the
  client offered only `triage-json`, so the daemon never selected binary and
  `isFlatBuffersNegotiated` was always false in production. The missing cases
  would have fired the moment the default flipped — which is why the fix and the
  flip belong together, in that order.
- 2026-07-29T08:29-0700 Verified coverage before flipping, in all three
  directions: 14/14 request types the client sends have a case, 14/14 result types
  decode, and 5/5 `SessionEventPayload` union members are handled.
- 2026-07-29T08:29-0700 Verified negotiation against a *live* daemon with raw
  WebSocket upgrades, since the suite's fakes cannot prove the daemon's half:

  | Offered | Selected |
  | --- | --- |
  | `triage-flatbuffers, triage-json` | `triage-flatbuffers` |
  | `triage-json` | `triage-json` |
  | `triage-json, triage-flatbuffers` | `triage-json` |

  The third row is the one that matters: the daemon takes the client's *first*
  recognized token, with no server-side preference, so the order in
  `websocketSubprotocols` is genuinely what decides the format.

## Issues

- 2026-07-29T08:52-0700 CI's drift check failed on the first run over a single
  blank line: the bindings were generated locally with flatc 25.12.19 while CI
  pins 25.2.10. flatc's output is not byte-stable across releases, so the
  checked-in file is only meaningful against one compiler version — a hazard
  flagged as a nitpick in review and immediately proven real. Regenerated with
  25.2.10, and the script now verifies `flatc --version` and fails with the
  release URL rather than producing output that CI rejects for no real reason.
- 2026-07-29T08:52-0700 Regeneration wrote into the existing output directory
  without clearing it (raised by Copilot on the PR). A type removed or renamed in
  the schema would leave its stale file behind, and `--check` would then report
  drift that re-running the script never fixes. Now regenerates into a cleaned
  directory.

- 2026-07-29T09:20-0700 **The default flip broke the Flutter web client, and
  neither the review nor CI could see it.** dart2js has no
  `ByteData.getUint64`/`setUint64` — both throw
  `Unsupported operation: Uint64 accessor not supported by dart2js` — and flatc
  emits exactly those for every `ulong` field. `flutter test --platform chrome`
  failed 5 of 26 transport tests: attach snapshots (`output_seq`,
  `bytes_logged`), event envelopes (`event_seq`), pairing challenges
  (`expires_at`), and the `subscribe_session_events` request (`after_event_seq`).
  In production that is worse than a crash: the connection succeeds, `hello` and
  `list_sessions` work, then attach times out and every output event becomes a
  `protocol_error` — the exact silent degradation this branch set out to
  eliminate, on the build the daemon serves as its own embedded UI.

  It had been fixed once already. `ad72b56` (#48) hand-patched a
  `_vTableGetUint64` into the generated file; `949fd6f` (#53) regenerated it
  away. Nothing failed then either, because the client was still pinned to
  `triage-json`. Two independent blind spots kept it invisible: `flutter test`
  runs on the VM, where the accessors exist, and the JSON pin meant the binary
  path never ran.

  Worse, the drift gate added earlier on this branch *forecloses* that fix — it
  demands byte-identical stock `flatc --dart` output, so reinstating a patch
  inside `lib/generated/` now fails CI. The gate and the patch had to be
  designed together.

  Resolved by moving the fix out of the generated file into
  `lib/services/flatbuffers_js_compat.dart` and having the generator script
  apply the call-site rewrite in *both* modes, so `--check` compares patched
  against patched. Verified the gate now catches the exact 949fd6f regression: a
  stock `flatc --dart` over the output directory makes `--check` exit 1.
- 2026-07-29T09:20-0700 Writing uint64 was the harder half. Reads assemble from
  two `getUint32`, which is what #48 did — but `Builder`'s `_prepare`,
  `_trackField` and `_setUint64AtTail` are all private, so there is no way to
  place eight bytes in a vtable slot from outside the package. `addFloat64` is
  the way through: identical size, alignment and slot accounting, and
  `setFloat64` *is* supported by dart2js. Writing the integer's bit pattern as a
  double produces a byte-identical buffer, asserted directly against
  `fb.Builder.addUint64` on the VM. Safe because dart2js caps ints at 2^53, so
  the high half never reaches the exponent bits — the value is always a
  subnormal double, never a NaN whose payload an engine may canonicalize.
- 2026-07-29T09:20-0700 The `update_available` push turned out to be dropped on
  *both* transports, not just the binary one: `_handleIncomingMessage` never had
  a branch for it, so the daemon has been sending an event this client discards.
  Forwarded it briefly, then reverted — wiring up a push nothing subscribes to
  is a self-update change, not a transport one, and this branch was split off
  precisely to keep its blast radius narrow. The FlatBuffers decoder now
  produces the same map the JSON decoder does and both are dropped at dispatch:
  parity preserved, behaviour unchanged. Left as a follow-up.
- 2026-07-29T09:35-0700 Review round 2 caught the version-guard error path being
  unreachable: under `set -euo pipefail`, a `grep` that matches nothing aborts
  the script at the assignment, so the friendly "could not parse a version"
  message could never print. Confirmed by running the script against a stub
  `flatc` that prints garbage — exit 1, no output at all. Needed `|| true` on
  the command substitution. A reminder that `set -e` silently deletes the error
  handling written just below it.
- 2026-07-29T09:35-0700 Regeneration left `lib/generated` at mode 700, inherited
  from `mktemp -d` by `cp -R "$SCRATCH" "$OUT_DIR"`. Git does not track
  directory modes, so it would never have shown up in a diff. Fixed by copying
  `"$SCRATCH/."` into a directory created under the normal umask.
- 2026-07-29T09:35-0700 The post-patch guard was first written against the
  literal receiver `fbBuilder.addUint64(`, which would let a differently-named
  builder slip through unpatched — the exact silent-on-VM, throws-in-browser
  failure the guard exists to prevent. Now receiver-agnostic and also covers
  `putUint64` and `writeListUint64`, filtering out only this patch's own
  rewritten calls.

## Next Steps

- Run the app against a live daemon before merging. The binary transport is
  verified at the handshake level and under unit tests, but no full
  request/response round-trip has been exercised against a real daemon, and this
  path has effectively never run in production.
- The chrome CI step names its two test files literally, so a third transport
  test added later silently never runs on web — the same blind-spot-by-omission
  this branch is about. A `test/` glob is not available yet: 48 tests across the
  storage and widget suites fail on web for unrelated pre-existing reasons.
  Worth fixing those and widening the step.
- Forward the `update_available` push (dropped on both transports today) as part
  of self-update work, not here.

## Lessons Learned

- 2026-07-29T09:20-0700 "Verified coverage in all three directions" was true and
  insufficient. The audit covered the protocol axis exhaustively — 14/14 request
  types, 14/14 result types, 5/5 event union members — and never touched the
  platform axis, which is where the actual break was. When a change flips which
  code path executes, enumerate the *environments* that path runs in, not just
  the messages it carries.
- 2026-07-29T09:20-0700 A test suite that cannot fail on a platform is not
  coverage of that platform. `flutter test` is VM-only by default, so no amount
  of transport testing would ever have caught this; the gap closes only by
  adding `--platform chrome`, not by adding more tests.
- 2026-07-29T09:20-0700 A drift gate over generated code silently outlaws every
  hand fix to that code. Deciding where the fix lives — inside the generated
  file or beside it — is part of designing the gate, not a detail to settle
  later.

## Commits

- 9f41e4e — fix(triage_client): restore list_session_contexts and default to FlatBuffers
- 4be856b — fix(ci): generate Dart bindings with the pinned flatc and a clean output dir
- HEAD — fix(triage_client): keep the binary transport working on Flutter web
