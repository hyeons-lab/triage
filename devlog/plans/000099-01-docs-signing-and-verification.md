# Plan — docs: signing status, download verification, push guidance

## Thinking

A docs audit against `main` (39 commits past `v0.1.6`) turned up three gaps. The
docs are otherwise current — README, AGENTS.md, and the per-crate READMEs already
cover Windows daemon support, `triaged service install`, multi-daemon switching,
remote access, and update checks.

**1. Signing status is described unconditionally, and the condition matters.**
Two CI changes landed after the `v0.1.6` tag (2026-06-16):

- `#96` (2026-06-21) — minisign signatures + sha256 sidecars on every release asset.
- `#104` (2026-07-18) — Developer ID signing + notarization for the macOS client.

Three docs still say the builds are flatly "unsigned":
`README.md:17`, `crates/triaged/README.md:125-140`, `flutter/triage_client/README.md:21`.

The first instinct — rewrite them as "signed and notarized" — is wrong.
`gh secret list` shows only `CARGO_REGISTRY_TOKEN`, `JUNIE_API_KEY`, and
`MINISIGN_SECRET_KEY`; none of the six `MACOS_*` secrets exist. `publish.yml:208-223`
gates notarization on all six being present and warns-and-falls-back to the prior
ad-hoc re-sign otherwise, so the next release's `Triage.app` will still be ad-hoc
signed and un-notarized. The current wording is accurate *today* and would become
wrong the moment the secrets are added.

So the fix is to state the condition rather than pick a side: the unquarantine
steps stay as the documented path for the builds that actually ship, with the
signed/notarized path described as what configuring the secrets turns on. That
reads correctly before and after the secrets land, and it tells a reader why
their download's behavior might differ from the docs.

Minisign is unconditional and already live — `MINISIGN_SECRET_KEY` is set and the
step fails closed — so sidecar verification can be stated flatly.

**2. `docs/release-signing.md` is orphaned.** Nothing in `README.md`,
`crates/triaged/README.md`, or the client README links to it. A user downloading
a release has no documented path to the `.minisig`/`.sha256` sidecars that `#96`
now attaches — the verification story exists but is unreachable, which is close
to not having it. Its worked example also uses `Triage-cli-linux-v0.1.7.tar.gz`;
`v0.1.7` was never released (latest tag is `v0.1.6`, `VERSION` is `0.2.0`). The
rest of the docs use a `v<version>` placeholder — match that instead of naming a
version that may or may not ever exist.

**3. `AGENTS.md:58` documents a push that can land on `main`.** It says the
upstream "is set on the first `git push -u origin <type>/<branch-name>`". That
refspec is source-only, so with `push.default = upstream`/`tracking` git resolves
the *destination* from the branch's upstream. Worktree branches created per the
documented `git worktree add ... origin/main` recipe track `origin/main` until
`--unset-upstream` runs, and if that step is skipped or silently fails, the push
targets `main` and bypasses the PR. The explicit `HEAD:refs/heads/<branch>` form
names its destination and is immune. This is the one finding that is a live
hazard rather than a staleness issue.

## Plan

1. `AGENTS.md` — replace the bare `git push -u origin <branch>` guidance with the
   explicit `git push -u origin HEAD:refs/heads/<type>/<branch-name>` form, and
   say why the source-only refspec is unsafe here.
2. `crates/triaged/README.md` — rewrite the "release binaries are unsigned"
   callout to describe the actual conditional (ad-hoc today; Developer ID +
   notarized when the release signing secrets are configured), keep the
   per-platform unquarantine steps, and add a short "Verifying a download"
   subsection pointing at `docs/release-signing.md`.
3. `flutter/triage_client/README.md` — match the same conditional wording; keep
   the pointer to the `triaged` per-platform steps.
4. `README.md` — mention the `.minisig`/`.sha256` sidecars, link
   `docs/release-signing.md`, and soften "unsigned" to the conditional.
5. `docs/release-signing.md` — swap the `v0.1.7` example for the `v<version>`
   placeholder, and add a short note distinguishing minisign (always on, all
   assets) from macOS Developer ID/notarization (conditional, macOS client only)
   so the two signing mechanisms aren't conflated.
6. Verify: no `cargo`/Flutter surface changes, so the gates are the doc-link and
   prose checks — confirm every relative link and anchor resolves, and confirm no
   remaining doc asserts an unconditional signing state.
