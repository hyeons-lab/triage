# 000083 — Release signing (Phase 0b)

**Agent:** Claude (claude-opus-4-8) @ triage branch ci/release-signing

## Intent

Self-update epic, Phase 0b: sign and checksum every release asset so the daemon
self-update (Phase 3) and Flutter in-app install (Phase 5) can verify downloads
before installing them. Prerequisite for any download-install path. Also clean up
the loose private-key files sitting in the repo root.

## What Changed

- 2026-06-21T14:56-0300 `.github/workflows/publish.yml` — added a "Sign and
  checksum release assets" step to the `release` job (installs minisign, then for
  each `Triage-*` archive writes a `.sha256` in `sha256sum -c` format and a
  `.minisig`). Fails closed if `MINISIGN_SECRET_KEY` is unset. The existing
  `files: release-assets/**/Triage-*` glob attaches the sidecars unchanged (they
  share the `Triage-` prefix); added a comment noting that.
- 2026-06-21T14:56-0300 `.github/minisign.pub` — committed the release-signing
  **public** key (ed25519, `RWRinpvI8phW62LgDacQlEXg1JqBPZxvWKROZWAqmyToxr7Pw0e534yH`).
  This is the key clients pin.
- 2026-06-21T14:56-0300 `.gitignore` — block `*.key`, `*.asc`, `*.pem`,
  `*_signing`, `*_signing.pub`, `*.minisign.key`; allowlist `.github/minisign.pub`.
- 2026-06-21T14:56-0300 `docs/release-signing.md` — new: scheme, pinned public
  key, verification commands, key custody, rotation policy.
- 2026-06-21T14:56-0300 Removed the untracked `prism_release_signing`,
  `prism_release_signing.pub`, and `private-key.asc` from the main checkout's
  working tree (never committed; housekeeping, not part of the diff).

## Decisions

- 2026-06-21T14:56-0300 **minisign / ed25519, fresh keypair** (plan F7). The loose
  keys at the repo root were OpenSSH ed25519 + PGP — neither is a minisign key and
  both contradict F7's "trivial Dart-side verifier" rationale, so they are retired
  rather than adapted.
- 2026-06-21T14:56-0300 **Passwordless secret key.** The GitHub secret store is
  the protection boundary; a password would only force the CI step to script
  around an interactive prompt. Confirmed locally that a `-W` key signs
  non-interactively (`minisign -S … < /dev/null`).
- 2026-06-21T14:56-0300 **Fail closed.** No `MINISIGN_SECRET_KEY` ⇒ the release
  job errors out rather than publishing unsigned binaries.
- 2026-06-21T14:56-0300 **Sign centrally in the `release` job**, not per build
  job. One step has all assets in `release-assets/` already, so it needs the
  secret in exactly one place (least exposure) and signs everything uniformly.
- 2026-06-21T14:56-0300 **Scope:** produce + publish signatures and pin the public
  key only. Client-side verification belongs to the consumers (Phase 3 self-update,
  Phase 5 Flutter install) and is out of scope here.

## Issues

- 2026-06-21T14:56-0300 The CI signing path only exercises on a real release
  (`workflow_dispatch`, `dry_run=false`), which is expensive to trigger. Mitigated
  with a local end-to-end drill: signed a fake `release-assets/<artifact>/Triage-*`
  tree with the real key, verified every `.minisig` against the **committed**
  `.github/minisign.pub` (`Signature and comment signature verified`), and ran
  `sha256sum -c` — all green. This also proves the committed public key and the
  uploaded secret are a matching pair. Plus: YAML parses, shellcheck clean.

## Plan

See `devlog/plans/000083-01-release-signing.md`.

## Next Steps

- PR 4 (rest): Phase 3 health-gated handover self-update — the daemon download
  path verifies these `.minisig`/`.sha256` sidecars (checksum now, signature via
  this key).
- PR 5: Flutter banner + browser-download; in-app install (gated on notarization)
  verifies against the pinned `.github/minisign.pub`.

## Commits

- HEAD — ci(release): sign and checksum release assets with minisign
