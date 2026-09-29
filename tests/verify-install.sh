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
dest_for() { # dest_for <target>
  case "$1" in
    agents) printf '%s/.agents/skills/%s\n' "${FAKE}" "${SKILL}" ;;
    muse) printf '%s/.config/muse/skills/%s\n' "${FAKE}" "${SKILL}" ;;
    claude) printf '%s/.claude/skills/%s\n' "${FAKE}" "${SKILL}" ;;
    codex) printf '%s/.codex/skills/%s\n' "${FAKE}" "${SKILL}" ;;
    antigravity) printf '%s/.gemini/config/skills/%s\n' "${FAKE}" "${SKILL}" ;;
  esac
}
skill_intact() { # skill_intact <dest>
  [ -f "$1/SKILL.md" ] \
    && [ -f "$1/agents/openai.yaml" ] \
    && grep -qxF "name: ${SKILL}" "$1/SKILL.md" \
    && cmp -s "${BUNDLE}/skills/${SKILL}/SKILL.md" "$1/SKILL.md"
}

# 1. Plain install reaches every target with intact files.
run_install "${LOG_DIR}/install.log"
for target in agents muse claude codex antigravity; do
  check "plain install populates ${target}" skill_intact "$(dest_for "${target}")"
done

# 2. Re-running is idempotent.
run_install "${LOG_DIR}/idempotent.log"
check "second run reports unchanged" grep -q "unchanged:" "${LOG_DIR}/idempotent.log"

# 3. Link mode symlinks non-canonical targets at the canonical copy.
rm -rf "${FAKE}"
mkdir -p "${FAKE}"
run_install "${LOG_DIR}/link.log" --link
check "link mode installs canonical copy" skill_intact "$(dest_for agents)"
for target in muse claude codex antigravity; do
  dest="$(dest_for "${target}")"
  check "link mode symlinks ${target}" test "${dest}" -ef "$(dest_for agents)"
done

# 4. Upgrade refreshes installed copies and skips missing targets.
rm -rf "${FAKE}"
mkdir -p "${FAKE}"
run_install "${LOG_DIR}/pre-upgrade.log" --agents --muse
printf 'stale\n' >> "$(dest_for agents)/SKILL.md"
run_install "${LOG_DIR}/upgrade.log" --upgrade
check "upgrade refreshes a stale copy" skill_intact "$(dest_for agents)"
check "upgrade skips uninstalled targets" is_missing "$(dest_for codex)"

# 5. Dry run changes nothing.
before="$(find "${FAKE}" | sort)"
run_install "${LOG_DIR}/dry-run.log" --dry-run
after="$(find "${FAKE}" | sort)"
check "dry run changes nothing" test "${before}" = "${after}"

# 6. Unknown flags fail loudly.
bogus_exit=0
"${BUNDLE}/install.sh" --bogus >/dev/null 2>&1 || bogus_exit=$?
check "unknown flag exits 2" test "${bogus_exit}" -eq 2

echo "---"
echo "passed: ${pass}, failed: ${fail}"
[ "${fail}" -eq 0 ]
