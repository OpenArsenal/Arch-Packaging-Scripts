#!/usr/bin/env bash
set -uo pipefail

# install-updates.sh
#
# Cross-compare installed packages with local PKGBUILDs.
# If local PKGBUILD version is newer than installed:
#   - install already-built artifact if present
#   - otherwise build it, then install
# Failures warn and continue.
#
# Examples:
#   ./install-updates.sh --root "$HOME/Projects/Packages"
#   ./install-updates.sh --root "$HOME/Projects/Packages" --dry-run
#   ./install-updates.sh --root "$HOME/Projects/Packages" -y
#   ./install-updates.sh --root "$HOME/Projects/Packages" ollama ktailctl

declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  log_err "Do not run this script as root."
  exit 1
fi

# ----- CLI flags -----

declare ROOT="${ROOT:-"$PWD"}"
declare DRY_RUN="false"
declare DEBUG="false"
declare CLEAN="false"
declare INCLUDE_VCS="false"

declare INTERACTIVE="true"
declare YES_ALL="false"

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [DIR_NAMES...]

Scans local PKGBUILDs under --root, intersects with installed packages,
and updates installed packages if local version is newer.

OPTIONS:
  --root <path>        Root containing package dirs (default: PWD)
  --dry-run            Print what would happen; do nothing
  --clean              Remove src/pkg/*.pkg.tar.* before building
  --include-vcs        Include *-git/*-hg/*-svn packages (default: skipped)
  --debug              Extra logs
  --no-prompt          Never prompt (non-interactive)
  -y, --yes            Assume yes for all prompts (also non-interactive)
  -h, --help           Show help

If DIR_NAMES are provided, only those directories are scanned (still only updates if installed).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?missing path after --root}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --clean) CLEAN="true"; shift ;;
    --include-vcs) INCLUDE_VCS="true"; shift ;;
    --debug) DEBUG="true"; shift ;;
    --no-prompt) INTERACTIVE="false"; shift ;;
    -y|--yes) YES_ALL="true"; INTERACTIVE="false"; shift ;;
    -h|--help) show_usage; exit 0 ;;
    --) shift; break ;;
    -*) log_err "Unknown option: $1"; show_usage; exit 1 ;;
    *) break ;;
  esac
done

if [[ ! -t 0 || ! -t 1 ]]; then
  INTERACTIVE="false"
fi

declare -a SELECTED_DIRS=()
if [[ $# -gt 0 ]]; then
  SELECTED_DIRS=("$@")
fi

# ----- prompt helpers (same vibe as update-pkg.sh) -----

read_choice_tty() {
  local out_var="$1"
  local prompt="$2"
  local choice=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r choice </dev/tty || choice=""
  printf -v "$out_var" "%s" "$choice"
}

confirm_action() {
  local label="$1"   # e.g. "ollama: install update"
  local from="$2"    # installed version
  local to="$3"      # local version

  if [[ "$INTERACTIVE" != "true" ]]; then
    return 0
  fi
  if [[ "$YES_ALL" == "true" ]]; then
    return 0
  fi

  local ans=""
  while true; do
    read_choice_tty ans \
      "[PROMPT] ${label} (${from} -> ${to})? [y]es/[n]o/[a]ll/[q]uit: "
    case "${ans,,}" in
      y|"") return 0 ;;
      n) return 1 ;;
      a) YES_ALL="true"; return 0 ;;
      q) log_err "Aborted by user."; exit 1 ;;
      *) ;;
    esac
  done
}

# ----- deps -----

check_deps() {
  local -a missing=()
  command -v pacman >/dev/null 2>&1 || missing+=("pacman")
  command -v makepkg >/dev/null 2>&1 || missing+=("base-devel")
  command -v sudo >/dev/null 2>&1 || missing+=("sudo")
  command -v vercmp >/dev/null 2>&1 || true

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ----- core helpers -----

is_vcs_name() {
  local name="${1:-}"
  [[ "$name" =~ -(git|hg|svn|bzr)$ ]]
}

is_installed() {
  local pkg="${1:?pkg required}"
  pacman -Qq "$pkg" >/dev/null 2>&1
}

installed_version() {
  local pkg="${1:?pkg required}"
  pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'
}

vercmp_gt() {
  # returns 0 if a > b
  local a="$1"
  local b="$2"

  if command -v vercmp >/dev/null 2>&1; then
    [[ "$(vercmp "$a" "$b")" -gt 0 ]]
    return
  fi

  # Fallback: string compare (less accurate)
  [[ "$a" != "$b" ]] && [[ "$a" > "$b" ]]
}

vercmp_eq() {
  local a="$1"
  local b="$2"

  if command -v vercmp >/dev/null 2>&1; then
    [[ "$(vercmp "$a" "$b")" -eq 0 ]]
    return
  fi
  [[ "$a" == "$b" ]]
}

pkgbuild_meta() {
  # Prints:
  #   <epoch> <pkgver> <pkgrel>
  # Returns non-zero on failure.
  #
  # Uses makepkg --printsrcinfo so it correctly handles arrays, etc.
  makepkg --printsrcinfo 2>/dev/null | awk '
    $1=="epoch"  && $2=="=" { epoch=$3 }
    $1=="pkgver" && $2=="=" { pkgver=$3 }
    $1=="pkgrel" && $2=="=" { pkgrel=$3 }
    END {
      if (pkgver=="" || pkgrel=="") exit 2
      if (epoch=="") epoch="0"
      print epoch, pkgver, pkgrel
    }
  '
}

pkgbuild_pkgnames() {
  # Prints one pkgname per line (may be multiple).
  makepkg --printsrcinfo 2>/dev/null | awk '
    $1=="pkgname" && $2=="=" { print $3 }
  ' | sed '/^$/d' | awk '!seen[$0]++'
}

local_version_string() {
  local epoch="$1"
  local pkgver="$2"
  local pkgrel="$3"
  if [[ -n "$epoch" && "$epoch" != "0" ]]; then
    printf "%s:%s-%s" "$epoch" "$pkgver" "$pkgrel"
  else
    printf "%s-%s" "$pkgver" "$pkgrel"
  fi
}

artifact_paths_for_installed_pkgs() {
  # Given: epoch pkgver pkgrel, plus a list of package names on stdin (installed ones),
  # emits matching built artifact paths from makepkg --packagelist.
  #
  # Matches files like:
  #   /path/pkgname-pkgver-pkgrel-arch.pkg.tar.zst
  local pkgver="$1"
  local pkgrel="$2"

  local -a wanted=()
  local line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && wanted+=("$line")
  done

  local -a all_files=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && all_files+=("$line")
  done < <(makepkg --packagelist 2>/dev/null || true)

  # If packagelist fails, emit nothing.
  [[ ${#all_files[@]} -eq 0 ]] && return 0

  local f=""
  local w=""
  for w in "${wanted[@]}"; do
    # Use a deterministic pattern boundary: "-${pkgver}-${pkgrel}-"
    local needle="-${pkgver}-${pkgrel}-"
    for f in "${all_files[@]}"; do
      local base="${f##*/}"
      if [[ "$base" == "$w"*"$needle"*".pkg.tar."* ]]; then
        printf "%s\n" "$f"
      fi
    done
  done
}

