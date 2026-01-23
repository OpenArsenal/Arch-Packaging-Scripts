#!/usr/bin/env bash
set -uo pipefail

# Clone AUR packages into repo root, strip .git, and add/update feeds.json entries.
#
# Examples:
#   ./scripts/aur-import.sh https://aur.archlinux.org/google-chrome-canary-bin.git
#   ./scripts/aur-import.sh google-chrome-canary-bin
#   ./scripts/aur-import.sh 1password-wayland --type manual
#   ./scripts/aur-import.sh somepkg --infer
#
# Notes:
# - Default feed type is "manual" unless inference finds a GitHub repo.
# - The updater script treats feeds.json as authoritative.

declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
declare -r FEEDS_JSON_DEFAULT="$PROJECT_ROOT/feeds.json"

declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_deps() {
  local -a missing=()
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v python3 >/dev/null 2>&1 || missing+=("python")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    log_info "Install with: sudo pacman -S ${missing[*]}"
    exit 1
  fi
}

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <aur-url-or-name> [more...]

OPTIONS:
  --feeds <path>      feeds.json path (default: $FEEDS_JSON_DEFAULT)
  --type <type>       feed type (manual|vcs|github-release|github-release-filtered|github-tags-filtered|chrome|edge|vscode|1password-cli2|lmstudio)
  --repo <owner/repo> GitHub repo for github-* or vcs display (optional)
  --channel <name>    stable|any|prerelease (default: stable)
  --url <url>         for feed types that require explicit url (edge/1password-cli2/etc.)
  --infer             attempt to infer GitHub repo from PKGBUILD (recommended)
  --force             overwrite existing directory
  -h, --help          help

Examples:
  $0 google-chrome-canary-bin --infer
  $0 https://aur.archlinux.org/kurtosis-cli-bin.git --infer
  $0 somepkg --type manual
EOF
}

aur_url_from_name() {
  local name="$1"
  echo "https://aur.archlinux.org/${name}.git"
}

