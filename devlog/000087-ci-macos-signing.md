# 000087 — ci/macos-signing

**Agent:** Claude (claude-opus-4-8) @ triage branch ci/macos-signing

**Intent:** Developer-ID-sign + notarize + staple the macOS client in CI so every
release launches without Gatekeeper quarantine prompts, instead of the current
ad-hoc signing. User has an Apple Developer account and chose the CI-based approach.

## What Changed

- 2026-07-10T10:20-0700 `.github/workflows/publish.yml` — `build-macos` job now
  Developer-ID-signs (hardened runtime + timestamp), notarizes (notarytool), and
  staples the app when signing secrets are configured; falls back to the prior
  ad-hoc strip step when they are not.
- 2026-07-10T10:20-0700 `devlog/plans/000087-01-macos-developer-id-signing.md` —
  plan.

## Decisions

- 2026-07-10 Fallback to ad-hoc when the signing secrets are absent — keeps the
  multi-platform release job working for forks / before secrets are set, rather than
  failing the whole release. A CI warning is emitted so it is not silent.
- 2026-07-17 Gate the signed path on **all six** secrets, not just
  `MACOS_SIGN_IDENTITY` — a partially configured repo (identity set, cert or notary
  key missing) would otherwise enter the signed path and fail mid-job; now it falls
  back to ad-hoc cleanly and the warning names which secrets are missing. (Copilot
  review finding)
- 2026-07-17 Decode base64 secrets with `base64 -D` rather than `--decode` — `-D` is
  the decode flag the macOS/BSD `base64` accepts on every runner image; the GNU-style
  long option is not guaranteed there. (Copilot review finding)
- 2026-07-17 Devlog timestamps use numeric UTC offsets (`-0700`, no colon) per
  `AGENTS.md`. (Copilot review finding)
- 2026-07-10 App Store Connect API key (`--key/--key-id/--issuer`) over Apple ID +
  app-specific password for notarytool — no interactive Apple ID, revocable, standard
  for CI.
- 2026-07-10 Sign inside-out with `find` (loose dylibs/`.so`, then `.framework`
  bundles, then the app), instead of `codesign --deep`. `--deep` does not reliably
  apply `--options runtime` to nested Mach-O, and notarization requires the hardened
  runtime on *every* binary — a nested dylib left ad-hoc / without hardened runtime
  makes Apple reject the submission. (pre-push review finding)
- 2026-07-10 Preserve the runner's existing keychain search list (prepend the temp
  keychain) rather than replacing it, so the Apple intermediate certs needed to build
  the signing chain stay resolvable. (pre-push review finding)

## Next Steps

- User creates the Developer ID Application cert + App Store Connect API key and adds
  the six repo secrets (see PR body / plan).
- Run the Publish workflow (dry_run=false) to cut a signed v0.2.0 release.

## Commits

- 46ce42b — ci(release): Developer ID sign + notarize the macOS client
- HEAD — ci(release): address PR review (all-six-secrets gate, portable base64, timestamps)