all_files_exist() {
  local -a files=("$@")
  local f=""
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || return 1
  done
  return 0
}

install_files() {
  # Install built package files.
  local -a files=("$@")
  [[ ${#files[@]} -eq 0 ]] && return 1

  log_debug "Installing via pacman -U: ${files[*]}"
  sudo pacman -U --noconfirm --needed -- "${files[@]}" >/dev/null 2>&1
}

build_in_dir() {
  # Build packages in current directory (non-root).
  # -s install deps, -c clean after, -f force rebuild, --noconfirm, --needed for deps.
  #
  # We do not use -i here, because we want to install only the installed subset artifacts.
  makepkg -scf --noconfirm --needed
}

# ----- main scan/update loop -----

main() {
  check_deps

  ROOT="$(cd "$ROOT" && pwd)"
  log_info "Root: $ROOT"
  log_debug "Interactive: $INTERACTIVE | Yes-all: $YES_ALL | Dry-run: $DRY_RUN | Clean: $CLEAN | Include VCS: $INCLUDE_VCS"

  local -a dirs=()

  if [[ ${#SELECTED_DIRS[@]} -gt 0 ]]; then
    local d=""
    for d in "${SELECTED_DIRS[@]}"; do
      [[ -d "$ROOT/$d" ]] && dirs+=("$ROOT/$d")
    done
  else
    while IFS= read -r d; do
      dirs+=("$d")
    done < <(find "$ROOT" -maxdepth 2 -mindepth 2 -type f -name PKGBUILD -printf '%h\n' 2>/dev/null | sort)
  fi

  if [[ ${#dirs[@]} -eq 0 ]]; then
    log_warn "No PKGBUILD directories found under: $ROOT"
    return 0
  fi

  local checked=0
  local updated=0
  local skipped=0
  local failed=0

  local dir=""
  for dir in "${dirs[@]}"; do
    local pkgb="$dir/PKGBUILD"
    [[ -f "$pkgb" ]] || continue

    local dir_name="${dir##*/}"
    ((checked++))

    (
      cd "$dir"

      # Collect pkgnames, then filter to installed pkgnames
      local -a all_pkgs=()
      local p=""
      while IFS= read -r p; do
        [[ -n "$p" ]] && all_pkgs+=("$p")
      done < <(pkgbuild_pkgnames || true)

      if [[ ${#all_pkgs[@]} -eq 0 ]]; then
        log_warn "[$dir_name] Could not read pkgname(s) (makepkg --printsrcinfo failed?)"
        exit 0
      fi

      # Skip VCS by default (unless --include-vcs)
      if [[ "$INCLUDE_VCS" != "true" ]]; then
        local maybe_vcs="false"
        for p in "${all_pkgs[@]}"; do
          if is_vcs_name "$p"; then
            maybe_vcs="true"
            break
          fi
        done
        if [[ "$maybe_vcs" == "true" ]]; then
          log_ok "[$dir_name] Skip VCS package(s): ${all_pkgs[*]}"
          exit 0
        fi
      fi

      local -a installed_pkgs=()
      for p in "${all_pkgs[@]}"; do
        if is_installed "$p"; then
          installed_pkgs+=("$p")
        fi
      done

      if [[ ${#installed_pkgs[@]} -eq 0 ]]; then
        log_ok "[$dir_name] No produced packages are installed; skipping"
        exit 0
      fi

      # Read version meta from PKGBUILD
      local meta=""
      meta="$(pkgbuild_meta || true)"
      if [[ -z "$meta" ]]; then
        log_warn "[$dir_name] Could not read pkgver/pkgrel (skipping): ${installed_pkgs[*]}"
        exit 0
      fi

      local epoch="" pkgver="" pkgrel=""
      read -r epoch pkgver pkgrel <<<"$meta"

      local local_ver=""
      local_ver="$(local_version_string "$epoch" "$pkgver" "$pkgrel")"

      # Determine if any installed pkg needs an update
      local need_update="false"
      local any_newer="false"
      local any_older="false"

      for p in "${installed_pkgs[@]}"; do
        local inst_ver=""
        inst_ver="$(installed_version "$p")"

        if vercmp_eq "$local_ver" "$inst_ver"; then
          log_ok "[$dir_name] $p up-to-date ($inst_ver)"
          continue
        fi

        if vercmp_gt "$local_ver" "$inst_ver"; then
          log_info "[$dir_name] $p needs update ($inst_ver -> $local_ver)"
          need_update="true"
          any_newer="true"
        else
          log_warn "[$dir_name] $p installed is newer than local ($inst_ver > $local_ver)"
          any_older="true"
        fi
      done

      # Only act if local is newer for at least one installed pkg
      if [[ "$any_newer" != "true" ]]; then
        exit 0
      fi

      # Ask once per directory (covers split packages)
      if ! confirm_action "$dir_name: install update" "installed" "local $local_ver"; then
        log_info "[$dir_name] Skipped by user"
        exit 0
      fi

      # If artifacts already exist for the needed installed pkgs, install directly.
      local -a want_files=()
      while IFS= read -r p; do
        [[ -n "$p" ]] && want_files+=("$p")
      done < <(artifact_paths_for_installed_pkgs "$pkgver" "$pkgrel" <<<"$(printf "%s\n" "${installed_pkgs[@]}")")

      if [[ ${#want_files[@]} -gt 0 ]] && all_files_exist "${want_files[@]}"; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log_info "[$dir_name] DRY-RUN: would install existing artifacts: ${want_files[*]}"
          exit 0
        fi

        if ! install_files "${want_files[@]}"; then
          log_warn "[$dir_name] Install failed (existing artifacts)."
          exit 1
        fi

        log_ok "[$dir_name] Installed existing artifacts."
        exit 0
      fi

      # Otherwise build, then install the produced artifacts for the installed subset.
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[$dir_name] DRY-RUN: would build (no matching artifacts found) then install"
        exit 0
      fi

      if [[ "$CLEAN" == "true" ]]; then
        rm -rf "$dir/src" "$dir/pkg" "$dir"/*.pkg.tar.* >/dev/null 2>&1 || true
      fi

      if ! build_in_dir >"$dir/.install-updates.build.log" 2>&1; then
        log_warn "[$dir_name] Build failed (see $dir/.install-updates.build.log)"
        exit 1
      fi

      # Recompute artifact list post-build and install
      want_files=()
      while IFS= read -r p; do
        [[ -n "$p" ]] && want_files+=("$p")
      done < <(artifact_paths_for_installed_pkgs "$pkgver" "$pkgrel" <<<"$(printf "%s\n" "${installed_pkgs[@]}")")

      if [[ ${#want_files[@]} -eq 0 ]] || ! all_files_exist "${want_files[@]}"; then
        log_warn "[$dir_name] Build succeeded but expected artifacts not found for installed packages"
        exit 1
      fi

      if ! install_files "${want_files[@]}"; then
        log_warn "[$dir_name] Install failed after build."
        exit 1
      fi

      log_ok "[$dir_name] Built + installed update."
      exit 0
    )

    case "$?" in
      0) ((updated++)) ;;
      *) ((failed++)); log_warn "Continuing after failure in: ${dir##*/}" ;;
    esac
  done

  log_info "Checked: $checked | Updated/acted: $updated | Failed: $failed"
  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
