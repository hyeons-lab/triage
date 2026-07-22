# 000099 — docs/signing-and-verification

**Agent:** Claude Code (claude-opus-4-8[1m]) @ triage branch docs/signing-and-verification

## Intent

Audit the docs against `main` (39 commits past `v0.1.6`) and fix what has drifted.
Three findings: signing status described unconditionally, `docs/release-signing.md`
orphaned with a nonexistent version in its example, and `AGENTS.md` documenting a
push form that can land on `main`.

## What Changed

- 2026-07-21T21:47-0700 `AGENTS.md` — replaced the bare `git push -u origin <branch>`
  guidance with the explicit `HEAD:refs/heads/<type>/<branch-name>` refspec, plus the
  reason the source-only form is unsafe and a verification step for `--unset-upstream`.
- 2026-07-21T21:50-0700 `crates/triaged/README.md` — rewrote the "release binaries are
  unsigned" callout to state the per-platform truth (macOS ad-hoc, Windows/Linux
  unsigned, only macOS and Windows warn), leaving the Developer ID condition itself to
  `docs/release-signing.md` behind a one-line pointer. Added a top-level **Verifying a
  download** section covering the sidecars and the pinned public key, linked from both
  **Installation** and the desktop-client section, and using absolute GitHub URLs for
  out-of-crate targets.
- 2026-07-21T21:50-0700 `flutter/triage_client/README.md` — took the per-platform wording
  (macOS ad-hoc, Windows/Linux unsigned, only the first two warn), scoped the signing
  claim to releases after `v0.1.6`, and pointed at **Verifying a download** in the
  `triaged` README rather than at the maintainer-facing signing doc.
- 2026-07-21T21:50-0700 `README.md` — reworked the install paragraph: desktop builds ship
  on every release, while the CLI archives and per-asset signature/checksum start after
  `v0.1.6`; "no release build carries an OS code-signing certificate, so macOS and Windows
  warn once"; and both links now target the sections that answer them
  (**Verifying a download**, **Prebuilt desktop clients**) rather than the file generally.
- 2026-07-21T21:50-0700 `docs/release-signing.md` — replaced the worked example (which
  used a `v0.1.7` that was never released) with a pointer to the `triaged` README's
  **Verifying a download**, so the recipe has one home; added a section separating
  minisign (every asset of every release the workflow cuts, fails closed) from macOS
  Developer ID notarization (conditional, `Triage.app` only); corrected the opening
  sentence, which claimed every release is signed; and added a rotation note naming the
  remaining duplicated facts.

## Decisions

- 2026-07-21T21:49-0700 Reordered the macOS steps to "try `open` first, clear quarantine
  if blocked" rather than leading with `xattr`. The original draft told the reader a
  notarized build skips the quarantine step, which is unactionable — a reader cannot tell
  which build they hold. Attempting to open first makes the app itself answer that, and
  the instruction stays correct whether or not notarization is enabled.
- 2026-07-21T21:51-0700 Put the user-facing verification steps in
  `crates/triaged/README.md` and linked `docs/release-signing.md` for the scheme, rather
  than only linking out. A reader who has just downloaded an asset should not have to
  follow a link to learn there is anything to verify — the orphaning was the problem.
- 2026-07-21T21:55-0700 Document the signing condition in exactly one place, and have the
  user-facing docs state only what ships. `gh secret list` shows only
  `CARGO_REGISTRY_TOKEN`, `JUNIE_API_KEY`, and `MINISIGN_SECRET_KEY`;
  `publish.yml:208-223` requires all six `MACOS_*` secrets and warns-and-falls-back to
  the ad-hoc re-sign otherwise, so #104's notarization path has never actually run.
  Rewriting the docs as "signed and notarized" would have been wrong today. The first
  attempt put the condition in all four docs, which read as hedging and gave the same
  fact four independently-driftable copies; `docs/release-signing.md` now owns it, the
  `triaged` README carries a one-line pointer, and the root and Flutter READMEs state the
  present fact. The tradeoff is that those two go stale when the secrets land — see
  Next Steps for exactly what to change then.

## Issues

- 2026-07-21T21:45-0700 First worktree was created as
  `docs/docs-signing-and-verification` — the type prefix was duplicated in the branch
  name. Removed and recreated as `docs/signing-and-verification`.
- 2026-07-21T21:46-0700 The signing finding inverted on inspection. The initial audit
  read #104 (Developer ID sign + notarize, 2026-07-18) as live because it postdates the
  `v0.1.6` tag (2026-06-16), and concluded three docs were stale. Checking
  `gh secret list` before editing showed the required secrets are absent, so the "stale"
  wording was in fact accurate for what ships. Confirmed against the workflow's gate
  rather than assuming a merged CI change is an active one.
- 2026-07-21T21:58-0700 The first draft of the conditional was itself wrong, and all four
  review-loop reviewers caught it independently: it read "the builds carry no OS
  code-signing certificate unless the signing secrets are configured", which applies a
  macOS-only gate to all three desktop platforms. `build-windows` and `build-linux` have
  no signing step at all, so their warnings persist no matter what is configured. Fixed
  by scoping the condition to `Triage.app` everywhere it appears. The lesson generalizes:
  when replacing an over-broad claim with a conditional, the *scope* of the condition
  needs the same scrutiny as its truth value.