aur_name_from_url_or_name() {
  local input="$1"
  if [[ "$input" == http*://* ]]; then
    local base="${input##*/}"
    base="${base%.git}"
    echo "$base"
    return 0
  fi
  echo "$input"
}

infer_github_repo_from_pkgbuild() {
  local pkgbuild_path="$1"

  # Try url="https://github.com/owner/repo"
  local url_line
  url_line="$(grep -E '^[[:space:]]*url=' "$pkgbuild_path" | head -n 1 || true)"
  [[ -z "$url_line" ]] && echo "" && return 0

  python3 - "$url_line" <<'PY'
import re, sys
line = sys.argv[1]
m = re.search(r'https?://github\.com/([^/\s"]+)/([^/\s"]+)', line)
if not m:
  sys.exit(2)
print(f"{m.group(1)}/{m.group(2)}")
PY
}

ensure_feeds_json_exists() {
  local feeds_json="$1"
  if [[ -f "$feeds_json" ]]; then
    return 0
  fi

  log_warning "feeds.json not found; creating: $feeds_json"
  cat >"$feeds_json" <<'JSON'
{
  "schemaVersion": 2,
  "packages": []
}
JSON
}

feeds_upsert_pkg() {
  local feeds_json="$1"
  local name="$2"
  local type="$3"
  local repo="$4"
  local channel="$5"
  local url="$6"

  local obj
  if ! obj="$(
    jq -n \
      --arg name "$name" \
      --arg type "$type" \
      --arg repo "$repo" \
      --arg channel "$channel" \
      --arg url "$url" \
      '
      { name: $name, type: $type }
      + (if (($repo|length) > 0) then { repo: $repo } else {} end)
      + (if (($channel|length) > 0) then { channel: $channel } else {} end)
      + (if (($url|length) > 0) then { url: $url } else {} end)
      '
  )"; then
    log_error "Failed to construct feed JSON object for '$name'"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"

  if ! jq --arg name "$name" --argjson obj "$obj" '
    .schemaVersion = (.schemaVersion // 2)
    | .packages = (.packages // [])
    | if (.packages | map(.name) | index($name)) == null
      then .packages += [$obj]
      else .packages = (.packages | map(if .name == $name then $obj else . end))
      end
  ' "$feeds_json" >"$tmp"; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    log_error "Failed to write updated feeds.json for '$name'"
    return 1
  fi

  mv "$tmp" "$feeds_json"
  return 0
}

clone_aur_pkg() {
  local input="$1"
  local pkg="$2"
  local force="$3"

  local url
  if [[ "$input" == http*://* ]]; then
    url="$input"
  else
    url="$(aur_url_from_name "$input")"
  fi

  local dest="$PROJECT_ROOT/$pkg"

  if [[ -d "$dest" ]]; then
    if [[ "$force" == "true" ]]; then
      log_warning "Removing existing directory: $dest"
      rm -rf "$dest"
    else
      log_error "Directory already exists: $dest (use --force to overwrite)"
      return 1
    fi
  fi

  log_info "Cloning: $url -> $dest"
  git clone --depth 1 "$url" "$dest" >/dev/null 2>&1

  if [[ ! -d "$dest" ]]; then
    log_error "Clone failed: $url"
    return 1
  fi

  # Strip git metadata (you requested this).
  rm -rf "$dest/.git" >/dev/null 2>&1 || true

  if [[ ! -f "$dest/PKGBUILD" ]]; then
    log_error "No PKGBUILD found in $dest (unexpected for AUR)."
    return 1
  fi

  log_success "Imported AUR package into: $dest"
}

declare FEEDS_JSON="$FEEDS_JSON_DEFAULT"
declare TYPE=""
declare REPO=""
declare CHANNEL="stable"
declare URL=""
declare INFER="false"
declare FORCE="false"
declare -a INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feeds) FEEDS_JSON="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --infer) INFER="true"; shift ;;
    --force) FORCE="true"; shift ;;
    -h|--help) show_usage; exit 0 ;;
    -*)
      log_error "Unknown option: $1"
      show_usage
      exit 1
      ;;
    *)
      INPUTS+=("$1")
      shift
      ;;
  esac
done

main() {
  check_deps
  ensure_feeds_json_exists "$FEEDS_JSON"

  if [[ ${#INPUTS[@]} -eq 0 ]]; then
    show_usage
    exit 1
  fi

  local input pkg pkgdir pkgb inferred_repo inferred_type
  for input in "${INPUTS[@]}"; do
    pkg="$(aur_name_from_url_or_name "$input")"
    pkgdir="$PROJECT_ROOT/$pkg"
    pkgb="$pkgdir/PKGBUILD"

    clone_aur_pkg "$input" "$pkg" "$FORCE" || exit 1

    inferred_repo=""
    inferred_type="$TYPE"

    if [[ "$INFER" == "true" ]]; then
      inferred_repo="$(infer_github_repo_from_pkgbuild "$pkgb" 2>/dev/null || true)"

      if [[ -z "$inferred_type" ]]; then
        if [[ "$pkg" =~ -(git|hg|svn|bzr)$ ]]; then
          inferred_type="vcs"
        elif [[ -n "$inferred_repo" ]]; then
          inferred_type="github-release"
        else
          inferred_type="manual"
        fi
      fi
    fi

    # If caller explicitly set fields, they win.
    local final_type="${TYPE:-$inferred_type}"
    local final_repo="${REPO:-$inferred_repo}"
    local final_channel="$CHANNEL"
    local final_url="$URL"

    [[ -z "$final_type" ]] && final_type="manual"

    if feeds_upsert_pkg "$FEEDS_JSON" "$pkg" "$final_type" "$final_repo" "$final_channel" "$final_url"; then
      log_success "feeds.json updated: $pkg (type=$final_type${final_repo:+, repo=$final_repo})"
    else
      log_error "feeds.json update FAILED for $pkg"
      exit 1
    fi
  done

  log_success "Done."
  log_info "Next: ./scripts/update-pkg.sh --dry-run"
}

main "$@"
