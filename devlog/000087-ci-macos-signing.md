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

- 2026-07-10T10:20-0700 Fallback to ad-hoc when the signing secrets are absent — keeps the
  multi-platform release job working for forks / before secrets are set, rather than
  failing the whole release. A CI warning is emitted so it is not silent.
- 2026-07-17T19:05-0700 Gate the signed path on **all six** secrets, not just
  `MACOS_SIGN_IDENTITY` — a partially configured repo (identity set, cert or notary
  key missing) would otherwise enter the signed path and fail mid-job; now it falls
  back to ad-hoc cleanly and the warning names which secrets are missing. (Copilot
  review finding)
- 2026-07-17T19:05-0700 Decode base64 secrets with `base64 -D` rather than `--decode` — `-D` is
  the decode flag the macOS/BSD `base64` accepts on every runner image; the GNU-style
  long option is not guaranteed there. (Copilot review finding)
- 2026-07-17T19:05-0700 Devlog timestamps use numeric UTC offsets (`-0700`, no colon) per
  `AGENTS.md`. (Copilot review finding)
- 2026-07-10T10:20-0700 App Store Connect API key (`--key/--key-id/--issuer`) over Apple ID +
  app-specific password for notarytool — no interactive Apple ID, revocable, standard
  for CI.
- 2026-07-10T10:20-0700 Sign inside-out with `find` (loose dylibs/`.so`, then `.framework`
  bundles, then the app), instead of `codesign --deep`. `--deep` does not reliably
  apply `--options runtime` to nested Mach-O, and notarization requires the hardened
  runtime on *every* binary — a nested dylib left ad-hoc / without hardened runtime
  makes Apple reject the submission. (pre-push review finding)
- 2026-07-10T10:20-0700 Preserve the runner's existing keychain search list (prepend the temp
  keychain) rather than replacing it, so the Apple intermediate certs needed to build
  the signing chain stay resolvable. (pre-push review finding)
- 2026-07-17T19:54-0700 Generalize the signing traversal — sign every Mach-O in the
  bundle inside-out (deepest first), discovering code by content (`file`) rather than
  a `Contents/Frameworks` + extension whitelist, then every nested *code* bundle, then
  the app. A future plugin shipping a helper tool / `.xpc` / `.bundle` / nested
  framework / extension-less binary is now covered instead of failing notarization.
  (review-fix-loop finding)
- 2026-07-17T19:54-0700 Pass 2 only signs bundles that contain a Mach-O — `codesign`
  refuses a resource-only bundle (e.g. `Assets.bundle`) with "bundle format
  unrecognized", which would abort the job; resource bundles are sealed as resources
  of their parent regardless. (review-fix-loop finding — regression caught in the
  traversal rewrite)
- 2026-07-17T19:54-0700 Notarization asserts `status == Accepted` from the JSON
  output and dumps `notarytool log` on any other status, because `notarytool submit
  --wait` does not reliably exit non-zero on an Invalid submission (would otherwise
  fall through to `stapler` with an opaque "no ticket" error). (review-fix-loop
  finding)
- 2026-07-17T19:54-0700 Remove decoded secret temp files (`.p12`/`.p8`) via
  `trap … EXIT` so a mid-step failure can't strand a private key on the runner —
  matching the existing trap pattern in the release job. (review-fix-loop finding)
- 2026-07-17T19:54-0700 `get-task-allow` guard fails closed if entitlements can't be
  read (captures `codesign -d` exit) instead of silently passing an uninspected app.
  (review-fix-loop finding)

## Next Steps

- User creates the Developer ID Application cert + App Store Connect API key and adds
  the six repo secrets (see PR body / plan).
- Run the Publish workflow (dry_run=false) to cut a signed v0.2.0 release.

## Commits

- 46ce42b — ci(release): Developer ID sign + notarize the macOS client
- 14c9323 — ci(release): address PR review on macOS signing
- 0a23b00 — ci(release): harden macOS signing (traversal, notary status, secret cleanup)
- HEAD — ci(release): reword secret-cleanup comments and full-timestamp devlog decisions
