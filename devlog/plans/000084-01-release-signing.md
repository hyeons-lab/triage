# 000084-01 — Release signing (Phase 0b)

## Thinking

Phase 0b of the self-update epic (`devlog/plans/000066-01-self-update.md`) is the
signing prerequisite for any download-install path: until release assets are
signed and checksummed, neither the daemon self-update (Phase 3) nor the Flutter
in-app install (Phase 5) can verify what they download.

State of the world before this PR:

- Phase 0a (#90) already builds + attaches the CLI archives and Flutter clients,
  but emits **no** checksums or signatures.
- Two private keys were sitting **untracked** at the repo root
  (`prism_release_signing` = OpenSSH ed25519, `private-key.asc` = PGP). Never
  committed, but one `git add .` from disaster, and neither is a minisign key —
  they contradict the plan's F7 decision (minisign over GPG/SSH for a trivial
  Dart-side verifier).

Decisions (confirmed with the user):

- **minisign / ed25519**, fresh keypair — per F7. Retire the loose OpenSSH/PGP
  keys rather than adapt to them.
- **Passwordless** secret key. The GitHub secret store is the protection
  boundary; a password would only add an interactive prompt the CI step would
  have to work around. Verified locally that a `-W` key signs non-interactively.
- **Delete** the loose private-key files from the working tree and add
  `.gitignore` rules so key material can never be committed again.
- Generate the keypair + set the `MINISIGN_SECRET_KEY` secret in this session.

Scope boundary: this PR produces and publishes signatures + checksums and pins
the public key in-repo. It deliberately does **not** add client-side
verification — that belongs to the consumers (Phase 3 daemon self-update, Phase 5
Flutter install).

## Plan

1. **Keypair + secret** (one-time, this session): generate a passwordless
   minisign keypair outside any working tree; set `MINISIGN_SECRET_KEY` via
   `gh secret set`. Commit the public half at `.github/minisign.pub`.
2. **`publish.yml`**: in the `release` job, after downloading artifacts, install
   minisign and add a "Sign and checksum release assets" step that, for every
   `Triage-*` archive, writes a `.sha256` (in `sha256sum -c` format) and a
   `.minisig`. Fail closed when `MINISIGN_SECRET_KEY` is absent. The existing
   `files: release-assets/**/Triage-*` glob already attaches the sidecars (they
   share the `Triage-` prefix).
3. **`.gitignore`**: block `*.key`, `*.asc`, `*.pem`, `*_signing`,
   `*_signing.pub`, `*.minisign.key`; allowlist `.github/minisign.pub`.
4. **Remove** the loose `prism_release_signing*` / `private-key.asc` files from
   the working tree (housekeeping in the main checkout; they were never tracked).
5. **`docs/release-signing.md`**: scheme, pinned public key, verification
   commands, key custody, and the rotation policy (single pinned key ⇒ rotation
   is a coordinated client-rollout event, not automatic).
6. **Validate** without burning a real release: YAML parse, shellcheck the
   embedded script, and a local end-to-end drill (sign a fake `release-assets`
   tree, verify each `.minisig` against the committed public key, `sha256sum -c`).
