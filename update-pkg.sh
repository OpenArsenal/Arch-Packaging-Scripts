#!/usr/bin/env bash
# Removed -e flag to prevent early exit on individual package failures
set -uo pipefail

# Package Update Script for Arch Linux
# Automatically updates PKGBUILDs and builds packages using latest upstream versions

# Color output for better visibility
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m' # No Color

# Script configuration
declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
declare -r PACKAGE_UPDATE_BOT_USER_AGENT="Package-Update-Bot/1.0"
declare -r FETCH_TIMEOUT=30

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Copy version fetching functions from debug-feeds.sh
fetch() {
    curl -sSL --max-time "$FETCH_TIMEOUT" -A "$PACKAGE_UPDATE_BOT_USER_AGENT" "$1"
}

get_1password_version() {
    local url="$1"
    fetch "$url" | \
        xmllint --xpath '//item[last()]/title' - 2>/dev/null | \
        sed 's/<[^>]*>//g' | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

get_github_version() {
    local url="$1"
    fetch "$url" | \
        xmlstarlet sel -N atom="http://www.w3.org/2005/Atom" \
            -t -v "//atom:entry[1]/atom:title" | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

get_vscode_version() {
    local api_url="https://api.github.com/repos/Microsoft/vscode/releases/latest"
    fetch "$api_url" | jq -r '.tag_name'
}

get_chrome_version_json() {
    local channel="$1"
    local encoded_filter="endtime%3Dnone%2Cfraction%3E%3D0.5"
    local encoded_order="version%20desc"
    local url="https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/${channel}/versions/all/releases?filter=${encoded_filter}&order_by=${encoded_order}"

    local response
    response=$(fetch "$url" 2>/dev/null)

    if [[ -z "$response" ]] || ! echo "$response" | jq . >/dev/null 2>&1; then
        log_error "Invalid JSON response from Chrome API for $channel"
        return 1
    fi

    echo "$response" | jq -r '.releases[0].version'
}

get_edge_version() {
    local repomd_url="$1"
    local base="${repomd_url%/repodata/repomd.xml}"

    local primary_href
    primary_href=$(fetch "$repomd_url" | \
        xmllint --xpath 'string(//*[local-name()="data" and @type="primary"]/*[local-name()="location"]/@href)' - 2>/dev/null)

    if [[ -z "$primary_href" ]]; then
        log_error "Could not find primary.xml location in repomd.xml"
        return 1
    fi

    local version
    version=$(fetch "${base}/${primary_href}" | gunzip 2>/dev/null | \
        xmllint --xpath "string((//*[local-name()='entry'][@name='microsoft-edge-stable']/@ver)[last()])" - 2>/dev/null)

    if [[ -z "$version" ]]; then
        log_error "Could not extract Edge version from primary.xml"
        return 1
    fi

    echo "$version"
}

get_1password_cli2_version_json() {
  local url="$1"

  local response
  response=$(fetch "$url" 2>/dev/null)

  if [[ -z "$response" ]] || ! echo "$response" | jq . >/dev/null 2>&1; then
    log_error "Invalid JSON response from 1Password CLI2 check endpoint"
    return 1
  fi

  echo "$response" | jq -r '.version // empty'
}

# Package configuration - PROPERLY DECLARE ASSOCIATIVE ARRAYS
# ["1password"]="1password"
declare -A FEED_TYPE=(
    ["1password-cli-bin"]="1password-cli2"
    ["github-cli"]="github"
    ["google-chrome-bin"]="chrome-stable"
    ["google-chrome-canary-bin"]="chrome-canary"
    ["microsoft-edge-stable-bin"]="edge"
    ["visual-studio-code-bin"]="vscode"
    ["vesktop"]="github"
    ["vesktop-git"]="github"
    ["vesktop-electron"]="github"
    ["vesktop-electron-git"]="github"
    ["ktailctl"]="github"
    ["kurtosis-cli-bin"]="github"
    ["talosctl-bin"]="github"
    ["omnictl-bin"]="github"
)

# ["1password-wayland"]="https://releases.1password.com/linux/index.xml"
declare -A FEED_URL=(
    ["1password-cli-bin"]="https://app-updates.agilebits.com/check/1/0/CLI2/en/0/N"
    ["github-cli"]="https://github.com/cli/cli/releases.atom"
    ["google-chrome-bin"]=""
    ["google-chrome-canary-bin"]=""
    ["microsoft-edge-stable-bin"]="https://packages.microsoft.com/yumrepos/edge/repodata/repomd.xml"
    ["visual-studio-code-bin"]=""
    ["vesktop"]="https://github.com/Vencord/Vesktop/releases.atom"
    ["vesktop-git"]="https://github.com/Vencord/Vesktop/tags.atom"
    ["vesktop-electron"]="https://github.com/Vencord/Vesktop/releases.atom"
    ["vesktop-electron-git"]="https://github.com/Vencord/Vesktop/tags.atom"
    ["ktailctl"]="https://github.com/f-koehler/KTailctl/releases.atom"
    ["kurtosis-cli-bin"]="https://github.com/kurtosis-tech/kurtosis/releases.atom"
    ["talosctl-bin"]="https://github.com/siderolabs/talos/releases.atom"
    ["omnictl-bin"]="https://github.com/siderolabs/omni/releases.atom"
)

# Debug function to show array contents
debug_arrays() {
    log_info "=== DEBUG: Array Contents ==="
    log_info "FEED_TYPE keys: ${!FEED_TYPE[*]}"
    log_info "FEED_URL keys: ${!FEED_URL[*]}"
    log_info "Number of packages: ${#FEED_TYPE[@]}"

    # Show each package and check if directory exists
    log_info "=== Package Directory Check ==="
    for pkg in "${!FEED_TYPE[@]}"; do
        local pkg_dir="$PROJECT_ROOT/$pkg"
        if [[ -d "$pkg_dir" ]]; then
            log_success "✓ $pkg -> $pkg_dir"
        else
            log_error "✗ $pkg -> $pkg_dir (MISSING)"
        fi
    done
    echo
}

# Fetch latest version for a package
fetch_latest_version() {
    local pkg="$1"

    # Check if package exists in our arrays
    if [[ -z "${FEED_TYPE[$pkg]:-}" ]]; then
        log_error "Package '$pkg' not found in FEED_TYPE array"
        return 1
    fi

    local type="${FEED_TYPE[$pkg]}"
    local url="${FEED_URL[$pkg]}"

    log_info "Fetching version for $pkg (type: $type)"

    case "$type" in
        "1password-cli2")
            get_1password_cli2_version_json "$url" 2>/dev/null || echo ""
            ;;
        "1password")
            get_1password_version "$url" 2>/dev/null || echo ""
            ;;
        "github")
            get_github_version "$url" 2>/dev/null || echo ""
            ;;
        "vscode")
            get_vscode_version 2>/dev/null || echo ""
            ;;
        "chrome-stable")
            get_chrome_version_json "stable" 2>/dev/null || echo ""
            ;;
        "chrome-canary")
            get_chrome_version_json "canary" 2>/dev/null || echo ""
            ;;
        "edge")
            get_edge_version "$url" 2>/dev/null || echo ""
            ;;
        *)
            log_error "Unknown feed type: $type"
            echo ""
            ;;
    esac
}

