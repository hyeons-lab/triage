# 000110-01 — Make FlatBuffers the negotiated default

## Thinking

The Dart bindings had drifted from `triage.fbs`: `ListSessionContextsRequest`
and `SessionContextsResult` were missing entirely, so `list_session_contexts`
had neither a request case nor a result case. Nothing failed, because the client
offered only `triage-json` — the daemon never selected the binary format, so
`isFlatBuffersNegotiated` was false on every real connection and the whole
FlatBuffers path was dead code in production.

That is the shape of the problem: the encoder is fully wired and completely
unexercised. Any gap in it is invisible until the default flips, at which point
every gap surfaces at once. So the work is not "flip the default" — it is
"establish that the binary path is complete, then flip the default, then make it
impossible for it to rot back."

Three distinct failure modes to close:

1. **Coverage gaps.** Every request type the client sends, every result type it
   receives, and every event union member has to have a case. A missing one
   throws `UnimplementedError` (requests) or silently returns `{}` (results and
   events) — the silent kind is worse, because it looks like a working
   connection that just never delivers.

2. **Drift.** The Rust bindings regenerate from `build.rs` on every compile; the
   Dart ones are checked in with no trigger at all. That asymmetry is the actual
   cause, so a one-off regeneration fixes today and guarantees a repeat. Needs a
   CI gate, which in turn needs a regeneration script with a non-mutating
   `--check` mode.

3. **Platform.** `flutter test` runs on the Dart VM. The daemon serves this
   client as its embedded web UI (`crates/triaged/build.rs` runs
   `flutter build web --release`, i.e. dart2js). dart2js has no
   `ByteData.getUint64`/`setUint64` at all, and flatc emits exactly those for
   every `ulong` field. So the VM suite structurally cannot observe the platform
   where the binary transport actually ships.

Point 3 is not hypothetical: #48 hand-patched the generated file for dart2js and
#53 regenerated the patch away, with nothing failing, because the client was
still pinned to `triage-json`. A drift gate that mandates byte-identical stock
`flatc --dart` output would make that revert *permanent* — it would forbid the
only fix that has ever worked. The gate and the patch have to be designed
together: CI must compare patched output against patched output.

For the patch itself, reads are easy (assemble from two `getUint32`). Writes are
the interesting half, because `Builder`'s internals are private — there is no way
to write eight bytes into a vtable slot from outside the package. `addFloat64` is
the way through: same eight bytes, same alignment, same single vtable slot, and
`setFloat64` is supported by dart2js. Reinterpreting the integer's bit pattern as
a double gives a byte-identical buffer. Values are capped at 2^53 by dart2js
anyway, so the high half never reaches the exponent bits and the result is always
a subnormal — never a NaN whose payload an engine could canonicalize.

## Plan

1. Regenerate `flutter/triage_client/lib/generated/` from the schema with the
   flatc version CI pins, restoring the missing context types.
2. Add the `list_session_contexts` request case and the `SessionContextsResult`
   result case, shaping the latter to match the JSON form exactly so callers
   read one map whichever transport produced it.
3. Audit coverage in all three directions — requests, results, event union
   members — before changing any default.
4. Write `scripts/generate-dart-flatbuffers.sh` with `--check`, and gate it in
   CI. Read the flatc version pin from the setup-flatc action so local and CI
   cannot disagree.
5. Add `lib/services/flatbuffers_js_compat.dart` with dart2js-safe uint64 read
   and write helpers, and have the script rewrite every generated call site to
   route through them — in both regenerate and `--check` modes, so a stock
   regeneration reads as drift rather than as correct.
6. Pin the compat layer's output byte-for-byte against `fb.Builder.addUint64` on
   the VM, so "the daemon cannot tell the difference" is asserted, not assumed.
7. Add a `flutter test --platform chrome` CI step over the transport tests, so
   the regression is visible on the platform that ships it.
8. Exclude `lib/generated/**` from analysis rather than fighting the
   `ignore_for_file` header flatc overwrites on every regeneration.
9. Offer `['triage-flatbuffers', 'triage-json']` at connect, JSON second so a
   daemon that predates the format still negotiates something.
10. Verify negotiation against a live daemon with raw WebSocket upgrades — the
    suite's fakes cannot prove the daemon's half of the handshake.
