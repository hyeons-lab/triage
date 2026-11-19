#!/usr/bin/env bash
# Installer verification using a fake HOME. Never touches the real home.
set -euo pipefail

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/triage-verify-XXXXXX")"
cleanup() {
  local exit_code=$?
  if [ "${exit_code}" -ne 0 ] || [ "${fail:-0}" -gt 0 ]; then
    echo "Verification failed (exit code ${exit_code}, ${fail} failure(s)). Retaining diagnostic logs in: ${LOG_DIR}"
  else
    rm -rf "${TEST_DIR}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
FAKE="${TEST_DIR}/home"
LOG_DIR="${TEST_DIR}/logs"
mkdir -p "${FAKE}" "${LOG_DIR}"

export HOME="${FAKE}"
export XDG_CONFIG_HOME="${FAKE}/.config"
SKILL="triage-coordination"
SKILLS="triage-coordination agent-teamwork"

pass=0; fail=0
check() { # check <desc> <command...>
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    echo "PASS: ${desc}"
    pass=$((pass+1))
  else
    echo "FAIL: ${desc}"
    if [ -n "${out}" ]; then
      printf '%s\n' "${out}" | sed 's/^/  /' >&2
    fi
    fail=$((fail+1))
  fi
}
run_install() { # run_install <logfile> [args...]
  local log="$1"; shift
  if ! "${BUNDLE}/install.sh" "$@" > "${log}" 2>&1; then
    cat "${log}" >&2
    return 1
  fi
}
is_missing() { # is_missing <path>
  [ ! -e "$1" ] && [ ! -L "$1" ]
}
dest_for() { # dest_for <target> [skill]
  case "$1" in
    agents) printf '%s/.agents/skills/%s\n' "${FAKE}" "${2:-${SKILL}}" ;;
    muse) printf '%s/.config/muse/skills/%s\n' "${FAKE}" "${2:-${SKILL}}" ;;
    claude) printf '%s/.claude/skills/%s\n' "${FAKE}" "${2:-${SKILL}}" ;;
    codex) printf '%s/.codex/skills/%s\n' "${FAKE}" "${2:-${SKILL}}" ;;
    antigravity) printf '%s/.gemini/config/skills/%s\n' "${FAKE}" "${2:-${SKILL}}" ;;
  esac
}
skill_intact() { # skill_intact <dest> [skill]
  local dest="$1" skill="${2:-${SKILL}}" file files
  case "$skill" in
    triage-coordination) files="SKILL.md agents/openai.yaml" ;;
    agent-teamwork) files="SKILL.md agents/openai.yaml references/native-workers.md references/triage-workers.md" ;;
    *) return 1 ;;
  esac
  [ -f "$dest/SKILL.md" ] && grep -qxF "name: ${skill}" "$dest/SKILL.md" || return 1
  for file in $files; do
    cmp -s "${BUNDLE}/skills/${skill}/$file" "$dest/$file" || return 1
  done
}

# 1. Plain install reaches every target with intact files.
run_install "${LOG_DIR}/install.log"
for target in agents muse claude codex antigravity; do
  for skill in $SKILLS; do
    check "plain install populates ${target}/${skill}" skill_intact "$(dest_for "${target}" "$skill")" "$skill"
  done
done

# 2. Re-running is idempotent.
run_install "${LOG_DIR}/idempotent.log"
check "second run reports unchanged" grep -q "unchanged:" "${LOG_DIR}/idempotent.log"
check "all 30 bundled files unchanged" test "$(grep -c 'unchanged:' "${LOG_DIR}/idempotent.log")" -eq 30
rm "$(dest_for agents agent-teamwork)/references/triage-workers.md"
run_install "${LOG_DIR}/repair-reference.log" --agents
check "reinstall restores a missing worker reference" skill_intact "$(dest_for agents agent-teamwork)" agent-teamwork

# 3. Link mode symlinks non-canonical targets at the canonical copy.
rm -rf "${FAKE}"
mkdir -p "${FAKE}"
run_install "${LOG_DIR}/link.log" --link
for skill in $SKILLS; do
  check "link mode installs canonical copy: $skill" skill_intact "$(dest_for agents "$skill")" "$skill"
  for target in muse claude codex antigravity; do
    dest="$(dest_for "${target}" "$skill")"
    check "link mode symlinks ${target}/${skill}" test "${dest}" -ef "$(dest_for agents "$skill")"
    check "linked bundle intact: ${target}/${skill}" skill_intact "$dest" "$skill"
  done
done

# 4. Upgrade refreshes installed copies and skips missing targets.
rm -rf "${FAKE}"
mkdir -p "${FAKE}"
run_install "${LOG_DIR}/pre-upgrade.log" --agents --muse
printf 'stale\n' >> "$(dest_for agents)/SKILL.md"
rm -rf "$(dest_for agents agent-teamwork)" "$(dest_for muse agent-teamwork)"
run_install "${LOG_DIR}/upgrade.log" --upgrade
check "upgrade refreshes a stale copy" skill_intact "$(dest_for agents)"
check "upgrade skips uninstalled targets" is_missing "$(dest_for codex)"
check "upgrade does not add new skills to canonical store" is_missing "$(dest_for agents agent-teamwork)"
check "upgrade does not add new skills to existing runtime" is_missing "$(dest_for muse agent-teamwork)"

