#!/usr/bin/env bash
#
# slack-rtl.sh — Add RTL (Hebrew/Arabic) support to Slack Desktop on macOS.
#
# Replaces the old fix.sh, which no longer works: Slack's code is no longer in
# app.asar (now just an architecture loader), src/stat-cache.js is gone, jQuery
# was dropped from the bundle, and Electron now verifies asar integrity through
# the ElectronAsarIntegrity key in Info.plist.
#
# What this script does:
#   1. validates its hashing method against an untouched archive before writing
#   2. backs up the whole Slack.app (see the `restore` command to roll back)
#   3. patches dist/preload.bundle.js inside app-<arch>.asar (a CSS rule,
#      no jQuery, no DOM rewriting)
#   4. recomputes the integrity hash and writes it back to Info.plist
#   5. re-signs the app ad-hoc, preserving the bundle identifier and entitlements
#
# WARNING — ad-hoc re-signing has consequences:
#   - you will most likely be signed out of your workspaces (the token lives in
#     the Keychain, and access to it is tied to the app's code signature);
#   - macOS may ask again for microphone / camera / screen-recording permission;
#   - Apple notarization is lost;
#   - a Slack auto-update overwrites the patch (just run the script again).
#
# Usage:
#   ./slack-rtl.sh status              show current state, changes nothing
#   ./slack-rtl.sh patch [--dry-run]   apply the patch
#   ./slack-rtl.sh restore             restore from backup
#
# Requirements: Node.js (brew install node). The `asar` package is installed
# automatically if missing.

set -euo pipefail

# SLACK_RTL_APP allows pointing the script at a copy of Slack.app, which is how
# the pipeline can be exercised end to end without touching the installed app.
readonly SLACK_APP="${SLACK_RTL_APP:-/Applications/Slack.app}"
readonly RESOURCES="${SLACK_APP}/Contents/Resources"
readonly INFO_PLIST="${SLACK_APP}/Contents/Info.plist"
readonly BACKUP_ROOT="${SLACK_RTL_BACKUP_ROOT:-${HOME}/Library/Application Support/slack-rtl}"
readonly PLISTBUDDY="/usr/libexec/PlistBuddy"

# Preload bundle to patch (path relative to the root of the asar archive).
readonly PRELOAD_REL="dist/preload.bundle.js"

readonly MARK_BEGIN="/* >>> slack-rtl begin — do not edit by hand */"
readonly MARK_END="/* <<< slack-rtl end */"

WORKDIR=""
DRY_RUN=0
ASSUME_YES=0

# Set to "sudo" only when the target app is not writable by the current user.
# Apps under /Applications are root-owned; a copy in a user directory is not.
SUDO=""

# ------------------------------------------------------------------- helpers

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

step() { c_blue "==> $*"; }
ok()   { c_green "    ok — $*"; }
info() { c_dim   "    $*"; }
die()  { c_red   "ERROR: $*" >&2; exit 1; }

