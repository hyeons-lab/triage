# Release signing

Every binary attached to a Triage GitHub release is signed and checksummed in CI
so clients can verify a download before installing it (self-update, in-app
install). This is the signing infrastructure for the self-update epic
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

## Public key

The release-signing **public** key is committed at
[`.github/minisign.pub`](../.github/minisign.pub) and is the key clients pin:

```
RWRinpvI8phW62LgDacQlEXg1JqBPZxvWKROZWAqmyToxr7Pw0e534yH
```

### Verifying a downloaded asset

```sh
# 1. Fetch the asset and its .minisig from the GitHub release.
# 2. Verify the signature against the pinned public key:
minisign -Vm Triage-cli-linux-v0.1.7.tar.gz -P RWRinpvI8phW62LgDacQlEXg1JqBPZxvWKROZWAqmyToxr7Pw0e534yH

# Optionally also check the sha256 sidecar:
sha256sum -c Triage-cli-linux-v0.1.7.tar.gz.sha256
```

A good signature prints `Signature and comment signature verified` and a trusted
comment of the form `triage release vX.Y.Z`.

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

There is intentionally no automatic rotation — minisign supports only a single
pinned key per verification, so overlap has to be managed by client rollout.
