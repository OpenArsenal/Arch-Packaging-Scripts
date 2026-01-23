#!/usr/bin/env bash
set -uo pipefail

# Update/build AUR-style PKGBUILDs from a single source of truth: feeds.json
#
# Supports both schemaVersion 1 (nested .feed) and schemaVersion 2 (flat structure)
#
# Examples:
#   ./scripts/update-pkg.sh --dry-run
#   ./scripts/update-pkg.sh --dry-run --strict
#   ./scripts/update-pkg.sh --list
#   ./scripts/update-pkg.sh github-cli ktailctl
#   ./scripts/update-pkg.sh --no-build
#   ./scripts/update-pkg.sh --build-only
#
# Optional:
#   export GITHUB_TOKEN="..."  # reduces GitHub rate-limit pain

declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2; }

declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
declare -r DEFAULT_FEEDS_JSON="$PROJECT_ROOT/feeds.json"
declare -r PACKAGE_UPDATE_BOT_USER_AGENT="Package-Update-Bot/1.0"
declare -r FETCH_TIMEOUT=30

fetch() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  
  if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
    curl -sSL --max-time "$FETCH_TIMEOUT" \
      -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null
    return $?
  fi

  curl -sSL --max-time "$FETCH_TIMEOUT" -A "$PACKAGE_UPDATE_BOT_USER_AGENT" "$url" 2>/dev/null
}

check_deps() {
  local -a missing=()

  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v makepkg >/dev/null 2>&1 || missing+=("base-devel")
  command -v updpkgsums >/dev/null 2>&1 || missing+=("pacman-contrib")
  command -v vercmp >/dev/null 2>&1 || true
  command -v python3 >/dev/null 2>&1 || missing+=("python")
  command -v xmllint >/dev/null 2>&1 || missing+=("libxml2")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    log_info "Install with: sudo pacman -S ${missing[*]}"
    exit 1
  fi
}

# -------- feeds.json helpers (schema-aware) --------

feeds_json_get_schema_version() {
  local feeds_json="${1:-}"
  [[ -z "$feeds_json" ]] && echo "1" && return 0
  jq -r '.schemaVersion // 1' "$feeds_json"
}

feeds_json_list_packages() {
  local feeds_json="${1:-}"
  [[ -z "$feeds_json" ]] && return 0
  jq -r '.packages[]?.name // empty' "$feeds_json" | sed '/^$/d'
}

feeds_json_get_field() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local field="${3:-}"
  [[ -z "$feeds_json" || -z "$pkg" || -z "$field" ]] && return 0
  
  local schema_version
  schema_version="$(feeds_json_get_schema_version "$feeds_json")"
  
  if [[ "$schema_version" == "1" ]]; then
    # Schema v1: fields nested under .feed
    jq -r --arg name "$pkg" --arg field "$field" '
      (.packages[] | select(.name==$name) | .feed[$field]) // empty
    ' "$feeds_json"
  else
    # Schema v2: fields directly on package object
    jq -r --arg name "$pkg" --arg field "$field" '
      (.packages[] | select(.name==$name) | .[$field]) // empty
    ' "$feeds_json"
  fi
}

# Returns 0 if feeds.json contains an entry for pkg
feeds_json_has_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [[ -z "$feeds_json" || -z "$pkg" ]] && return 1
  jq -e --arg name "$pkg" '.packages[] | select(.name==$name) | .name' "$feeds_json" >/dev/null 2>&1
}

# -------- version normalization / extraction --------

