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

## Next Steps

- Run the app against a live daemon before merging. The binary transport is
  verified at the handshake level and under unit tests, but no full
  request/response round-trip has been exercised against a real daemon, and this
  path has effectively never run in production.

## Commits

- HEAD — fix(triage_client): restore list_session_contexts and default to FlatBuffers
