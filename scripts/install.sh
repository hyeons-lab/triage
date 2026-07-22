#!/usr/bin/env bash
#
# Build and install the triage binaries without ever overwriting a live inode.
#
# Why this script exists
# ----------------------
# The release binaries are adhoc / linker-signed, and macOS caches a binary's
# code directory hash against its *inode*. Writing new bytes into the inode of an
# installed binary — which is exactly what `cp dst` does — leaves that cached
# hash describing content that no longer exists, and the kernel then SIGKILLs
# both the running daemon and every subsequent launch from that path:
#
#   exception:   EXC_CRASH, signal "SIGKILL (Code Signature Invalid)"
#   termination: namespace CODESIGNING, "Launch Constraint Violation"
#
# With the LaunchAgent installed, launchd re-spawns the corpse on a timer, so a
# single bad copy turns into a respawn storm that takes every session with it.
#
# Installing through a temporary file plus rename(2) allocates a *fresh* inode
# and swaps it in atomically, so the signature is evaluated against the bytes
# that are actually there. A running daemon keeps its own (now unlinked) inode
# and is left alone until it is restarted deliberately.
set -euo pipefail

BIN_DIR="${TRIAGE_BIN_DIR:-$HOME/.cargo/bin}"
BINARIES=(triaged triage triage-mcp)

usage() {
    cat <<'EOF'
usage: scripts/install.sh

Build the release binaries and install them into $TRIAGE_BIN_DIR
(default: $HOME/.cargo/bin) without overwriting a live inode.

environment:
  TRIAGE_BIN_DIR   destination directory (default: $HOME/.cargo/bin)
EOF
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

staged=""
# `return 0` is load-bearing: as the last command of an EXIT trap under `set -e`,
# a failing `[[ -n "" ]]` would become the script's exit status and report a
# successful install as a failure.
cleanup() {
    [[ -n "$staged" ]] && rm -f "$staged"
    return 0
}
trap cleanup EXIT

echo "==> Building release binaries"
cargo build --release --locked --manifest-path "$ROOT/Cargo.toml"

mkdir -p "$BIN_DIR"

for binary in "${BINARIES[@]}"; do
    src="$ROOT/target/release/$binary"
    [[ -f "$src" ]] || die "missing build output: $src"

    dst="$BIN_DIR/$binary"
    # The staging file must live in the destination directory: rename(2) is only
    # atomic within a single filesystem, and $BIN_DIR may well be on a different
    # one from the build tree.
    staged="$(mktemp "$dst.XXXXXX")"
    cp "$src" "$staged"
    chmod 755 "$staged"
    # Atomic replace: $dst becomes a brand-new inode, never a rewritten one.
    mv -f "$staged" "$dst"
    staged=""

    echo "==> Installed $dst"
done

# Only triaged parses --version; the client and the MCP server reject unknown
# options, so running them here would fail an otherwise good install. triaged is
# enough to prove the point anyway: a codesigning kill is a property of how the
# file was written, not of which binary it is.
echo
echo "==> Verifying the installed daemon launches"
"$BIN_DIR/triaged" --version \
    || die "$BIN_DIR/triaged failed to run — check 'codesign -v' and Console for a CODESIGNING kill"

echo
echo "The running daemon still holds the previous binary. To adopt this build"
echo "without dropping sessions, hand over explicitly:"
echo "    $BIN_DIR/triaged --handover"
