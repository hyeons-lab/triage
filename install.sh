#!/usr/bin/env bash
#
# Install the Triage agent skill (triage-coordination) for Muse, Claude Code,
# Codex, and Antigravity/Gemini, so agents in Triage sessions know how to
# coordinate through the triage-mcp tools.
#
# Idempotent: re-running changes nothing when everything is current.
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --all             install to every target below (default)
#   --agents          install to ~/.agents/skills (canonical cross-agent store)
#   --muse            install to the Muse skills dir
#   --claude          install to ~/.claude/skills
#   --codex           install to ~/.codex/skills
#   --antigravity     install to the Antigravity/Gemini skills dir
#   --gemini          alias for --antigravity
#   --link            symlink agent dirs to the canonical copy instead of
#                     copying files (falls back to copying when linking fails)
#   --upgrade         refresh already-installed skills to the checked-out
#                     version: targets without the skill are skipped (never
#                     newly installed), and symlinked installs are left alone
#                     (they follow the canonical copy); the canonical store
#                     is always in scope so linked installs refresh for real
#   --dry-run         print what would change without changing anything
#   -h, --help        print this help and exit
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="triage-coordination"

AGENTS_BASE="${HOME}/.agents/skills"
MUSE_BASE="${XDG_CONFIG_HOME:-${HOME}/.config}/muse/skills"
CLAUDE_BASE="${HOME}/.claude/skills"
CODEX_BASE="${HOME}/.codex/skills"
ANTIGRAVITY_BASE="${HOME}/.gemini/config/skills"

skill_files() {
  # skill_files <skill>: print the bundled files that make up one skill.
  case "$1" in
    triage-coordination) printf 'SKILL.md agents/openai.yaml\n' ;;
    *) printf 'ERROR: unknown skill: %s\n' "$1" >&2; return 1 ;;
  esac
}

dest_for_target() {
  # dest_for_target <skill> <target>: print the install dir for one pair.
  case "$2" in
    agents)      printf '%s/%s\n' "${AGENTS_BASE}" "$1" ;;
    muse)        printf '%s/%s\n' "${MUSE_BASE}" "$1" ;;
    claude)      printf '%s/%s\n' "${CLAUDE_BASE}" "$1" ;;
    codex)       printf '%s/%s\n' "${CODEX_BASE}" "$1" ;;
    antigravity) printf '%s/%s\n' "${ANTIGRAVITY_BASE}" "$1" ;;
    *) printf 'ERROR: unknown target: %s\n' "$2" >&2; return 1 ;;
  esac
}