trim() {
  local s="${1:-}"
  echo "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

normalize_basic_tag_to_version() {
  # Accept either:
  #  - a single arg (preferred), or
  #  - stdin (when used in a pipe)
  local raw=""

  if [[ $# -gt 0 ]]; then
    raw="${1:-}"
  else
    # Read everything from stdin (not just one line) to be safe
    raw="$(cat || true)"
  fi

  # Normalize whitespace/newlines (common from APIs)
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw#refs/tags/}"
  raw="${raw#v}"
  raw="${raw#V}"

  printf '%s\n' "$raw"
}

apply_version_regex() {
  local raw="${1:-}"
  local version_regex="${2:-}"
  local version_format="${3:-}"
  [[ -z "$raw" || -z "$version_regex" || -z "$version_format" ]] && return 2

  python3 - "$raw" "$version_regex" "$version_format" <<'PY'
import re
import sys

raw = sys.argv[1]
rx = sys.argv[2]
fmt = sys.argv[3]

m = re.match(rx, raw)
if not m:
  sys.exit(2)

out = fmt
for i in range(1, 10):
  token = f"${i}"
  if token in out:
    val = m.group(i) if i <= m.lastindex else ""
    out = out.replace(token, val or "")
print(out)
PY
}

pick_max_version_list() {
  local -a versions=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && versions+=("$line")
  done

  if [[ ${#versions[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  if command -v vercmp >/dev/null 2>&1; then
    local max="${versions[0]}"
    local v
    for v in "${versions[@]:1}"; do
      if [[ "$(vercmp "$v" "$max")" -gt 0 ]]; then
        max="$v"
      fi
    done
    echo "$max"
    return 0
  fi

  printf "%s\n" "${versions[@]}" | sort -V | tail -n 1
}

# -------- upstream version fetchers --------

github_latest_release_tag() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  [[ -z "$repo" ]] && return 0

  local url=""
  case "$channel" in
    stable)
      url="https://api.github.com/repos/${repo}/releases/latest"
      ;;
    prerelease|any|*)
      url="https://api.github.com/repos/${repo}/releases?per_page=30"
      ;;
  esac

  local response
  response="$(fetch "$url")" || return 1
  
  case "$channel" in
    stable)
      echo "$response" | jq -r '.tag_name // empty'
      ;;
    prerelease)
      echo "$response" | jq -r '[.[] | select(.prerelease==true)][0].tag_name // empty'
      ;;
    any|*)
      echo "$response" | jq -r '.[0].tag_name // empty'
      ;;
  esac
}

github_latest_release_tag_filtered() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  local tag_regex="${3:-}"
  [[ -z "$repo" || -z "$tag_regex" ]] && return 1

  local releases
  releases="$(fetch "https://api.github.com/repos/${repo}/releases?per_page=50")" || return 1

  case "$channel" in
    stable)
      echo "$releases" | jq -r --arg re "$tag_regex" '
        [.[] | select(.prerelease==false) | select(.tag_name | test($re))][0].tag_name // empty
      '
      ;;
    prerelease)
      echo "$releases" | jq -r --arg re "$tag_regex" '
        [.[] | select(.prerelease==true) | select(.tag_name | test($re))][0].tag_name // empty
      '
      ;;
    any|*)
      echo "$releases" | jq -r --arg re "$tag_regex" '
        [.[] | select(.tag_name | test($re))][0].tag_name // empty
      '
      ;;
  esac
}

github_tags_filtered_versions() {
  local repo="${1:-}"
  local tag_regex="${2:-}"
  local version_regex="${3:-}"
  local version_format="${4:-}"
  [[ -z "$repo" ]] && return 0

  local tags_json
  tags_json="$(fetch "https://api.github.com/repos/${repo}/tags?per_page=100")" || return 1

  echo "$tags_json" | jq -r --arg re "$tag_regex" '
    .[] | .name | select(test($re))
  ' | while IFS= read -r tag; do
    local raw
    raw="$(normalize_basic_tag_to_version "$tag")"

    if [[ -n "$version_regex" && -n "$version_format" ]]; then
      apply_version_regex "$raw" "$version_regex" "$version_format" 2>/dev/null || true
    else
      echo "$raw"
    fi
  done
}

get_chrome_version_json() {
  local channel="${1:-stable}"
  local encoded_filter="endtime%3Dnone%2Cfraction%3E%3D0.5"
  local encoded_order="version%20desc"
  local url="https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/${channel}/versions/all/releases?filter=${encoded_filter}&order_by=${encoded_order}"

  local response
  response="$(fetch "$url")" || return 1
  echo "$response" | jq -r '.releases[0].version // empty'
}

get_edge_version() {
  local repomd_url="${1:-}"
  [[ -z "$repomd_url" ]] && return 1
  
  local base="${repomd_url%/repodata/repomd.xml}"

  local primary_href
  primary_href="$(fetch "$repomd_url" \
    | xmllint --xpath 'string(//*[local-name()="data" and @type="primary"]/*[local-name()="location"]/@href)' - 2>/dev/null)"

  [[ -z "$primary_href" ]] && return 1

  fetch "${base}/${primary_href}" \
    | gunzip 2>/dev/null \
    | xmllint --xpath "string((//*[local-name()='entry'][@name='microsoft-edge-stable']/@ver)[last()])" - 2>/dev/null
}

get_vscode_version() {
  normalize_basic_tag_to_version "$(github_latest_release_tag "microsoft/vscode" "stable")"
}

get_1password_cli2_version_json() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  
  local response
  response="$(fetch "$url")" || return 1
  echo "$response" | jq -r '.version // empty'
}