# Extract current version from PKGBUILD
get_current_pkgver() {
    local pkgbuild_path="$1"
    if [[ -f "$pkgbuild_path" ]]; then
        # More robust version extraction
        grep -E '^pkgver=' "$pkgbuild_path" | head -1 | cut -d'=' -f2- | sed 's/^[\"'\'']*//;s/[\"'\'']*$//'
    else
        echo ""
    fi
}

is_vcs_package() {
  local pkg="$1"
  local pkgbuild_path="$2"

  [[ "$pkg" =~ -(git|hg|svn|bzr)$ ]] && return 0
  grep -qE '^\s*pkgver\(\)' "$pkgbuild_path" && return 0
  grep -qE 'git\+' "$pkgbuild_path" && return 0
  return 1
}

# Update PKGBUILD with new version
update_pkgbuild_version() {
    local pkgbuild_path="$1"
    local new_version="$2"

    # Validate version format (no hyphens allowed in Arch pkgver)
    local clean_version="${new_version//-/_}"
    clean_version="${clean_version//$'\r'/}"
    clean_version="${clean_version%%$'\n'*}"
    clean_version="${clean_version//&/\\&}"

    # Create backup
    cp "$pkgbuild_path" "${pkgbuild_path}.backup"

    # Update pkgver and reset pkgrel to 1
    sed -i -E "s/^pkgver=.*/pkgver='$clean_version'/" "$pkgbuild_path"
    sed -i -E "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild_path"

    log_info "Updated $pkgbuild_path: pkgver=$clean_version, pkgrel=1"
}