# 5. Dry run changes nothing, neither paths nor bytes.
# cksum (POSIX) rather than md5sum: stock macOS ships no md5sum, and a
# missing checksum tool would silently shrink the snapshot to paths only.
command -v cksum >/dev/null 2>&1 || {
  echo "ERROR: cksum is required but not installed" >&2
  exit 1
}
snapshot() { # snapshot: sorted path list plus per-file checksums.
  find "${FAKE}" | sort
  find "${FAKE}" -type f -exec cksum {} + 2>/dev/null | sort
}
before="$(snapshot)"
run_install "${LOG_DIR}/dry-run.log" --dry-run
after="$(snapshot)"
check "dry run changes nothing" test "${before}" = "${after}"

# 6. Unknown flags fail loudly.
bogus_exit=0
"${BUNDLE}/install.sh" --bogus >/dev/null 2>&1 || bogus_exit=$?
check "unknown flag exits 2" test "${bogus_exit}" -eq 2

# 7. A symlinked skill subdir refuses the install and writes nothing outside.
rm -rf "${FAKE}"
mkdir -p "${FAKE}"
mkdir -p "$(dest_for agents)"
mkdir -p "${TEST_DIR}/victim"
ln -s "${TEST_DIR}/victim" "$(dest_for agents)/agents"
symlink_exit=0
"${BUNDLE}/install.sh" --agents >/dev/null 2>&1 || symlink_exit=$?
check "symlinked subdir refuses install" test "${symlink_exit}" -ne 0
check "refusal writes nothing outside" test ! -e "${TEST_DIR}/victim/openai.yaml"

# 8. An intermediate-ancestor symlink at depth 2 refuses the install. The
# overlay bundle extends the skill with a triply nested file but keeps the
# installer logic untouched: the promise is that a new subdir needs no
# installer change, so the refusal must hold there too. The link sits at
# the middle level, which is no bundled file's leaf parent, so a leaf-only
# check would sail through the real dir seen through the link.
rm -rf "${FAKE}"
mkdir -p "${FAKE}"
OVERLAY="${TEST_DIR}/overlay"
rm -rf "${OVERLAY}"
mkdir -p "${OVERLAY}/skills"
cp -R "${BUNDLE}/skills/." "${OVERLAY}/skills/"
mkdir -p "${OVERLAY}/skills/${SKILL}/agents/nested/deep"
cp "${BUNDLE}/install.sh" "${OVERLAY}/install.sh"
printf 'probe\n' > "${OVERLAY}/skills/${SKILL}/agents/nested/deep/probe.yaml"
sed '/triage-coordination)/s|SKILL.md agents/openai.yaml|SKILL.md agents/openai.yaml agents/nested/deep/probe.yaml|' \
  "${OVERLAY}/install.sh" > "${OVERLAY}/install.sh.new"
mv "${OVERLAY}/install.sh.new" "${OVERLAY}/install.sh"
chmod +x "${OVERLAY}/install.sh"
if ! "${OVERLAY}/install.sh" --agents >"${LOG_DIR}/overlay-clean.log" 2>&1; then
  cat "${LOG_DIR}/overlay-clean.log" >&2
fi
check "nested subdir installs with no installer change" \
  test -f "$(dest_for agents)/agents/nested/deep/probe.yaml"
rm -rf "${FAKE}"
mkdir -p "${FAKE}" "$(dest_for agents)/agents" "${TEST_DIR}/victim2/deep"
ln -s "${TEST_DIR}/victim2" "$(dest_for agents)/agents/nested"
nested_exit=0
"${OVERLAY}/install.sh" --agents >/dev/null 2>&1 || nested_exit=$?
check "intermediate symlink refuses install" test "${nested_exit}" -ne 0
check "depth-2 refusal writes nothing outside" test ! -e "${TEST_DIR}/victim2/deep/probe.yaml"

# 9. Glob characters in the install path do not disable the symlink walk.
GLOB_HOME="${TEST_DIR}/we[ird]"
GLOB_DEST="${GLOB_HOME}/.agents/skills/${SKILL}"
# Positive control: a clean install under the glob-char home succeeds, so
# the refusal below proves the walk fired rather than the installer failing
# on glob paths for any other reason.
rm -rf "${GLOB_HOME}"
mkdir -p "${GLOB_HOME}"
if ! HOME="${GLOB_HOME}" "${BUNDLE}/install.sh" --agents >"${LOG_DIR}/glob-clean.log" 2>&1; then
  cat "${LOG_DIR}/glob-clean.log" >&2
fi
check "clean install under glob-char home succeeds" skill_intact "${GLOB_DEST}"
rm -rf "${GLOB_HOME}" "${TEST_DIR}/victim3"
mkdir -p "${GLOB_DEST}" "${TEST_DIR}/victim3"
ln -s "${TEST_DIR}/victim3" "${GLOB_DEST}/agents"
glob_exit=0
HOME="${GLOB_HOME}" "${BUNDLE}/install.sh" --agents >/dev/null 2>&1 || glob_exit=$?
check "glob-char home still refuses symlinked subdir" test "${glob_exit}" -ne 0
check "glob-char refusal writes nothing outside" test ! -e "${TEST_DIR}/victim3/openai.yaml"

# 10. Teamwork's referenced backend files obey the same symlink refusal.
rm -rf "${FAKE}"
mkdir -p "$(dest_for agents agent-teamwork)" "${TEST_DIR}/reference-victim"
ln -s "${TEST_DIR}/reference-victim" "$(dest_for agents agent-teamwork)/references"
reference_exit=0
"${BUNDLE}/install.sh" --agents >"${LOG_DIR}/reference-refusal.log" 2>&1 || reference_exit=$?
check "teamwork reference symlink refuses install" test "$reference_exit" -ne 0
check "reference refusal writes nothing outside" test -z "$(ls -A "${TEST_DIR}/reference-victim")"

echo "---"
echo "passed: ${pass}, failed: ${fail}"
[ "${fail}" -eq 0 ]