get_1password_linux_stable_version() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  
  local html
  html="$(fetch "$url")" || return 1

  echo "$html" \
    | tr '\n' ' ' \
    | sed -n -E 's/.*Updated to ([0-9]+(\.[0-9]+)+([\-][0-9]+)?).*/\1/p' \
    | head -1
}

get_lmstudio_version() {
  local html
  html="$(curl -sSL --max-time 5 "https://lmstudio.ai/download" 2>/dev/null)" || return 1

  printf '%s' "$html" | python3 - <<'PY' 2>/dev/null || true
import re, sys
html = sys.stdin.read()
m = re.search(r'\\"linux\\":\{\\"x64\\":\{\\"version\\":\\"([0-9.]+)\\",\\"build\\":\\"([0-9]+)\\"', html)
if not m:
  sys.exit(2)
print(f"{m.group(1)}.{m.group(2)}")
PY
}

fetch_upstream_version_for_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [[ -z "$feeds_json" || -z "$pkg" ]] && return 0

  local type repo channel url tag_regex version_regex version_format

  type="$(feeds_json_get_field "$feeds_json" "$pkg" "type")"
  repo="$(feeds_json_get_field "$feeds_json" "$pkg" "repo")"
  channel="$(feeds_json_get_field "$feeds_json" "$pkg" "channel")"
  url="$(feeds_json_get_field "$feeds_json" "$pkg" "url")"
  tag_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "tagRegex")"
  version_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "versionRegex")"
  version_format="$(feeds_json_get_field "$feeds_json" "$pkg" "versionFormat")"

  [[ -z "$channel" ]] && channel="stable"

  log_debug "Package: $pkg | Type: $type | Repo: $repo | Channel: $channel"

  case "$type" in
    github-release)
      local tag
      tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag "$repo" "$channel" 2>/dev/null)")"
      if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
        apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
      else
        echo "$tag"
      fi
      ;;
    github-release-filtered)
      local tag
      tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag_filtered "$repo" "$channel" "$tag_regex" 2>/dev/null)")"
      if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
        apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
      else
        echo "$tag"
      fi
      ;;
    github-tags-filtered)
      local versions
      versions="$(github_tags_filtered_versions "$repo" "$tag_regex" "$version_regex" "$version_format" 2>/dev/null)"
      pick_max_version_list <<<"$versions"
      ;;
    vcs)
      if [[ -n "$repo" ]]; then
        local tag
        tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag "$repo" "stable" 2>/dev/null)")"
        if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
          apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
        else
          echo "$tag"
        fi
      else
        echo ""
      fi
      ;;
    chrome)
      get_chrome_version_json "$channel" 2>/dev/null
      ;;
    edge)
      get_edge_version "$url" 2>/dev/null
      ;;
    vscode)
      get_vscode_version 2>/dev/null
      ;;
    1password-cli2)
      get_1password_cli2_version_json "$url" 2>/dev/null
      ;;
    1password-linux-stable)
      get_1password_linux_stable_version "$url" 2>/dev/null
      ;;
    lmstudio)
      get_lmstudio_version 2>/dev/null
      ;;
    manual)
      echo ""
      ;;
    "")
      log_debug "Empty type for $pkg, treating as manual"
      echo ""
      ;;
    *)
      log_warning "Unknown feed type '$type' for $pkg (treating as manual)"
      echo ""
      ;;
  esac
}

# -------- PKGBUILD helpers --------

get_current_pkgver() {
  local pkgbuild_path="${1:-}"
  [[ ! -f "$pkgbuild_path" ]] && echo "" && return 0
  grep -E '^pkgver=' "$pkgbuild_path" | head -1 | cut -d'=' -f2- \
    | sed "s/^[\"']*//; s/[\"']*$//"
}

is_vcs_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local type
  type="$(feeds_json_get_field "$feeds_json" "$pkg" "type")"
  [[ "$type" == "vcs" ]] && return 0
  [[ "$pkg" =~ -(git|hg|svn|bzr)$ ]] && return 0
  return 1
}

update_pkgbuild_version() {
  local pkgbuild_path="${1:-}"
  local new_version="${2:-}"

  local clean_version
  clean_version="$(trim "$new_version")"
  clean_version="${clean_version//-/_}"

  cp "$pkgbuild_path" "${pkgbuild_path}.backup"

  sed -i -E "s/^pkgver=.*/pkgver='${clean_version//&/\\&}'/" "$pkgbuild_path"
  sed -i -E "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild_path"
}

update_checksums() {
  local pkg_dir="${1:-}"
  ( cd "$pkg_dir" && updpkgsums ) >/dev/null 2>&1
}

