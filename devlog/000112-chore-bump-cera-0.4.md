# 000112 chore/bump-cera-0.4

**Agent:** Claude (claude-opus-5[1m]) @ triage branch chore/bump-cera-0.4

## Intent

Move the workspace off `cera` 0.3.1 onto 0.4.0, the newest published release of
the local inference engine that backs the session summarizer.

## What Changed

2026-08-01T09:30-0700 `Cargo.toml` — workspace dep `cera` 0.3.1 to 0.4.0. The
`remote` feature selection is unchanged.

2026-08-01T09:31-0700 `Cargo.lock` — regenerated with `cargo update -p cera
--precise 0.4.0`. Only the `cera` entry moved; the other 127 dependencies are
untouched, so this carries no transitive churn.

No source changes. `crates/triaged/src/summarizer.rs` is the only consumer, and
every item it names (`CeraEngine`, `EngineConfig`, `BackendPreference`,
`SessionConfig`, `GenerateOpts`, `manifest::GenerationDefaults`,
`session::{FinishReason, ModalitySink, CeraError}`, `tokenizer::{BpeTokenizer,
ChatMessage, apply_chat_template}`, `bundle::BundleRepo`) still resolves.

## Decisions

2026-08-01T09:31-0700 Took 0.4.0 rather than a `^0.3` float — reasoning: `cera`
is pre-1.0, so 0.3 to 0.4 is a semver-breaking bump that cargo will never pick
up on its own. Pinning the new minor is the only way to actually move.

2026-08-01T09:32-0700 Left `rust-toolchain.toml` on `nightly-2026-07-10` —
reasoning: the pin exists because `cera`'s aarch64 NEON backend calls
still-unstable intrinsics, and nothing observed here says 0.4.0 dropped that
requirement. 0.4.0 does declare `rust-version = 1.94`, which is below the
1.99-nightly floor the pin documents, but an MSRV field describes the stable
floor and says nothing about feature gates. Verifying that 0.4.0 builds on
stable is a separate question from this bump, and lowering the pin on the
strength of a metadata field alone would risk the exact aarch64 build break the
existing comment warns about.

2026-08-01T09:32-0700 Did not touch the feature list — reasoning: 0.3.1 and
0.4.0 declare byte-identical feature graphs (checked against the crates.io API,
including `default = [parallel, mmap, std-fs, disk-cache, vl-preprocess,
avx512]`), so there is no new opt-in to consider and no default that silently
changed shape.

## Issues

2026-08-01T09:28-0700 A first `cargo check` failed in `crates/triaged/build.rs`,
not in any Rust code: the build script wants a Flutter web bundle and panics
when `flutter` is absent from PATH. Unrelated to the bump. Re-ran the gates with
`TRIAGE_SKIP_FLUTTER_BUILD=1`, which embeds the `web_fallback/` placeholder; the
daemon's Rust surface is what is under test here.

## Verification

Full CI gate set, run locally, all green:

- `cargo fmt --all --check` — clean
- `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` — clean
- `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps --locked` — clean
- `cargo test --workspace --all-features --locked` — 313 passed, 0 failed, 1 ignored

**Not covered by the above:** the summarizer is not exercised end to end by the
test suite. Compiling against 0.4.0 proves the API still fits; it does not prove
that model loading, the LFM2.5 bundle resolution, or generation quality behave
the same at runtime. A daemon that loads a session and produces a snippet is the
real check, and that wants doing before this is trusted in a release.

## Next Steps

- Run a real summarizer pass against 0.4.0 before publishing.
- Re-test whether the nightly pin is still required, as its own change.

## Commits

- HEAD — chore(deps): bump cera to 0.4.0