cleanup() {
  [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# -------------------------------------------------------- embedded Node helper

# Writes $WORKDIR/asar-tool.js, a small utility exposing the asar operations
# this script needs. Subcommands:
#   header-hash <archive>           SHA-256 of the header (the ElectronAsarIntegrity value)
#   list-unpacked <archive>         relative paths flagged as unpacked, one per line
#   count-files <archive>           number of file entries
#   extract <archive> <dest>
#   pack <src> <dest> <ref-archive> pack, reproducing the unpacked set of <ref-archive>
write_asar_tool() {
  cat > "${WORKDIR}/asar-tool.js" <<'NODE_EOF'
'use strict';
const path = require('path');
const crypto = require('crypto');

const asar = require(path.join(process.env.SLACK_RTL_NPM_ROOT, 'asar'));

// Walk the asar header and collect relative paths matching a predicate.
function walk(node, prefix, out, pick) {
  for (const [name, entry] of Object.entries(node.files || {})) {
    const rel = prefix ? `${prefix}/${name}` : name;
    if (entry.files) {
      walk(entry, rel, out, pick);
    } else if (pick(entry)) {
      out.push(rel);
    }
  }
  return out;
}

function header(archive) {
  return JSON.parse(asar.getRawHeader(archive).headerString);
}

function unpackedOf(archive) {
  return walk(header(archive), '', [], e => e.unpacked === true).sort();
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);

  switch (cmd) {
    case 'header-hash': {
      const raw = asar.getRawHeader(rest[0]).headerString;
      process.stdout.write(crypto.createHash('sha256').update(raw).digest('hex') + '\n');
      break;
    }

    case 'list-unpacked': {
      process.stdout.write(unpackedOf(rest[0]).join('\n') + '\n');
      break;
    }

    case 'count-files': {
      process.stdout.write(String(walk(header(rest[0]), '', [], () => true).length) + '\n');
      break;
    }

    case 'extract': {
      asar.extractAll(rest[0], rest[1]);
      break;
    }

    case 'pack': {
      const [src, dest, refArchive] = rest;
      const unpacked = unpackedOf(refArchive);

      // asar matches `options.unpack` with minimatch against the absolute path.
      // Build an alternation pattern listing exactly the files that were
      // unpacked in the reference archive — a faithful reproduction rather than
      // guessing from file extensions.
      const abs = unpacked.map(rel => path.join(src, rel));
      for (const p of abs) {
        if (/[{},]/.test(p)) {
          throw new Error(`path is not glob-safe: ${p}`);
        }
      }

      const options = {};
      if (abs.length === 1) options.unpack = abs[0];
      else if (abs.length > 1) options.unpack = `{${abs.join(',')}}`;

      await asar.createPackageWithOptions(src, dest, options);

      // Safety net: the new archive must have exactly the same unpacked set as
      // the original. Otherwise the native modules (.node) would end up sealed
      // inside the archive and Slack would crash on launch.
      const after = unpackedOf(dest);
      const missing = unpacked.filter(f => !after.includes(f));
      const extra = after.filter(f => !unpacked.includes(f));
      if (missing.length || extra.length) {
        throw new Error(
          'unpacked set diverged after repacking.' +
          (missing.length ? `\n  missing: ${missing.join(', ')}` : '') +
          (extra.length ? `\n  extra:   ${extra.join(', ')}` : '')
        );
      }
      process.stdout.write(`${after.length}\n`);
      break;
    }

    default:
      throw new Error(`unknown subcommand: ${cmd}`);
  }
}

main().catch(err => {
  process.stderr.write(String(err && err.stack ? err.stack : err) + '\n');
  process.exit(1);
});
NODE_EOF
}

asar_tool() {
  SLACK_RTL_NPM_ROOT="${NPM_ROOT}" node "${WORKDIR}/asar-tool.js" "$@"
}

# ------------------------------------------------------------ injected RTL patch

# The code below is appended to the preload bundle. It runs in the renderer and
# has access to the DOM.
#
# What actually breaks RTL in Slack, established by inspecting the live DOM
# rather than guessing:
#
#   1. Slack already sets dir="auto" on message blocks, and the computed
#      direction is correct (rtl for Hebrew). Detection is not the problem.
#   2. Its own stylesheet carries `.p-rich_text_block { text-align: left }`,
#      which pins every line to the left edge regardless of direction. 7 of 8
#      sampled Hebrew blocks had direction:rtl together with text-align:left.
#   3. A multi-line message is a single .p-rich_text_section holding bare text
#      nodes separated by <br>. There is no per-line element, so a line of
#      English code inside a Hebrew message inherits the RTL base direction and
#      renders with its trailing punctuation flipped to the front
#      (";const { id } = alert" instead of "const { id } = alert;").
#
# unicode-bidi:plaintext addresses (3) directly: it runs the bidi algorithm
# independently per <br>-delimited line, so each line gets its own direction.
# Combined with text-align:start for (2), the whole fix is CSS — no DOM
# rewriting, no observer, nothing to keep in sync with Slack's markup.
#
# The old fix.sh did the opposite of all this: it forced text-align:left, which
# is the bug itself.
write_rtl_patch() {
  # The heredoc is quoted so the shell performs no expansion at all on the
  # JavaScript below: backticks, $ and backslashes reach the file untouched.
  # The markers are written separately for that reason.
  {
    printf '\n%s\n' "${MARK_BEGIN}"
    cat <<'PATCH_EOF'
(function () {
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  // `start` is the logical counterpart of `left`: it follows each line's
  // resolved direction, so Hebrew aligns right and Latin stays left.
  var CSS = [
    '.p-rich_text_section, .p-rich_text_block {',
    '  unicode-bidi: plaintext !important;',
    '  text-align: start !important;',
    '}',
    '.ql-editor, .ql-editor p {',
    '  unicode-bidi: plaintext !important;',
    '  text-align: start !important;',
    '}'
  ].join('\n');

  var STYLE_ID = 'slack-rtl-style';

  function inject() {
    if (document.getElementById(STYLE_ID)) return;
    var style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = CSS;
    (document.head || document.documentElement).appendChild(style);
  }

  function start() {
    inject();

    // Slack is a single-page app and may replace parts of <head> on
    // navigation. Watch only head's direct children — far cheaper than
    // observing the message list, and enough to survive a teardown.
    if (document.head) {
      new MutationObserver(function () {
        if (!document.getElementById(STYLE_ID)) inject();
      }).observe(document.head, { childList: true });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
PATCH_EOF
    printf '%s\n' "${MARK_END}"
  } > "${WORKDIR}/rtl-patch.js"
}

# ------------------------------------------------------------------- context

detect_context() {
  [[ "$(uname -s)" == "Darwin" ]] || die "this script only runs on macOS."
  [[ -d "${SLACK_APP}" ]] || die "Slack not found at ${SLACK_APP}."
  [[ -f "${INFO_PLIST}" ]] || die "Info.plist not found inside the Slack bundle."

  command -v node >/dev/null 2>&1 \
    || die "Node.js is required. Install it with: brew install node"

  NPM_ROOT="$(npm root -g)"
  if [[ ! -d "${NPM_ROOT}/asar" ]]; then
    step "Installing the asar package"
    npm install -g asar >/dev/null
    NPM_ROOT="$(npm root -g)"
    [[ -d "${NPM_ROOT}/asar" ]] || die "failed to install asar."
  fi

  case "$(uname -m)" in
    arm64)  ARCH_ASAR="app-arm64.asar" ;;
    x86_64) ARCH_ASAR="app-x64.asar" ;;
    *)      die "unsupported architecture: $(uname -m)" ;;
  esac

  ARCHIVE="${RESOURCES}/${ARCH_ASAR}"
  [[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"

  if [[ -w "${INFO_PLIST}" && -w "${RESOURCES}" ]]; then
    SUDO=""
  else
    SUDO="sudo"
  fi

  SLACK_VERSION="$(defaults read "${INFO_PLIST}" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
  BUNDLE_ID="$(defaults read "${INFO_PLIST}" CFBundleIdentifier 2>/dev/null || echo "com.tinyspeck.slackmacgap")"
  BACKUP_APP="${BACKUP_ROOT}/Slack-${SLACK_VERSION}.app"
}

plist_integrity_key() {
  echo ":ElectronAsarIntegrity:Resources/${1}:hash"
}

read_plist_hash() {
  "${PLISTBUDDY}" -c "Print $(plist_integrity_key "$1")" "${INFO_PLIST}" 2>/dev/null || true
}

is_patched() {
  local probe="${WORKDIR}/probe"
  local found=1
  rm -rf "${probe}"
  if asar_tool extract "${ARCHIVE}" "${probe}" >/dev/null 2>&1 \
     && grep -q "slack-rtl begin" "${probe}/${PRELOAD_REL}" 2>/dev/null; then
    found=0
  fi
  rm -rf "${probe}"
  return ${found}
}

# macOS 14 and later enforce App Management: one application may not modify
# another application's bundle. This is a TCC control, not a file permission,
# so sudo does not lift it. It surfaces as EPERM ("Operation not permitted"),
# where a plain ownership issue would surface as EACCES ("Permission denied") —
# which is what lets this probe tell the two apart without asking for a
# password. Checked up front, before the backup and before quitting Slack.
check_app_management() {
  local probe="${RESOURCES}/.slack-rtl-probe"
  local err
  err="$(touch "${probe}" 2>&1 || true)"

  if [[ -e "${probe}" ]]; then
    rm -f "${probe}" 2>/dev/null || true
    ok "app bundle is writable"
    return 0
  fi

  if [[ "${err}" == *"Operation not permitted"* ]]; then
    local app="${TERM_PROGRAM:-your terminal}"
    die "macOS App Management is blocking writes to ${SLACK_APP}.
       sudo cannot lift this: it is enforced by TCC, not by file permissions.

       Grant the permission, then run this script again:
         System Settings > Privacy & Security > App Management
         turn on: ${app}

       Open that pane directly with:
         open \"x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles\"

       Quit and reopen ${app} afterwards for it to take effect.
       Nothing has been modified."
  fi

  # EACCES here simply means root owns the bundle, which sudo handles.
  ok "app bundle reachable (elevation required)"
  return 0
}

# Check that the hash we compute for an archive matches the one in Info.plist.
# This tests the method before anything is written: if Electron ever changes how
# it computes integrity, we stop instead of bricking the app.
verify_hash_method() {
  local archive_name="$1"
  local expected computed
  expected="$(read_plist_hash "${archive_name}")"
  [[ -n "${expected}" ]] || die "no ElectronAsarIntegrity entry for ${archive_name}."
  computed="$(asar_tool header-hash "${RESOURCES}/${archive_name}")"

  if [[ "${expected}" != "${computed}" ]]; then
    c_red "    Info.plist: ${expected}"
    c_red "    computed:   ${computed}"
    die "the hashing method does not match this version of Slack.
       Either Slack has already been modified, or Electron changed its integrity
       scheme. Nothing was modified."
  fi
  ok "hashing method verified against ${archive_name}"
}

# ------------------------------------------------------------------- commands

cmd_status() {
  detect_context
  WORKDIR="$(mktemp -d)"
  write_asar_tool

  echo
  step "Slack status"
  info "version        : ${SLACK_VERSION}"
  info "bundle id      : ${BUNDLE_ID}"
  info "architecture   : $(uname -m) → ${ARCH_ASAR}"
  info "archive        : ${ARCHIVE}"

  local expected computed
  expected="$(read_plist_hash "${ARCH_ASAR}")"
  computed="$(asar_tool header-hash "${ARCHIVE}")"
  info "Info.plist hash: ${expected:-missing}"
  info "computed hash  : ${computed}"

  if [[ "${expected}" == "${computed}" ]]; then
    ok "integrity consistent"
  else
    c_red "    integrity MISMATCH — Slack may refuse to launch"
  fi

  if is_patched; then
    ok "RTL patch present"
  else
    info "RTL patch      : absent"
  fi

  if [[ -d "${BACKUP_APP}" ]]; then
    ok "backup         : ${BACKUP_APP}"
  else
    info "backup         : none for version ${SLACK_VERSION}"
  fi

  echo
  info "code signature:"
  codesign -dv "${SLACK_APP}" 2>&1 | sed 's/^/      /' || true
  echo
}

quit_slack() {
  if ! pgrep -f "${SLACK_APP}/Contents/MacOS/Slack" >/dev/null 2>&1; then
    info "Slack is not running"
    return 0
  fi

  info "quitting Slack…"
  osascript -e 'tell application "Slack" to quit' >/dev/null 2>&1 || true

  local i
  for i in $(seq 1 20); do
    pgrep -f "${SLACK_APP}/Contents/MacOS/Slack" >/dev/null 2>&1 || { ok "Slack quit"; return 0; }
    sleep 0.5
  done

  # Fallback: target the exact binary path, not a broad grep for "Slack" that
  # would match the grep process itself and any similarly named process.
  info "forcing quit"
  pkill -f "${SLACK_APP}/Contents/MacOS/Slack" 2>/dev/null || true
  sleep 2
  pgrep -f "${SLACK_APP}/Contents/MacOS/Slack" >/dev/null 2>&1 \
    && die "could not quit Slack; quit it manually and run again." || true
  ok "Slack quit"
}

confirm() {
  [[ ${ASSUME_YES} -eq 1 ]] && return 0
  # No terminal attached and no --yes: refuse rather than block on a read that
  # will never be answered.
  [[ -t 0 ]] || die "not running interactively; pass --yes to confirm up front."
  echo
  c_red "This script modifies Slack.app and re-signs it ad-hoc."
  echo "  Likely consequences:"
  echo "    - signed out of your workspaces (Keychain access is tied to the signature)"
  echo "    - microphone / camera / screen-recording permissions to grant again"
  echo "    - Apple notarization lost"
  echo "    - patch overwritten by the next Slack update"
  echo
  echo "  A full backup is taken first. To roll back:"
  echo "    ./slack-rtl.sh restore"
  echo
  printf "  Continue? [yes/NO] "
  local answer
  read -r answer
  [[ "${answer}" == "yes" ]] || { echo "Aborted."; exit 0; }
}

cmd_patch() {
  detect_context
  WORKDIR="$(mktemp -d)"
  write_asar_tool
  write_rtl_patch

  step "Pre-flight checks"
  info "Slack ${SLACK_VERSION} — ${ARCH_ASAR}"
  # Validate the method against app.asar, which we never modify: a safe baseline.
  verify_hash_method "app.asar"
  verify_hash_method "${ARCH_ASAR}"
  check_app_management

  if is_patched; then
    ok "RTL patch already present — it will be cleanly reapplied"
  fi

  if [[ ${DRY_RUN} -eq 1 ]]; then
    echo
    step "Dry run — nothing will be written"
    info "backup would go to : ${BACKUP_APP}"
    info "file to patch      : ${ARCH_ASAR} → ${PRELOAD_REL}"
    info "unpacked to keep   : $(asar_tool list-unpacked "${ARCHIVE}" | wc -l | tr -d ' ') files"
    info "Info.plist key     : $(plist_integrity_key "${ARCH_ASAR}")"
    info "re-signing         : codesign --force --sign - --identifier ${BUNDLE_ID}"
    echo
    ok "dry run complete"
    return 0
  fi

  confirm

  step "Backup"
  if [[ -d "${BACKUP_APP}" ]]; then
    ok "backup already exists for ${SLACK_VERSION} (left untouched)"
  else
    mkdir -p "${BACKUP_ROOT}"
    info "copying Slack.app to ${BACKUP_APP} (may take a minute)…"
    ${SUDO} ditto "${SLACK_APP}" "${BACKUP_APP}"
    [[ -n "${SUDO}" ]] && ${SUDO} chown -R "$(id -u):$(id -g)" "${BACKUP_APP}"
    ok "backup complete"
  fi

  quit_slack

  step "Extracting ${ARCH_ASAR}"
  local src="${WORKDIR}/src"
  asar_tool extract "${ARCHIVE}" "${src}"
  local preload="${src}/${PRELOAD_REL}"
  [[ -f "${preload}" ]] || die "${PRELOAD_REL} missing from the archive — Slack changed its layout."
  local n_files n_unpacked
  n_files="$(asar_tool count-files "${ARCHIVE}")"
  n_unpacked="$(asar_tool list-unpacked "${ARCHIVE}" | wc -l | tr -d ' ')"
  ok "${n_files} files extracted, ${n_unpacked} flagged as unpacked"

  step "Injecting the RTL patch"
  # Idempotence: strip any previous block before injecting a fresh one.
  if grep -q "slack-rtl begin" "${preload}"; then
    sed -i '' "/slack-rtl begin/,/slack-rtl end/d" "${preload}"
    info "previous block removed"
  fi
  cat "${WORKDIR}/rtl-patch.js" >> "${preload}"
  ok "patch appended to ${PRELOAD_REL}"

  step "Repacking"
  local new_archive="${WORKDIR}/${ARCH_ASAR}"
  local kept
  kept="$(asar_tool pack "${src}" "${new_archive}" "${ARCHIVE}")"
  ok "archive rebuilt, ${kept} unpacked files preserved"

  local new_hash
  new_hash="$(asar_tool header-hash "${new_archive}")"
  info "new hash: ${new_hash}"

  step "Installing"
  ${SUDO} cp "${new_archive}" "${ARCHIVE}"
  ok "${ARCH_ASAR} replaced"

  step "Updating ElectronAsarIntegrity"
  ${SUDO} "${PLISTBUDDY}" -c "Set $(plist_integrity_key "${ARCH_ASAR}") ${new_hash}" "${INFO_PLIST}"
  local check
  check="$(read_plist_hash "${ARCH_ASAR}")"
  [[ "${check}" == "${new_hash}" ]] || die "Info.plist was not updated correctly. Run: ./slack-rtl.sh restore"
  ok "Info.plist updated"

  step "Re-signing"
  # Editing Info.plist invalidates the main bundle's signature. Re-sign ad-hoc,
  # keeping the identifier and entitlements to limit fallout on TCC (microphone,
  # camera) and the Keychain.
  #
  # Important: we deliberately pass neither --options runtime nor
  # --preserve-metadata=flags. Slack ships signed with the library-validation
  # flag (0x12000), which restricts library loading to the same Team ID
  # (BQR82RBBHL). Keeping it on an ad-hoc signature would make the native .node
  # modules — still signed by Slack — unloadable, and the app would crash on
  # launch.
  local ent="${WORKDIR}/entitlements.plist"
  if codesign -d --entitlements "${ent}" --xml "${SLACK_APP}" >/dev/null 2>&1 && [[ -s "${ent}" ]]; then
    info "original entitlements recovered"
    ${SUDO} codesign --force --sign - \
      --identifier "${BUNDLE_ID}" \
      --entitlements "${ent}" \
      "${SLACK_APP}"
  else
    info "entitlements not recoverable — signing without them"
    ${SUDO} codesign --force --sign - --identifier "${BUNDLE_ID}" "${SLACK_APP}"
  fi

  if codesign --verify --deep --strict "${SLACK_APP}" 2>/dev/null; then
    ok "signature valid"
  else
    c_red "    signature verification failed"
    info "Slack may refuse to launch. Roll back with: ./slack-rtl.sh restore"
  fi

  echo
  c_green "Patch applied. Slack ${SLACK_VERSION} — automatic RTL enabled."
  info "If Slack asks you to sign in again, that is expected (see the warning)."
  info "Roll back at any time with: ./slack-rtl.sh restore"
  # Only offer to launch when there is a terminal to answer the prompt.
  # Launching unattended would be surprising, and `open` resolves by bundle
  # identifier anyway, which may well focus a different copy of Slack.
  if [[ -t 0 ]]; then
    echo
    printf "  Launch Slack now? [Y/n] "
    local answer=""
    read -r answer || true
    [[ "${answer}" =~ ^([nN]) ]] || open "${SLACK_APP}"
  fi
}

cmd_restore() {
  detect_context

  local backup="${BACKUP_APP}"
  if [[ ! -d "${backup}" ]]; then
    # No backup for the current version: offer the most recent one available.
    local candidate
    candidate="$(find "${BACKUP_ROOT}" -maxdepth 1 -name 'Slack-*.app' 2>/dev/null | sort | tail -1)"
    [[ -n "${candidate}" ]] || die "no backup found in ${BACKUP_ROOT}."
    c_red "No backup for version ${SLACK_VERSION}."
    info "available backup: ${candidate}"
    printf "  Restore it? [yes/NO] "
    local answer
    read -r answer
    [[ "${answer}" == "yes" ]] || { echo "Aborted."; exit 0; }
    backup="${candidate}"
  fi

  step "Restoring from ${backup}"
  quit_slack
  ${SUDO} rm -rf "${SLACK_APP}"
  ${SUDO} ditto "${backup}" "${SLACK_APP}"
  [[ -n "${SUDO}" ]] && ${SUDO} chown -R root:wheel "${SLACK_APP}"
  ok "Slack.app restored"

  if codesign --verify --deep --strict "${SLACK_APP}" 2>/dev/null; then
    ok "original signature valid"
  else
    c_red "    restored signature does not verify — reinstall Slack from slack.com"
  fi

  echo
  c_green "Restore complete."
  info "A clean reinstall is always an option: https://slack.com/downloads/mac"
  echo
}

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------------------------------------------------------------------- main

main() {
  local command="${1:-}"
  shift || true

  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y)  ASSUME_YES=1 ;;
      *)         die "unknown option: ${arg}" ;;
    esac
  done

  case "${command}" in
    status)  cmd_status ;;
    patch)   cmd_patch ;;
    restore) cmd_restore ;;
    ""|-h|--help|help) usage ;;
    *)       die "unknown command: ${command} (status | patch | restore)" ;;
  esac
}

main "$@"