build_package() {
  local pkg_dir="${1:-}"
  ( cd "$pkg_dir" && makepkg -scf --noconfirm --needed )
}

# -------- reporting / comparison --------

status_for() {
  local current="${1:-}"
  local upstream="${2:-}"
  local has_feed="${3:-}"
  local is_vcs="${4:-}"
  local is_manual="${5:-}"

  if [[ "$has_feed" != "true" ]]; then
    echo "NO_FEED"
    return 0
  fi

  if [[ "$is_manual" == "true" ]]; then
    echo "MANUAL"
    return 0
  fi

  if [[ "$is_vcs" == "true" ]]; then
    echo "SKIP"
    return 0
  fi

  if [[ -z "$upstream" ]]; then
    echo "n/a"
    return 0
  fi

  if [[ -z "$current" ]]; then
    echo "UPDATE"
    return 0
  fi

  if command -v vercmp >/dev/null 2>&1; then
    local cmp
    cmp="$(vercmp "$upstream" "$current")"
    if [[ "$cmp" -gt 0 ]]; then
      echo "UPDATE"
    else
      echo "OK"
    fi
    return 0
  fi

  if [[ "$current" == "$upstream" ]]; then
    echo "OK"
  else
    echo "UPDATE"
  fi
}

print_table_header() {
  printf "\n%-28s %-18s %-18s %-10s\n" "PACKAGE" "CURRENT" "UPSTREAM" "STATUS"
  printf "%-28s %-18s %-18s %-10s\n" \
    "----------------------------" "------------------" "------------------" "----------"
}

# -------- CLI parsing --------

declare FEEDS_JSON="$DEFAULT_FEEDS_JSON"
declare DRY_RUN="false"
declare NO_BUILD="false"
declare BUILD_ONLY="false"
declare CLEAN_BUILD="false"
declare STRICT="false"
declare LIST_ONLY="false"
declare DEBUG="false"
declare -a SELECTED=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [PACKAGES...]

