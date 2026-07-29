#!/usr/bin/env bash
#
# Regenerates the Flutter client's FlatBuffers bindings from the shared schema.
#
# The Rust bindings are generated automatically by triage-core's build.rs, but
# the Dart ones are checked in and have no such trigger. That asymmetry is how
# they went stale: `list_session_contexts` was added to the schema and the Rust
# side picked it up for free, while the Dart bindings kept a pre-request copy.
# Nothing failed at the time only because the client offered `triage-json`
# exclusively, so the binary path was never taken; the breakage was latent and
# would have surfaced the moment FlatBuffers became the negotiated default.
#
# Run this after any change to crates/triage-core/schema/triage.fbs, and commit
# the result alongside the schema change.
#
# Usage:
#   scripts/generate-dart-flatbuffers.sh          # regenerate in place
#   scripts/generate-dart-flatbuffers.sh --check  # fail if out of date (CI)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_root/crates/triage-core/schema/triage.fbs"
out_dir="$repo_root/flutter/triage_client/lib/generated"

# flatc's output is not byte-stable across releases — even a blank line moving is
# enough to fail --check — so the checked-in bindings are only meaningful against
# one compiler version. Must match the default in
# .github/actions/setup-flatc/action.yml.
expected_version="25.2.10"

if ! command -v flatc >/dev/null 2>&1; then
  echo "error: flatc not found on PATH." >&2
  echo "       Install v$expected_version from" >&2
  echo "       https://github.com/google/flatbuffers/releases/tag/v$expected_version" >&2
  exit 1
fi

actual_version="$(flatc --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "error: flatc $actual_version found, but the checked-in bindings are" >&2
  echo "       generated with $expected_version. Regenerating with a different" >&2
  echo "       version produces cosmetically different output that fails CI's" >&2
  echo "       --check for no real reason." >&2
  echo "       Get v$expected_version from" >&2
  echo "       https://github.com/google/flatbuffers/releases/tag/v$expected_version" >&2
  exit 1
fi

check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
elif [[ $# -gt 0 ]]; then
  echo "error: unrecognized argument '$1' (expected --check or nothing)" >&2
  exit 1
fi

if [[ $check_only -eq 1 ]]; then
  # Generate into a scratch dir and diff, so --check never mutates the tree.
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  flatc --dart -o "$scratch" "$schema"
  if ! diff -rq "$scratch" "$out_dir" >/dev/null 2>&1; then
    echo "error: Dart FlatBuffers bindings are out of date." >&2
    echo "       Run scripts/generate-dart-flatbuffers.sh and commit the result." >&2
    diff -ru "$out_dir" "$scratch" || true
    exit 1
  fi
  echo "Dart FlatBuffers bindings are up to date."
  exit 0
fi

# Regenerate into a clean directory: flatc only writes the files the schema
# still produces, so a removed or renamed type would otherwise leave its stale
# output behind — which --check then reports as drift that regenerating never
# fixes. Everything here is generated, so nothing hand-written is at risk.
rm -rf "$out_dir"
mkdir -p "$out_dir"
flatc --dart -o "$out_dir" "$schema"
echo "Regenerated Dart FlatBuffers bindings in $out_dir"