# Update checksums using updpkgsums
update_checksums() {
    local pkg_dir="$1"
    local pkg_name="$(basename "$pkg_dir")"

    if ! command -v updpkgsums >/dev/null 2>&1; then
        log_error "updpkgsums not found. Install pacman-contrib: sudo pacman -S pacman-contrib"
        return 1
    fi

    log_info "Updating checksums for $pkg_name..."

    cd "$pkg_dir" || return 1
    if updpkgsums 2>/dev/null; then
        log_success "Updated checksums for $pkg_name"
        return 0
    else
        log_warning "Failed to update checksums for $pkg_name (this might be normal for VCS packages)"
        return 1
    fi
}

# Build package using makepkg
build_package() {
    local pkg_dir="$1"
    local pkg_name="$(basename "$pkg_dir")"

    cd "$pkg_dir" || return 1

    # Clean previous builds if requested
    if [[ "${CLEAN_BUILD:-false}" == "true" ]]; then
        log_info "Cleaning previous build directory for $pkg_name"
        rm -rf src pkg *.pkg.tar.*
    fi

    log_info "Building package: $pkg_name"

    # Build with clean environment, skip integrity checks if needed, and install dependencies
    # Using multiple flags for robustness:
    # -s: install missing dependencies
    # -c: clean up work files after build
    # -f: overwrite existing package
    # --noconfirm: don't ask for user input
    # --needed: don't reinstall up-to-date dependencies
    local log_file=".makepkg.log"
    if makepkg -scf --noconfirm --needed 2>&1 | tee "$log_file"; then
        log_success "Successfully built $pkg_name"

        # List built packages
        local built_packages
        built_packages=$(find . -maxdepth 1 -name "*.pkg.tar.*" -type f 2>/dev/null)
        if [[ -n "$built_packages" ]]; then
            log_info "Built packages:"
            echo "$built_packages" | while IFS= read -r pkg; do
                echo "  - $pkg"
            done
        fi
        return 0
    else
        log_error "Failed to build $pkg_name"
        log_error "makepkg failed. Last 120 lines:"
        tail -n 120 "$log_file" >&2
        return 1
    fi
}

