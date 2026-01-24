#!/usr/bin/env bash
set -uo pipefail

# cleanup-repo.sh - Repository maintenance and cleanup
#
# Wrapper around repo-mgmt.sh cleanup with additional intelligence
# for orphan detection and selective cleanup.
#
# Examples:
#   ./cleanup-repo.sh                       # Interactive cleanup
#   ./cleanup-repo.sh --auto --keep-n 2     # Auto cleanup, keep 2 versions
#   ./cleanup-repo.sh --orphans-only        # Only remove orphans

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Options
# ============================================================================

declare AUTO_MODE="false"
declare KEEP_N=2
declare ORPHANS_ONLY="false"
declare OLD_VERSIONS_ONLY="false"
declare DRY_RUN="false"

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Clean up local repository by removing old versions and orphaned packages.

OPTIONS:
  --auto                  Non-interactive mode
  --keep-n <N>            Keep N most recent versions (default: $KEEP_N)
  --orphans-only          Only remove packages not in feeds.json
  --old-versions-only     Only remove old versions
  --dry-run               Show what would be removed
  -h, --help              Show this help

EXAMPLES:
  # Interactive cleanup (asks before removing)
  $0

  # Auto cleanup, keep 2 versions
  $0 --auto --keep-n 2

  # Remove orphans only
  $0 --orphans-only

  # See what would be removed
  $0 --dry-run
EOF
}

# ============================================================================
# Orphan Detection
# ============================================================================

find_orphans() {
  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    return 1
  fi
  
  if [[ ! -f "$REPO_DB" ]]; then
    log_error "Repository database not found: $REPO_DB"
    return 1
  fi
  
  # Get packages from feeds.json
  local -a feed_pkgs=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && feed_pkgs+=("$name")
  done < <(jq -r '.packages[]?.name // empty' "$FEEDS_JSON" 2>/dev/null | sort -u)
  
  # Get packages from repo
  local -a repo_pkgs=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && repo_pkgs+=("$name")
  done < <(bsdtar -xOf "$REPO_DB" 2>/dev/null | awk '/^%NAME%$/ { getline; print }' | sort -u)
  
  # Find orphans (in repo but not in feeds.json)
  local -a orphans=()
  local pkg=""
  
  for pkg in "${repo_pkgs[@]}"; do
    if [[ ! " ${feed_pkgs[*]} " =~ " ${pkg} " ]]; then
      orphans+=("$pkg")
    fi
  done
  
  printf "%s\n" "${orphans[@]}"
}

# ============================================================================
# Old Version Detection
# ============================================================================

find_old_versions() {
  local keep_n="$1"
  
  if [[ ! -f "$REPO_DB" ]]; then
    log_error "Repository database not found: $REPO_DB"
    return 1
  fi
  
  # Get unique package names
  local -a pkgnames=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && pkgnames+=("$name")
  done < <(bsdtar -xOf "$REPO_DB" 2>/dev/null | awk '/^%NAME%$/ { getline; print }' | sort -u)
  
  # For each package, find versions to remove
  local pkg=""
  for pkg in "${pkgnames[@]}"; do
    # Get all versions sorted by modification time (newest first)
    local -a versions=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && versions+=("$f")
    done < <(find "$REPO_DIR" -maxdepth 1 -name "${pkg}-*.pkg.tar.*" -printf '%T@ %p\n' 2>/dev/null | \
             sort -rn | awk '{print $2}')
    
    local count=${#versions[@]}
    if [[ $count -le $keep_n ]]; then
      continue
    fi
    
    # Output files to remove (skip the first keep_n)
    local i=0
    for f in "${versions[@]}"; do
      ((i++))
      if [[ $i -gt $keep_n ]]; then
        echo "$f"
      fi
    done
  done
}

# ============================================================================
# Interactive Cleanup
# ============================================================================

confirm_removal() {
  local item_type="$1"
  local -a items=("${@:2}")
  
  if [[ ${#items[@]} -eq 0 ]]; then
    log_info "No $item_type to remove"
    return 1
  fi
  
  echo ""
  echo "The following $item_type will be removed:"
  echo ""
  
  for item in "${items[@]}"; do
    if [[ -f "$item" ]]; then
      # File path
      echo "  - $(basename "$item")"
    else
      # Package name
      echo "  - $item"
    fi
  done
  
  echo ""
  
  if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "Auto mode: proceeding with removal"
    return 0
  fi
  
  local response=""
  read -p "Proceed with removal? [y/N]: " -n 1 -r response
  echo ""
  
  case "${response,,}" in
    y) return 0 ;;
    *) log_info "Removal cancelled"; return 1 ;;
  esac
}

# ============================================================================
# Cleanup Operations
# ============================================================================

cleanup_orphans() {
  log_info "Scanning for orphaned packages..."
  
  local -a orphans=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && orphans+=("$pkg")
  done < <(find_orphans)
  
  if [[ ${#orphans[@]} -eq 0 ]]; then
    log_success "No orphaned packages found"
    return 0
  fi
  
  if ! confirm_removal "orphaned packages" "${orphans[@]}"; then
    return 0
  fi
  
  # Remove via repo-mgmt
  local flags=()
  [[ "$DRY_RUN" == "true" ]] && flags+=(--dry-run)
  
  "$SCRIPT_DIR/repo-mgmt.sh" "${flags[@]}" remove "${orphans[@]}"
}

cleanup_old_versions() {
  log_info "Scanning for old package versions (keeping $KEEP_N)..."
  
  local -a old_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && old_files+=("$f")
  done < <(find_old_versions "$KEEP_N")
  
  if [[ ${#old_files[@]} -eq 0 ]]; then
    log_success "No old versions to remove"
    return 0
  fi
  
  if ! confirm_removal "old package versions" "${old_files[@]}"; then
    return 0
  fi
  
  # Remove files
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY-RUN: Would remove ${#old_files[@]} file(s)"
    return 0
  fi
  
  local removed=0
  local f=""
  
  for f in "${old_files[@]}"; do
    if rm -f "$f"; then
      log_debug "Removed: $(basename "$f")"
      ((removed++))
    else
      log_error "Failed to remove: $f"
    fi
  done
  
  if [[ $removed -gt 0 ]]; then
    log_success "Removed $removed old package file(s)"
    
    # Update database
    log_info "Updating repository database..."
    repo-add "$REPO_DB" >/dev/null 2>&1
  fi
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) AUTO_MODE="true"; shift ;;
      --keep-n) KEEP_N="${2:?missing count}"; shift 2 ;;
      --orphans-only) ORPHANS_ONLY="true"; shift ;;
      --old-versions-only) OLD_VERSIONS_ONLY="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) show_usage; exit 0 ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
      *)
        log_error "Unexpected argument: $1"
        show_usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  
  log_info "Starting repository cleanup..."
  
  if [[ "$ORPHANS_ONLY" == "true" ]]; then
    cleanup_orphans
  elif [[ "$OLD_VERSIONS_ONLY" == "true" ]]; then
    cleanup_old_versions
  else
    # Both operations
    cleanup_old_versions
    echo ""
    cleanup_orphans
  fi
  
  log_success "Cleanup complete"
  
  # Show final status
  echo ""
  "$SCRIPT_DIR/repo-mgmt.sh" status
}

main "$@"