is_missing() {
  # is_missing <dest>: true when nothing is installed there (plain or symlink).
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

DRY_RUN=0
LINK_MODE=0
UPGRADE_MODE=0
TARGETS=""

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

log() {
  printf '%s\n' "$*"
}

err() {
  printf '%s\n' "$*" >&2
}

copy_atomic() {
  # copy_atomic <src> <dest>: copy via temp file plus rename.
  local src="$1" dest="$2" tmp
  if [ -d "${dest}" ]; then
    err "ERROR: destination is an existing directory: ${dest}"
    return 1
  fi
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  if cp -p "${src}" "${tmp}" && mv -f "${tmp}" "${dest}"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

install_file() {
  # install_file <src> <dest>: copy when missing or different; else report.
  local src="$1" dest="$2"
  if [ ! -f "${src}" ]; then
    err "ERROR: missing bundle file: ${src}"
    return 1
  fi
  if [ -L "${dest}" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      printf '[dry-run] replace symlink with file: %s\n' "${dest}"
    else
      log "  replace symlink with file: ${dest}"
      if copy_atomic "${src}" "${dest}"; then
        printf '  updated: %s\n' "${dest}"
      else
        printf '  FAILED to replace: %s (check permissions, then re-run install.sh)\n' "${dest}"
        return 1
      fi
    fi
  elif [ ! -f "${dest}" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      printf '[dry-run] install %s\n' "${dest}"
    elif copy_atomic "${src}" "${dest}"; then
      printf '  installed: %s\n' "${dest}"
    else
      printf '  FAILED to install: %s (check permissions and disk space, then re-run install.sh)\n' "${dest}"
      return 1
    fi
  elif cmp -s "${src}" "${dest}"; then
    printf '  unchanged: %s\n' "${dest}"
  else
    if [ "${DRY_RUN}" -eq 1 ]; then
      printf '[dry-run] update %s\n' "${dest}"
    elif copy_atomic "${src}" "${dest}"; then
      printf '  updated: %s\n' "${dest}"
    else
      printf '  FAILED to update: %s (check permissions and disk space, then re-run install.sh)\n' "${dest}"
      return 1
    fi
  fi
}

install_skill_copy() {
  # install_skill_copy <skill> <dest_dir> [label]
  local skill="$1" dest="$2" file src files parent check label="${3:-copy}"
  src="${SCRIPT_DIR}/skills/${skill}"
  if [ "${label}" != "upgrade" ]; then
    log "==> Skill (${label}): ${skill} ${dest}"
  fi
  if [ -L "${dest}" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      printf '[dry-run] replace symlink with directory: %s\n' "${dest}"
      return 0
    fi
    log "  replace symlink with directory: ${dest}"
    rm "${dest}" || return 1
  fi
  files="$(skill_files "${skill}")" || return 1
  # Parent dirs come from the file list itself, so a new bundled subdir needs
  # no installer change. Every ancestor of every parent (not just the leaf)
  # is validated before any file lands, so a refusal never leaves a
  # half-installed skill behind and a symlink at any depth cannot redirect
  # the install outside the destination.
  # shellcheck disable=SC2086
  for file in ${files}; do
    parent="${dest}/$(dirname "${file}")"
    check="${parent}"
    # Quoted "${dest}" in the case pattern matches literally, so glob
    # characters in the install path cannot silently disable the walk.
    while case "${check}" in "${dest}"/?*) true ;; *) false ;; esac; do
      if [ -L "${check}" ]; then
        err "ERROR: refusing to install through symlink: ${check}"
        return 1
      fi
      check="$(dirname "${check}")"
    done
    if [ ! -d "${parent}" ]; then
      if [ "${DRY_RUN}" -eq 1 ]; then
        printf '[dry-run] mkdir -p %s\n' "${parent}"
      elif ! mkdir -p "${parent}"; then
        printf '  FAILED to create directory: %s\n' "${parent}"
        return 1
      fi
    fi
  done
  # shellcheck disable=SC2086
  for file in ${files}; do
    install_file "${src}/${file}" "${dest}/${file}" || return 1
  done
}

install_skill_link() {
  # install_skill_link <skill> <dest_dir>: link dest to the canonical copy.
  local skill="$1" dest="$2"
  local canonical="${AGENTS_BASE}/${skill}"
  log "==> Skill (link): ${skill} ${dest} -> ${canonical}"
  if [ -L "${dest}" ] && [ "$(readlink "${dest}")" = "${canonical}" ]; then
    printf '  unchanged: %s\n' "${dest}"
    return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '[dry-run] link %s -> %s\n' "${dest}" "${canonical}"
    return 0
  fi
  if ! is_missing "${dest}"; then
    log "  replacing existing path with symlink: ${dest}"
    rm -rf "${dest}" || return 1
  fi
  if ! mkdir -p "$(dirname "${dest}")"; then
    printf '  FAILED to create directory: %s\n' "$(dirname "${dest}")"
    return 1
  fi
  if ln -s "${canonical}" "${dest}"; then
    printf '  linked: %s\n' "${dest}"
  else
    log "  link failed; falling back to copy for ${dest}"
    install_skill_copy "${skill}" "${dest}" || return 1
  fi
}

verify_skill() {
  # verify_skill <skill> <dest_dir>: confirm the install is loadable.
  # Paths are tested through ${dest} itself so relative symlinks resolve
  # against the link's directory (never the CWD), with no readlink needed.
  local skill="$1" dest="$2" file
  if [ ! -f "${dest}/SKILL.md" ]; then
    printf '  MISSING: %s (no SKILL.md; reinstall, or check the link target)\n' "${dest}"
    return 1
  fi
  if ! grep -qxF "name: ${skill}" "${dest}/SKILL.md"; then
    printf '  INVALID: %s (SKILL.md name mismatch; expected %s)\n' "${dest}" "${skill}"
    return 1
  fi
  for file in $(skill_files "${skill}"); do
    if [ ! -f "${dest}/${file}" ]; then
      printf '  MISSING: %s (missing bundled file: %s)\n' "${dest}" "${file}"
      return 1
    fi
  done
  printf '  ok: %s\n' "${dest}"
}

upgrade_skill() {
  # upgrade_skill <skill> <dest>: refresh an installed copy; skip otherwise.
  local skill="$1" dest="$2" canonical link_text
  canonical="${AGENTS_BASE}/${skill}"
  log "==> Skill (upgrade): ${skill} ${dest}"
  if is_missing "${dest}"; then
    log "  not installed, skipping (upgrade never installs to new targets)"
    return 0
  fi
  if [ -L "${dest}" ]; then
    link_text="$(readlink "${dest}" 2>/dev/null || echo unknown)"
    if [ ! -e "${dest}" ]; then
      log "  WARNING: linked install dangles (target ${link_text} is missing); leaving in place, verify will flag it"
    elif [ -e "${canonical}" ] && [ "${dest}" -ef "${canonical}" ]; then
      log "  linked install, follows the canonical copy; leaving in place"
    else
      log "  WARNING: link points at ${link_text}, not the canonical copy; leaving in place"
    fi
    return 0
  fi
  install_skill_copy "${skill}" "${dest}" upgrade
}

# Parse flags.
while [ $# -gt 0 ]; do
  case "$1" in
    --all)          TARGETS="agents muse claude codex antigravity" ;;
    --agents)       TARGETS="${TARGETS} agents" ;;
    --muse)         TARGETS="${TARGETS} muse" ;;
    --claude)       TARGETS="${TARGETS} claude" ;;
    --codex)        TARGETS="${TARGETS} codex" ;;
    --antigravity|--gemini) TARGETS="${TARGETS} antigravity" ;;
    --link)         LINK_MODE=1 ;;
    --upgrade) UPGRADE_MODE=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              err "ERROR: unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