# Main update function for a single package
update_package() {
    local pkg="$1"
    local pkg_dir="$PROJECT_ROOT/$pkg"
    local pkgbuild_path="$pkg_dir/PKGBUILD"

    log_info "Processing package: $pkg"
    log_info "Package directory: $pkg_dir"

    # Check if package directory exists
    if [[ ! -d "$pkg_dir" ]]; then
        log_error "Package directory not found: $pkg_dir"
        return 1
    fi

    # Check if PKGBUILD exists
    if [[ ! -f "$pkgbuild_path" ]]; then
        log_error "PKGBUILD not found: $pkgbuild_path"
        return 1
    fi

    if is_vcs_package "$pkg" "$pkgbuild_path"; then
        log_info "$pkg looks like a VCS package; skipping PKGBUILD version bump and just building."
        update_checksums "$pkg_dir" || true
        build_package "$pkg_dir"
        return $?
    fi

    # Fetch latest version - wrap in error handling
    log_info "Fetching latest version for $pkg..."
    local latest_version
    if ! latest_version=$(fetch_latest_version "$pkg"); then
        log_error "Failed to fetch latest version for $pkg"
        return 1
    fi

    if [[ -z "$latest_version" ]]; then
        log_error "Empty version returned for $pkg"
        return 1
    fi

    if [[ "$latest_version" =~ [[:space:]] ]]; then
        log_error "Latest version for $pkg contains whitespace/newlines. Got: '$latest_version'"
        return 1
    fi

    # Get current version
    local current_version
    current_version=$(get_current_pkgver "$pkgbuild_path")

    log_info "Current version: '$current_version'"
    log_info "Latest version: '$latest_version'"

    # Check if update is needed
    if [[ "$current_version" == "$latest_version" ]]; then
        log_success "$pkg is already up to date"

        # Still build if NO_BUILD is false and this isn't a dry run
        if [[ "${NO_BUILD:-false}" == "false" && "${DRY_RUN:-false}" == "false" ]]; then
            log_info "Building current version of $pkg"
            if build_package "$pkg_dir"; then
                log_success "Successfully built current version of $pkg"
                return 0
            else
                log_error "Failed to build current version of $pkg"
                return 1
            fi
        fi
        return 0
    fi

    # Don't actually update in dry run mode
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY RUN] Would update $pkg from $current_version to $latest_version"
        return 0
    fi

    # Update PKGBUILD
    log_info "Updating PKGBUILD for $pkg from $current_version to $latest_version"
    if ! update_pkgbuild_version "$pkgbuild_path" "$latest_version"; then
        log_error "Failed to update PKGBUILD for $pkg"
        return 1
    fi

    # Update checksums
    log_info "Updating checksums for $pkg..."
    if ! update_checksums "$pkg_dir"; then
        log_warning "Checksum update failed for $pkg, but continuing with build..."
    fi

    # Build package unless NO_BUILD is true
    if [[ "${NO_BUILD:-false}" == "false" ]]; then
        if build_package "$pkg_dir"; then
            log_success "Successfully updated and built $pkg"
            return 0
        else
            log_error "Failed to build $pkg after update"
            return 1
        fi
    else
        log_success "Successfully updated $pkg (build skipped)"
        return 0
    fi
}

# Display usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [PACKAGES...]

Update Arch Linux packages from their PKGBUILDs using latest upstream versions.

OPTIONS:
    -h, --help              Show this help message
    -l, --list              List all available packages
    --test                  Test mode - show packages and directories without doing anything
    -n, --dry-run          Show what would be updated without making changes
    -b, --build-only       Only build packages, don't update versions
    -c, --clean            Clean build directories before building
    --no-build             Update PKGBUILDs but don't build packages
    --debug                Show debug information

EXAMPLES:
    $0                      Update all packages
    $0 kurtosis-cli-bin     Update only kurtosis-cli-bin
    $0 --dry-run            Show what would be updated
    $0 --list               List all available packages
    $0 --debug              Show debug info about arrays

PACKAGES:
$(printf "    %s\n" "${!FEED_TYPE[@]}" | sort)

EOF
}

# Parse command line arguments
declare DRY_RUN=false
declare BUILD_ONLY=false
declare NO_BUILD=false
declare CLEAN_BUILD=false
declare DEBUG_MODE=false
declare -a SELECTED_PACKAGES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -l|--list)
            echo "Available packages:"
            printf "  %s\n" "${!FEED_TYPE[@]}" | sort
            exit 0
            ;;
        --test)
            log_info "TEST MODE: Showing what would be processed"
            debug_arrays
            log_info "Would process these packages:"
            for pkg in "${!FEED_TYPE[@]}"; do
                printf "  %s\n" "$pkg"
            done
            exit 0
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -b|--build-only)
            BUILD_ONLY=true
            shift
            ;;
        --no-build)
            NO_BUILD=true
            shift
            ;;
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            # Check if package exists
            if [[ -n "${FEED_TYPE[$1]:-}" ]]; then
                SELECTED_PACKAGES+=("$1")
            else
                log_error "Unknown package: $1"
                log_info "Available packages: ${!FEED_TYPE[*]}"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate conflicting options
if [[ "$BUILD_ONLY" == "true" && "$NO_BUILD" == "true" ]]; then
    log_error "Cannot use --build-only and --no-build together"
    exit 1
