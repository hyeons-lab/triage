# Release signing

Every asset the release workflow attaches to a Triage GitHub release is signed and
checksummed in CI so clients can verify a download before installing it
(self-update, in-app install). Releases through `v0.1.6` predate this and carry no
sidecars. This is the signing infrastructure for the self-update epic
(`devlog/plans/000066-01-self-update.md`, Phase 0b); the clients that *consume*
these signatures land in later phases.

## Scheme

- **Signatures:** [minisign](https://jedisct1.github.io/minisign/) (ed25519).
  Chosen over GPG for a trivial verification story across Rust **and** Dart
  (small, dependency-light verifiers) — see finding F7 in the plan.
- **Checksums:** `sha256` sidecar per asset, in `sha256sum -c` format.

For each release archive `Triage-…`, the `release` job in
`.github/workflows/publish.yml` attaches two sidecar files:

| Sidecar | Produced by | Verify with |
| --- | --- | --- |
| `<asset>.minisig` | `minisign -S` | `minisign -Vm <asset> -P <pinned public key>` |
| `<asset>.sha256` | `sha256sum` | `sha256sum -c <asset>.sha256` |

### Not to be confused with OS code signing

This is Triage's own scheme, and it covers **every** asset of every release the
workflow cuts — the step fails closed if the key is missing (see
[Key custody](#key-custody)).

Separately, the `build-macos` job can sign `Triage.app` with an Apple Developer
ID identity and notarize it. That path is **conditional**: it runs only when all
six `MACOS_*` secrets are configured on the repository, and otherwise falls back
to an ad-hoc signature with a CI warning. It applies to `Triage.app` alone — no
other asset is ever Developer ID signed or notarized, so for the Windows and
Linux clients and the CLI archives, minisign is the only integrity check
available. (Mach-O binaries built on the macOS runners are ad-hoc signed by the
linker, which establishes no identity and is not a substitute.)

## Public key

The release-signing **public** key is committed at
[`.github/minisign.pub`](../.github/minisign.pub) and is the key clients pin:

```
RWRinpvI8phW62LgDacQlEXg1JqBPZxvWKROZWAqmyToxr7Pw0e534yH
```

The user-facing verification steps live in
[Verifying a download](../crates/triaged/README.md#verifying-a-download) — that is
the copy to point downloaders at. A good signature prints `Signature and comment
signature verified` with a trusted comment of the form `triage release vX.Y.Z`.

## Key custody

- The **private** key exists only as the `MINISIGN_SECRET_KEY` GitHub Actions
  secret. It is a passwordless minisign key — the secret store is the protection
  boundary, which keeps the CI signing step non-interactive.
- The private key is **never** committed. `.gitignore` blocks `*.key`, `*.asc`,
  `*.pem`, and `*_signing` so key material cannot be added by accident; the
  public key at `.github/minisign.pub` is explicitly allowlisted.
- The signing step **fails closed**: if `MINISIGN_SECRET_KEY` is absent, the
  release job errors out instead of publishing unsigned binaries.

## Rotation

The public key is pinned by released clients, so rotation is a coordinated,
deliberate event — not routine:

1. Generate a new passwordless keypair: `minisign -G -W -p minisign.pub -s minisign.key`.
2. Update the `MINISIGN_SECRET_KEY` secret: `gh secret set MINISIGN_SECRET_KEY < minisign.key`.
3. Commit the new `.github/minisign.pub` and ship a client release that pins it
   **before** the first release signed by the new key, so clients can still
   verify in the interim.
4. Treat a suspected private-key compromise as urgent: rotate immediately and
   re-sign (or yank) any releases produced with the old key.

> **The key literal is quoted outside `.github/minisign.pub`** — in
> [Public key](#public-key) above, and in **Verifying a download** in
> `crates/triaged/README.md`. Update both in the same commit as step 3; a stale
> copy sends users to verify against a retired key. The trusted-comment format is
> duplicated the same way — `publish.yml`'s signing step sets it, and this doc and
> that README both quote it as `triage release vX.Y.Z`. (The success string
> `Signature and comment signature verified` comes from minisign itself, so it
> changes only if minisign does. Devlogs quote the key too; they are an
> append-only record and are left alone.)

There is intentionally no automatic rotation — minisign supports only a single
pinned key per verification, so overlap has to be managed by client rollout.