OPTIONS:
  --feeds <path>        Path to feeds.json (default: $DEFAULT_FEEDS_JSON)
  --dry-run             Print CURRENT vs UPSTREAM and exit (no changes)
  --list                List packages from feeds.json and exit
  --no-build            Update PKGBUILD/updpkgsums but skip makepkg
  --build-only          Only build; do not version-bump
  --clean               Remove src/pkg/*.pkg.tar.* before building
  --strict              Exit non-zero if feeds.json entries are missing directories/PKGBUILDs
  --debug               Extra diagnostics (shows feed types, repos, API calls)
  -h, --help            Show this help

Examples:
  $0 --dry-run
  $0 --dry-run --debug
  $0 --dry-run --strict
  $0 github-cli ktailctl
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feeds)
      FEEDS_JSON="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --no-build) NO_BUILD="true"; shift ;;
    --build-only) BUILD_ONLY="true"; shift ;;
    --clean) CLEAN_BUILD="true"; shift ;;
    --strict) STRICT="true"; shift ;;
    --list) LIST_ONLY="true"; shift ;;
    --debug) DEBUG="true"; shift ;;
    -h|--help) show_usage; exit 0 ;;
    -*)
      log_error "Unknown option: $1"
      show_usage
      exit 1
      ;;
    *)
      SELECTED+=("$1")
      shift
      ;;
  esac
done

main() {
  [[ ! -f "$FEEDS_JSON" ]] && log_error "feeds.json not found: $FEEDS_JSON" && exit 1

  if [[ "$DRY_RUN" != "true" ]]; then
    check_deps
  else
    # still need jq/curl for dry-run
    check_deps
  fi

  local schema_version
  schema_version="$(feeds_json_get_schema_version "$FEEDS_JSON")"
  log_debug "Schema version: $schema_version"

  if [[ "$LIST_ONLY" == "true" ]]; then
    feeds_json_list_packages "$FEEDS_JSON" | sort
    exit 0
  fi

  local -a pkgs=()
  if [[ ${#SELECTED[@]} -gt 0 ]]; then
    pkgs=("${SELECTED[@]}")
  else
    while IFS= read -r p; do
      [[ -n "$p" ]] && pkgs+=("$p")
    done < <(feeds_json_list_packages "$FEEDS_JSON")
  fi

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    log_error "No packages found in feeds.json."
    exit 1
  fi

  if [[ "$DEBUG" == "true" ]]; then
    log_info "Project root: $PROJECT_ROOT"
    log_info "Feeds: $FEEDS_JSON (schemaVersion=$schema_version)"
    log_info "Packages to process (${#pkgs[@]}): ${pkgs[*]}"
  fi

  # Validate: every feeds entry must exist on disk
  local -a missing_dirs=()
  local -a missing_pkgbuilds=()

  local pkg
  for pkg in "${pkgs[@]}"; do
    if ! feeds_json_has_pkg "$FEEDS_JSON" "$pkg"; then
      log_error "Package '$pkg' not present in feeds.json"
      continue
    fi

    local dir="$PROJECT_ROOT/$pkg"
    local pkgb="$dir/PKGBUILD"
    [[ ! -d "$dir" ]] && missing_dirs+=("$pkg")
    [[ -d "$dir" && ! -f "$pkgb" ]] && missing_pkgbuilds+=("$pkg")
  done

  if [[ ${#missing_dirs[@]} -gt 0 ]]; then
    log_warning "Missing package directories: ${missing_dirs[*]}"
  fi
  if [[ ${#missing_pkgbuilds[@]} -gt 0 ]]; then
    log_warning "Missing PKGBUILD files: ${missing_pkgbuilds[*]}"
  fi
  if [[ "$STRICT" == "true" && ( ${#missing_dirs[@]} -gt 0 || ${#missing_pkgbuilds[@]} -gt 0 ) ]]; then
    log_error "--strict set; failing due to missing dirs/PKGBUILDs."
    exit 1
  fi

  print_table_header

  local -a failed=()
  local updated=0

  for pkg in "${pkgs[@]}"; do
    local has_feed="false"
    feeds_json_has_pkg "$FEEDS_JSON" "$pkg" && has_feed="true"

    local type
    type="$(feeds_json_get_field "$FEEDS_JSON" "$pkg" "type")"
    local is_manual="false"
    [[ "$type" == "manual" ]] && is_manual="true"

    local dir="$PROJECT_ROOT/$pkg"
    local pkgb="$dir/PKGBUILD"

    local current upstream status
    current="$(get_current_pkgver "$pkgb")"
    upstream=""

    if [[ "$has_feed" == "true" ]]; then
      upstream="$(trim "$(fetch_upstream_version_for_pkg "$FEEDS_JSON" "$pkg")")"
    fi

    local is_vcs="false"
    if is_vcs_pkg "$FEEDS_JSON" "$pkg"; then
      is_vcs="true"
    fi

    status="$(status_for "$current" "$upstream" "$has_feed" "$is_vcs" "$is_manual")"

    # Render upstream cell with VCS context
    local upstream_cell="$upstream"
    if [[ "$is_manual" == "true" ]]; then
      upstream_cell="n/a"
    elif [[ "$is_vcs" == "true" ]]; then
      if [[ -n "$upstream" ]]; then
        upstream_cell="${upstream} (stable)"
      else
        upstream_cell="VCS"
      fi
    elif [[ -z "$upstream_cell" ]]; then
      upstream_cell="n/a"
    fi

    printf "%-28s %-18s %-18s %-10s\n" \
      "$pkg" \
      "${current:-n/a}" \
      "$upstream_cell" \
      "$status"

    if [[ "$DRY_RUN" == "true" ]]; then
      continue
    fi

    # Actual update/build logic
    if [[ ! -d "$dir" || ! -f "$pkgb" ]]; then
      failed+=("$pkg")
      continue
    fi

    if [[ "$BUILD_ONLY" == "true" ]]; then
      if [[ "$CLEAN_BUILD" == "true" ]]; then
        rm -rf "$dir/src" "$dir/pkg" "$dir"/*.pkg.tar.* >/dev/null 2>&1 || true
      fi
      if ! build_package "$dir" >/dev/null 2>&1; then
        failed+=("$pkg")
      fi
      continue
    fi

    if [[ "$status" == "UPDATE" && "$is_vcs" != "true" && "$is_manual" != "true" && -n "$upstream" ]]; then
      update_pkgbuild_version "$pkgb" "$upstream" || { failed+=("$pkg"); continue; }
      update_checksums "$dir" || true
      ((updated++))
    fi

    if [[ "$NO_BUILD" != "true" ]]; then
      if [[ "$CLEAN_BUILD" == "true" ]]; then
        rm -rf "$dir/src" "$dir/pkg" "$dir"/*.pkg.tar.* >/dev/null 2>&1 || true
      fi
      if ! build_package "$dir" >/dev/null 2>&1; then
        failed+=("$pkg")
      fi
    fi
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    echo
    log_success "Dry-run complete."
    return 0
  fi

  echo
  log_info "Updated PKGBUILDs: $updated"
  if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "Failed: ${failed[*]}"
    exit 1
  fi
  log_success "All done."
}

main "$@"