fi

# Show debug info if requested
if [[ "$DEBUG_MODE" == "true" ]]; then
    debug_arrays
fi

# Determine which packages to process - PROPER ARRAY HANDLING
declare -a PACKAGES_TO_PROCESS=()
if [[ ${#SELECTED_PACKAGES[@]} -eq 0 ]]; then
    # Use all packages from FEED_TYPE keys
    for pkg in "${!FEED_TYPE[@]}"; do
        PACKAGES_TO_PROCESS+=("$pkg")
    done
else
    # Use selected packages
    PACKAGES_TO_PROCESS=("${SELECTED_PACKAGES[@]}")
fi

# Check dependencies
check_dependencies() {
    local -a missing_deps=()

    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v xmllint >/dev/null 2>&1 || missing_deps+=("libxml2")
    command -v xmlstarlet >/dev/null 2>&1 || missing_deps+=("xmlstarlet")
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v makepkg >/dev/null 2>&1 || missing_deps+=("base-devel")
    command -v updpkgsums >/dev/null 2>&1 || missing_deps+=("pacman-contrib")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install with: sudo pacman -S ${missing_deps[*]}"
        exit 1
    fi
}

# Main execution
main() {
    log_info "Starting package update process..."
    log_info "Project root: $PROJECT_ROOT"
    log_info "Processing ${#PACKAGES_TO_PROCESS[@]} packages: ${PACKAGES_TO_PROCESS[*]}"

    # Always show debug info for package validation
    debug_arrays

    # Show packages to process
    log_info "=== Packages to process ==="
    for i in "${!PACKAGES_TO_PROCESS[@]}"; do
        log_info "  [$((i+1))]: ${PACKAGES_TO_PROCESS[$i]}"
    done
    echo

    # Check dependencies unless dry run
    if [[ "$DRY_RUN" != "true" ]]; then
        check_dependencies
    fi

    local success_count=0
    local -a failed_packages=()

    # Validate that all package directories exist
    local -a missing_dirs=()
    for pkg in "${PACKAGES_TO_PROCESS[@]}"; do
        if [[ ! -d "$PROJECT_ROOT/$pkg" ]]; then
            missing_dirs+=("$pkg")
        fi
    done

    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
        log_error "Missing package directories: ${missing_dirs[*]}"
        log_info "Available directories in $PROJECT_ROOT:"
        find "$PROJECT_ROOT" -maxdepth 1 -type d -name "*-*" | sort
        exit 1
    fi

    # Process each package - PROPER ITERATION WITH ERROR HANDLING
    for pkg in "${PACKAGES_TO_PROCESS[@]}"; do
        echo
        log_info "=========================================="
        log_info "Processing package $((success_count + ${#failed_packages[@]} + 1))/${#PACKAGES_TO_PROCESS[@]}: $pkg"

        # Individual package processing with error handling
        if [[ "$BUILD_ONLY" == "true" ]]; then
            # Build only mode
            log_info "Build-only mode for $pkg"
            if build_package "$PROJECT_ROOT/$pkg"; then
                ((success_count++))
                log_success "Build completed for $pkg"
            else
                failed_packages+=("$pkg")
                log_error "Build failed for $pkg, continuing with other packages..."
            fi
        else
            # Full update mode or dry run
            log_info "Update mode for $pkg"
            if update_package "$pkg"; then
                ((success_count++))
                log_success "Update completed for $pkg"
            else
                failed_packages+=("$pkg")
                log_error "Update failed for $pkg, continuing with other packages..."
            fi
        fi

        # Show progress
        log_info "Progress: Completed $((success_count + ${#failed_packages[@]}))/${#PACKAGES_TO_PROCESS[@]} packages"
    done

    # Summary
    echo
    log_info "=========================================="
    log_info "Update process completed!"
    log_success "Successfully processed: $success_count/${#PACKAGES_TO_PROCESS[@]} packages"

    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log_error "Failed packages: ${failed_packages[*]}"
        exit 1
    fi

    log_success "All packages processed successfully!"
}

# Execute main function
main "$@"
