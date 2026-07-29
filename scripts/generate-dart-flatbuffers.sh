#!/usr/bin/env bash
#
# Regenerates the Flutter client's FlatBuffers bindings from the shared schema.
#
# Usage: scripts/generate-dart-flatbuffers.sh [--check]
#
#   (no arguments)  Regenerate the bindings in place.
#   --check         Fail if the checked-in bindings are out of date. Used by CI;
#                   never modifies the working tree.
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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ROOT/crates/triage-core/schema/triage.fbs"
OUT_DIR="$ROOT/flutter/triage_client/lib/generated"
GENERATED_FILE="triage_triage.generated_generated.dart"
FLATC_ACTION="$ROOT/.github/actions/setup-flatc/action.yml"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '5,9{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h | --help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

# flatc's output is not byte-stable across releases — even a blank line moving is
# enough to fail --check — so the checked-in bindings are only meaningful against
# one compiler version. Read the pin from the composite action that installs
# flatc in CI, so local and CI runs cannot drift apart. Scoped to the block under
# `inputs.version:` rather than the first `default:` in the file, so adding
# another input above it cannot silently repoint the pin.
EXPECTED_VERSION="$(
  awk '
    /^  version:/ { in_version = 1; next }
    in_version && /^  [a-zA-Z_]+:/ { exit }
    in_version && /^    default:/ { gsub(/[":]/, "", $2); print $2; exit }
  ' "$FLATC_ACTION"
)"
[[ "$EXPECTED_VERSION" =~ $SEMVER_RE ]] ||
  die "could not read the flatc version pin from inputs.version in
       $FLATC_ACTION (got '$EXPECTED_VERSION')"
RELEASE_URL="https://github.com/google/flatbuffers/releases/tag/v$EXPECTED_VERSION"

command -v flatc >/dev/null 2>&1 ||
  die "flatc not found on PATH. Install v$EXPECTED_VERSION from
       $RELEASE_URL"

# `|| true` because a grep that matches nothing exits non-zero, which `set -e`
# would turn into a bare abort — losing the diagnostic below, which exists
# precisely for the case where flatc prints something unparseable.
ACTUAL_VERSION="$(flatc --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[[ -n "$ACTUAL_VERSION" ]] ||
  die "could not parse a version out of 'flatc --version':
       $(flatc --version)"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] ||
  die "flatc $ACTUAL_VERSION found, but the checked-in bindings are generated
       with $EXPECTED_VERSION. Regenerating with a different version produces
       cosmetically different output that fails CI's --check for no real
       reason. Get v$EXPECTED_VERSION from
       $RELEASE_URL"

# flatc emits ByteData.getUint64/setUint64 for every `ulong` field, and dart2js
# implements neither — so on Flutter web, which is what the daemon serves as its
# embedded UI, the binary transport throws on any message carrying one. Route
# those call sites through lib/services/flatbuffers_js_compat.dart instead.
#
# Applied to generated output in both modes, so --check compares patched against
# patched. That is the point: plain `flatc --dart` output no longer looks correct
# to CI, which is exactly how this fix was lost the first time — 949fd6f
# regenerated ad72b56's equivalent patch away, and nothing noticed because the
# client was still pinned to triage-json.
patch_uint64() {
  local dir="$1"
  local file="$dir/$GENERATED_FILE"

  [[ -f "$file" ]] || die "expected $file to exist after generation"

  # If flatc ever stops emitting these call sites, the patch silently becomes a
  # no-op and the web client breaks again — so treat their absence as fatal
  # rather than assuming the problem went away.
  grep -q 'Uint64Reader()' "$file" ||
    die "no uint64 reader call sites found in $file — has flatc's output shape
       changed? Re-check this patch against the generated file rather than
       dropping it; unpatched bindings break the web client silently."
  grep -q '\.addUint64(' "$file" ||
    die "no uint64 writer call sites found in $file — see the note above."

  # Rewrite the call sites first and add the import last, so the import line is
  # never itself a substitution target.
  perl -0pi -e "
    s/const fb\\.Uint64Reader\\(\\)\\.vTableGet\\(/fbjs.readUint64(/g;
    s/fbBuilder\\.addUint64\\(/fbjs.addUint64(fbBuilder, /g;
    s{^(import 'package:flat_buffers/flat_buffers\\.dart' as fb;)\$}
     {\$1\\nimport 'package:triage_client/services/flatbuffers_js_compat.dart'\\n    as fbjs;}m;
  " "$file"

  # Deliberately receiver-agnostic, unlike the substitutions above: anything
  # still reaching a raw uint64 accessor — a differently-named builder, a
  # `[ulong]` list reader, a struct member — has to fail loudly here rather than
  # compile fine and throw only on dart2js, at runtime, in the browser. The
  # second grep drops this patch's own rewritten calls.
  local unpatched
  unpatched="$(
    grep -n 'Uint64Reader\|\.addUint64(\|putUint64(\|writeListUint64(' "$file" |
      grep -v 'fbjs\.addUint64(' || true
  )"
  [[ -z "$unpatched" ]] ||
    die "uint64 call sites survived the dart2js patch in $file:
$unpatched"
  grep -q 'flatbuffers_js_compat\.dart' "$file" ||
    die "the dart2js patch did not add its import to $file"
}

# Always generate into a scratch directory. --check needs it so the working tree
# is never touched, and regeneration needs it so a failing flatc or a failing
# patch leaves the checked-in bindings intact rather than a half-written or
# deleted tree that no longer compiles.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
flatc --dart -o "$SCRATCH" "$SCHEMA"
patch_uint64 "$SCRATCH"

if [[ $CHECK_ONLY -eq 1 ]]; then
  if ! diff -rq "$SCRATCH" "$OUT_DIR" >/dev/null 2>&1; then
    echo "error: Dart FlatBuffers bindings are out of date." >&2
    echo "       Run scripts/generate-dart-flatbuffers.sh and commit the result." >&2
    diff -ru "$OUT_DIR" "$SCRATCH" || true
    exit 1
  fi
  echo "Dart FlatBuffers bindings are up to date."
  exit 0
fi

# Replace the contents wholesale: flatc only writes the files the schema still
# produces, so a removed or renamed type would otherwise leave its stale output
# behind — which --check then reports as drift that regenerating never fixes.
# Everything here is generated, so nothing hand-written is at risk. Copying
# `$SCRATCH/.` into a freshly created directory rather than copying $SCRATCH
# itself keeps the umask default instead of inheriting mktemp's 0700.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$SCRATCH/." "$OUT_DIR"
echo "Regenerated Dart FlatBuffers bindings in $OUT_DIR"