- 2026-07-21T21:58-0700 The `triaged` README's new links used `../../` to reach
  `.github/minisign.pub` and `docs/release-signing.md`. That crate sets
  `readme = "README.md"` with a crate-scoped `include`, so it renders on crates.io and
  docs.rs where out-of-crate relative links 404. Switched to absolute
  `github.com/hyeons-lab/triage/blob/main/...` URLs. The intra-repo relative links in the
  root and Flutter READMEs are fine — neither is a published crate readme.
- 2026-07-21T21:58-0700 Four timestamps in this devlog's first draft were ahead of the
  wall clock — fabricated rather than read from `date`, which AGENTS.md explicitly
  forbids. Corrected against the files' mtimes.
- 2026-07-21T22:05-0700 Fell into the *same* trap a third time, and a second review round
  caught it: the docs asserted that every GitHub release ships `.minisig`/`.sha256`
  sidecars. `gh release view v0.1.6 --json assets` returns exactly three archives — no
  sidecars, and no `Triage-cli-*` either, because both #96 (minisign) and #90 (prebuilt
  CLI binaries) postdate the `v0.1.6` tag. A merged workflow change is not a shipped
  artifact, which is the identical error the notarization finding turned on. The
  verification docs now say sidecars start after `v0.1.6` rather than claiming every
  release has them.
- 2026-07-21T22:05-0700 The root README kept an over-broad "each OS warns once" after the
  sibling docs were corrected to "macOS and Windows" — Linux has no Gatekeeper/SmartScreen
  equivalent and warns for nothing. Scope fixes have to be applied to every copy in the
  same pass; fixing the two files under review while leaving the entry-point doc wrong is
  worse than not having split the claim at all.
- 2026-07-21T22:05-0700 Introduced a `vX.Y.Z` placeholder into `crates/triaged/README.md`
  while the surrounding file uses `v<version>` in five places. Standardized on
  `v<version>` for asset names, per the plan; `vX.Y.Z` now appears only where it is the
  literal trusted-comment format minisign emits.
- 2026-07-21T22:13-0700 A third round found the `v0.1.6` caveat had been added to some
  docs and not others, so the four files disagreed about when sidecars start — the same
  scope-consistency failure as the previous round, one level up. Rather than add a fourth
  copy, the full caveat now lives in **Verifying a download**; the root and Flutter
  READMEs carry only the three-word scope ("releases after `v0.1.6`") and link there for
  the rest. A fourth round showed that dropping the qualifier from the satellites entirely
  was too far the other way — it left the entry-point docs flatly asserting sidecars that
  no downloadable release has. The rule that came out of it: state the scope wherever the
  claim appears, but explain it in exactly one place.
- 2026-07-21T22:13-0700 `crates/triaged/README.md`'s Installation section claimed "every
  GitHub release attaches a `Triage-cli-*` archive" — false for the same reason (#90
  postdates `v0.1.6`) and directly contradicted the root README. Pre-existing text, but in
  a paragraph this branch already touched, so it was corrected here rather than left to
  contradict the new wording. A first pass only deleted the word "every", which left the
  claim just as unconditional; a fourth review round caught that, and it now reads
  "releases after `v0.1.6` attach…". Softening a quantifier is not the same as scoping a
  claim.

## Research & Discoveries

- `publish.yml:631` signs every `Triage-*` asset — desktop clients *and* CLI archives —
  with trusted comment `triage release v$VERSION`, and skips existing sidecars. The
  minisign story therefore covers Windows/Linux clients, which have no OS-level
  signature at all and for which it is the only integrity check.
- The relevant workflow job is `build-macos`; there is no `macos-client` job.
- Four releases exist — `v0.1.3` through `v0.1.6` — and each carries exactly three assets,
  `Triage-{linux,macos,windows}-<tag>.*`. None has sidecars or CLI archives, since #96 and
  #90 both postdate `v0.1.6`. That is why the docs say "releases through `v0.1.6`" rather
  than naming a single release. Any doc sentence of the form "every release has X" needs
  checking against `gh release view`, not against the workflow that produces X.
- `crates/triaged/Cargo.toml` sets `readme = "README.md"` with a crate-scoped `include`,
  so that README renders on crates.io and docs.rs. Relative links escaping `crates/triaged/`
  404 there; use absolute GitHub URLs in that file specifically.
- CI (`ci.yml`) has no markdown/link gate. `scripts/bump-version.sh --check` is the only
  push gate a docs-only diff can trip; it passes (`OK: all files match VERSION 0.2.0`).

## Commits

- HEAD — docs: scope the release signing claims and surface download verification

## Next Steps

- When the six `MACOS_*` secrets are added and a release is cut with them, three places
  need updating in the same pass: the "no OS code-signing certificate" callout in
  `crates/triaged/README.md` (flip it to lead with the notarized path, leaving the
  quarantine steps as the fallback they already are), and the same claim in `README.md`
  and `flutter/triage_client/README.md`. `docs/release-signing.md` already describes the
  condition and needs no change.
- Once a release ships with sidecars and CLI archives, drop the `v0.1.6` scope from every
  place it appears — `README.md`, `flutter/triage_client/README.md`,
  `crates/triaged/README.md` (**Installation**, the desktop-client callout, and
  **Verifying a download**), and `docs/release-signing.md`'s opening. They exist only because no released artifact has
  either yet; leaving some behind re-creates the disagreement rounds three and four were
  spent removing.
- Repo version is `0.2.0` with no `v0.2.0` tag and nothing past `0.1.6` on crates.io —
  unrelated to this branch, but the release is outstanding.