for skill in ${SKILLS}; do
  if [ ! -f "${SCRIPT_DIR}/skills/${skill}/SKILL.md" ]; then
    err "ERROR: skill source not found: ${SCRIPT_DIR}/skills/${skill}/SKILL.md"
    exit 1
  fi
done

# Upgrade never changes install type.
if [ "${UPGRADE_MODE}" -eq 1 ] && [ "${LINK_MODE}" -eq 1 ]; then
  log "note: --upgrade ignores --link (installed types are never changed)"
  LINK_MODE=0
fi
# Link mode and upgrade both need the canonical store in scope and first:
# links are created against it, and linked installs refresh through it (a
# missing canonical copy is still skipped, never newly installed).
if [ -z "${TARGETS}" ]; then
  TARGETS="agents muse claude codex antigravity"
elif [ "${LINK_MODE}" -eq 1 ] || [ "${UPGRADE_MODE}" -eq 1 ]; then
  TARGETS="agents ${TARGETS}"
fi
# Deduplicate while keeping order.
# shellcheck disable=SC2086
TARGETS="$(printf '%s\n' ${TARGETS} | awk '!seen[$0]++' | tr '\n' ' ')"

failures=0
for skill in ${SKILLS}; do
  for target in ${TARGETS}; do
    dest="$(dest_for_target "${skill}" "${target}")" || exit 1
    if [ "${UPGRADE_MODE}" -eq 1 ]; then
      upgrade_skill "${skill}" "${dest}" || failures=$((failures + 1))
    elif [ "${LINK_MODE}" -eq 1 ] && [ "${target}" != "agents" ]; then
      install_skill_link "${skill}" "${dest}" || failures=$((failures + 1))
    else
      install_skill_copy "${skill}" "${dest}" || failures=$((failures + 1))
    fi
  done
done

if [ "${DRY_RUN}" -eq 0 ]; then
  log "==> Verify"
  for skill in ${SKILLS}; do
    for target in ${TARGETS}; do
      dest="$(dest_for_target "${skill}" "${target}")" || exit 1
      if [ "${UPGRADE_MODE}" -eq 1 ] && is_missing "${dest}"; then
        printf '  not installed, skipped: %s\n' "${dest}"
        continue
      fi
      verify_skill "${skill}" "${dest}" || failures=$((failures + 1))
    done
  done
fi

if [ "${failures}" -gt 0 ]; then
  log "Completed with ${failures} problem(s)."
  exit 1
fi
log "Done. Invoke with /triage-coordination in any supported agent."
