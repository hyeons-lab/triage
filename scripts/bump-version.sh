#!/usr/bin/env bash
#
# bump-version.sh — single source of truth for the triage version.
#
# The repo version lives in the top-level VERSION file. This script propagates
# it to every place that must agree:
#   - Cargo.toml  [workspace.package].version  (inherited by all crates via
#     version.workspace = true)
#   - Cargo.toml  [workspace.dependencies] internal path-dep pins
#   - Cargo.lock  (refreshed via `cargo update --workspace`)
#   - flutter/triage_client/pubspec.yaml  version: (build name; build number
#     after `+` is preserved)
#
# The release pipeline reads the version from `cargo metadata` (the triaged
# crate), so Cargo stays authoritative for tags/assets; this script just keeps
# VERSION, Cargo, and the Flutter client in lockstep.
#
# Usage:
#   scripts/bump-version.sh <X.Y.Z>   Set a new version, then propagate it.
#   scripts/bump-version.sh           Re-sync all files to the current VERSION.
#   scripts/bump-version.sh --check   Verify every file matches VERSION; exit
#                                     non-zero on drift (no writes). For CI.
#   scripts/bump-version.sh --help    Show this help.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
CARGO_TOML="$ROOT/Cargo.toml"
PUBSPEC="$ROOT/flutter/triage_client/pubspec.yaml"

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "error: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ -f "$VERSION_FILE" ] || die "VERSION file not found at $VERSION_FILE"
[ -f "$CARGO_TOML" ]   || die "Cargo.toml not found at $CARGO_TOML"
[ -f "$PUBSPEC" ]      || die "pubspec.yaml not found at $PUBSPEC"

CHECK_ONLY=0
NEW_VERSION=""
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  "")      ;;
  *)       NEW_VERSION="$1" ;;
esac

current_version() { tr -d '[:space:]' < "$VERSION_FILE"; }

if [ -n "$NEW_VERSION" ]; then
  [[ "$NEW_VERSION" =~ $SEMVER_RE ]] || die "version '$NEW_VERSION' is not MAJOR.MINOR.PATCH"
  VERSION="$NEW_VERSION"
else
  VERSION="$(current_version)"
  [[ "$VERSION" =~ $SEMVER_RE ]] || die "VERSION file holds '$VERSION', not MAJOR.MINOR.PATCH"
fi

# --- read current values from each file (without mutating) -------------------

cargo_pkg_version() {
  perl -0777 -ne 'print "$1" if /\[workspace\.package\].*?^version = "([0-9]+\.[0-9]+\.[0-9]+)"/sm' "$CARGO_TOML"
}
pubspec_build_name() {
  perl -ne 'print "$1" if /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/' "$PUBSPEC"
}
pubspec_build_suffix() {
  # the "+N" after the build name, if any (empty otherwise)
  perl -ne 'print "$1" if /^version:\s*[0-9]+\.[0-9]+\.[0-9]+(\+\S+)?/ && defined $1' "$PUBSPEC"
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  want="$(current_version)"
  [[ "$want" =~ $SEMVER_RE ]] || die "VERSION file holds '$want', not MAJOR.MINOR.PATCH"
  drift=0
  cp="$(cargo_pkg_version)"; pp="$(pubspec_build_name)"
  [ "$cp" = "$want" ] || { echo "drift: Cargo.toml workspace.package version is '$cp', want '$want'" >&2; drift=1; }
  [ "$pp" = "$want" ] || { echo "drift: pubspec.yaml build name is '$pp', want '$want'" >&2; drift=1; }
  if [ "$drift" -eq 0 ]; then echo "OK: all files match VERSION $want"; fi
  exit "$drift"
fi

# --- propagate ---------------------------------------------------------------

printf '%s\n' "$VERSION" > "$VERSION_FILE"

# [workspace.package].version — the lone top-level `version = "..."` line.
perl -i -pe 'BEGIN{$v=shift} s/^version = "[0-9]+\.[0-9]+\.[0-9]+"/version = "$v"/' "$VERSION" "$CARGO_TOML"

# Internal [workspace.dependencies] pins — only path deps under crates/ carry a
# version requirement; match generically so new internal crates are covered.
perl -i -pe 'BEGIN{$v=shift} s/(\{ version = ")[0-9]+\.[0-9]+\.[0-9]+(", path = "crates\/)/${1}$v$2/' "$VERSION" "$CARGO_TOML"

# pubspec.yaml — replace the build name, preserve any "+build" suffix.
suffix="$(pubspec_build_suffix)"
perl -i -pe 'BEGIN{$v=shift; $s=shift} s/^version:\s*[0-9]+\.[0-9]+\.[0-9]+(\+\S+)?/version: $v$s/' "$VERSION" "$suffix" "$PUBSPEC"

# Refresh Cargo.lock so the workspace entries match.
if command -v cargo >/dev/null 2>&1; then
  ( cd "$ROOT" && cargo update --workspace >/dev/null 2>&1 ) \
    && echo "refreshed Cargo.lock via cargo update --workspace" \
    || echo "warning: 'cargo update --workspace' failed; run it manually" >&2
else
  echo "warning: cargo not found; run 'cargo update --workspace' to refresh Cargo.lock" >&2
fi

echo "version set to $VERSION"
echo "  VERSION"
echo "  Cargo.toml        (workspace.package + internal dep pins)"
echo "  pubspec.yaml      ${VERSION}${suffix}"
echo "  Cargo.lock        (workspace entries)"
echo
echo "review the diff, then commit."
