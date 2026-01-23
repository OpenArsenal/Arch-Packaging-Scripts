#!/usr/bin/env bash
set -euo pipefail

# Update local PKGBUILD packages that are already installed on the system.
# - If installed version differs from local PKGBUILD version -> install the local version.
# - If the correct package file is already built -> pacman -U it.
# - Otherwise -> makepkg, then pacman -U the resulting artifact(s).
# - On failure -> warn and continue.

PROJECT_ROOT="${PROJECT_ROOT:-"$HOME/Projects/Packages"}"

log_info() { printf '[INFO] %s\n' "$*" >&2; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_ok()   { printf '[OK]   %s\n' "$*" >&2; }

is_installed() {
  local pkg="${1:?pkg}"
  pacman -Qq "$pkg" >/dev/null 2>&1
}

installed_version() {
  local pkg="${1:?pkg}"
  pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'
}

# Prints lines: "<pkgname>\t<pkgver-pkgrel>"
local_pkg_versions_from_srcinfo() {
  # Must be run inside the PKGBUILD directory.
  local src
  src="$(makepkg --printsrcinfo 2>/dev/null)" || return 1

  local ver rel
  ver="$(printf '%s\n' "$src" | awk -F' = ' '$1 ~ /^[[:space:]]*pkgver$/ {print $2; exit}')"
  rel="$(printf '%s\n' "$src" | awk -F' = ' '$1 ~ /^[[:space:]]*pkgrel$/ {print $2; exit}')"
  [[ -n "$ver" && -n "$rel" ]] || return 1

  # Gather all pkgname entries (handles split packages)
  printf '%s\n' "$src" \
    | awk -F' = ' '$1 ~ /^[[:space:]]*pkgname$/ {print $2}' \
    | while IFS= read -r name; do
        [[ -n "$name" ]] && printf '%s\t%s-%s\n' "$name" "$ver" "$rel"
      done
}

# Finds built artifacts for the *current* PKGBUILD (paths, one per line).
expected_artifacts() {
  makepkg --packagelist 2>/dev/null || return 1
}

install_artifacts() {
  # Installs all artifacts passed as args (expects absolute/relative paths).
  sudo pacman -U --noconfirm --needed -- "$@"
}

build_pkg() {
  # Build only (no install). We install explicitly via pacman -U after.
  # -s: resolve deps, -f: overwrite existing packages
  makepkg -sf --noconfirm --needed
}

process_dir() {
  local dir="${1:?dir}"
  local pkgb="$dir/PKGBUILD"
  [[ -f "$pkgb" ]] || return 0

  (
    cd "$dir"

    # Optional: refresh sums if you want. If it fails, we still continue.
    if command -v updpkgsums >/dev/null 2>&1; then
      updpkgsums >/dev/null 2>&1 || log_warn "updpkgsums failed in $dir (continuing)"
    fi

    local lines
    lines="$(local_pkg_versions_from_srcinfo)" || {
      log_warn "Could not parse srcinfo in $dir (skipping)"
      exit 0
    }

    # Only act if at least one of the PKGBUILD's pkgname(s) is installed,
    # and any installed one differs from local version.
    local need_action="false"
    local any_installed="false"

    while IFS=$'\t' read -r name local_verrel; do
      [[ -n "$name" ]] || continue
      if is_installed "$name"; then
        any_installed="true"
        local installed_verrel
        installed_verrel="$(installed_version "$name" || true)"
        if [[ -n "$installed_verrel" && "$installed_verrel" != "$local_verrel" ]]; then
          need_action="true"
          log_info "$name: installed=$installed_verrel local=$local_verrel -> update needed"
        else
          log_ok "$name: up-to-date ($local_verrel)"
        fi
      fi
    done <<<"$lines"

    if [[ "$any_installed" != "true" ]]; then
      exit 0
    fi

    if [[ "$need_action" != "true" ]]; then
      exit 0
    fi

    # If update is needed: prefer installing already-built correct artifacts.
    local -a artifacts=()
    local a=""
    while IFS= read -r a; do
      [[ -n "$a" ]] && artifacts+=("$a")
    done < <(expected_artifacts || true)

    local all_exist="true"
    if [[ ${#artifacts[@]} -eq 0 ]]; then
      all_exist="false"
    else
      for a in "${artifacts[@]}"; do
        [[ -f "$a" ]] || { all_exist="false"; break; }
      done
    fi

    if [[ "$all_exist" == "true" ]]; then
      log_info "Installing already-built artifacts in $dir"
      install_artifacts "${artifacts[@]}" || {
        log_warn "Install failed (already-built) in $dir"
        exit 0
      }
      log_ok "Installed from existing build: $dir"
      exit 0
    fi

    log_info "Building (missing correct artifacts) in $dir"
    if ! build_pkg >".auto-update.local-build.log" 2>&1; then
      log_warn "Build failed in $dir (see $dir/.auto-update.local-build.log)"
      exit 0
    fi

    artifacts=()
    while IFS= read -r a; do
      [[ -n "$a" ]] && artifacts+=("$a")
    done < <(expected_artifacts || true)

    if [[ ${#artifacts[@]} -eq 0 ]]; then
      log_warn "Build succeeded but no artifacts found via --packagelist in $dir"
      exit 0
    fi

    log_info "Installing freshly-built artifacts in $dir"
    install_artifacts "${artifacts[@]}" || {
      log_warn "Install failed (fresh build) in $dir"
      exit 0
    }

    log_ok "Built + installed: $dir"
  ) || true
}

main() {
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
  log_info "PROJECT_ROOT: $PROJECT_ROOT"

  local d=""
  for d in "$PROJECT_ROOT"/*; do
    [[ -d "$d" ]] || continue
    process_dir "$d"
  done

  log_ok "Done."
}

main "$@"
