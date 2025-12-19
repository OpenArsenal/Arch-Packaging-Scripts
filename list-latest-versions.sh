#!/usr/bin/env bash
set -euo pipefail

# Package-Update-Bot/1.0
USER_AGENT="Package-Update-Bot/1.0"
TIMEOUT=30

# Fetch with timeout and User-Agent
fetch() {
    curl -sSL --max-time $TIMEOUT -A "$USER_AGENT" "$1"
}

# 1Password CLI: newest at bottom of RSS
get_1password_version() {
    local url="$1"
    fetch "$url" | \
        xmllint --xpath '//item[last()]/title' - 2>/dev/null | \
        sed 's/<[^>]*>//g' | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# GitHub Atom: newest first, version in <title>
get_github_version() {
    local url="$1"
    fetch "$url" | \
        xmlstarlet sel -N atom="http://www.w3.org/2005/Atom" \
            -t -v "//atom:entry[1]/atom:title" | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# VSCode: use GitHub API for cleaner version
get_vscode_version() {
    local api_url="https://api.github.com/repos/Microsoft/vscode/releases/latest"
    fetch "$api_url" | \
        jq -r '.tag_name'
}

# Google Chrome JSON API - Fixed URL encoding
get_chrome_version_json() {
    local channel="$1"  # stable or canary
    # Properly encode the URL parameters
    local encoded_filter="endtime%3Dnone%2Cfraction%3E%3D0.5"
    local encoded_order="version%20desc"
    local url="https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/${channel}/versions/all/releases?filter=${encoded_filter}&order_by=${encoded_order}"

    local response
    response=$(fetch "$url" 2>/dev/null)

    if [[ -z "$response" ]] || ! echo "$response" | jq . >/dev/null 2>&1; then
        echo "Error: Invalid JSON response from Chrome API for $channel" >&2
        return 1
    fi

    echo "$response" | jq -r '.releases[0].version'
}

# Microsoft Edge YUM: parse repomd.xml and primary.xml.gz (ignore namespaces)
get_edge_version() {
    local repomd_url="$1"
    local base="${repomd_url%/repodata/repomd.xml}"

    # Extract primary.xml.gz href without namespace issues
    local primary_href
    primary_href=$(fetch "$repomd_url" | \
        xmllint --xpath 'string(//*[local-name()="data" and @type="primary"]/*[local-name()="location"]/@href)' - 2>/dev/null)

    if [[ -z "$primary_href" ]]; then
        echo "Error: Could not find primary.xml location in repomd.xml" >&2
        return 1
    fi

    # Download, decompress and parse version attribute
    local version
    version=$(fetch "${base}/${primary_href}" | gunzip 2>/dev/null | \
        xmllint --xpath "string((//*[local-name()='entry'][@name='microsoft-edge-stable']/@ver)[last()])" - 2>/dev/null)

    if [[ -z "$version" ]]; then
        echo "Error: Could not extract Edge version from primary.xml" >&2
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


# Package definitions
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
  ["figma-linux-git"]="github"
)
# ["1password"]="https://releases.1password.com/linux/index.xml"
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
  ["figma-linux-git"]="https://github.com/Figma-Linux/figma-linux/releases.atom"
)

is_vcs_package() {
  local pkg="$1"
  local pkgbuild_path="$2"

  [[ "$pkg" =~ -(git|hg|svn|bzr)$ ]] && return 0
  grep -qE '^\s*pkgver\(\)' "$pkgbuild_path" && return 0
  grep -qE 'git\+' "$pkgbuild_path" && return 0
  return 1
}

# Main: fetch and print latest versions
for pkg in "${!FEED_TYPE[@]}"; do
    type="${FEED_TYPE[$pkg]}"
    url="${FEED_URL[$pkg]}"

    echo -n "$pkg: "

    case "$type" in
        "1password-cli2")
            if version=$(get_1password_cli2_version_json "$url" 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
        "1password")
            if version=$(get_1password_version "$url" 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
        "github")
            if version=$(get_github_version "$url" 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
        "vscode")
            if version=$(get_vscode_version 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
        "chrome-stable")
            if version=$(get_chrome_version_json "stable" 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
        "chrome-canary")
            if version=$(get_chrome_version_json "canary" 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
        "edge")
            if version=$(get_edge_version "$url" 2>/dev/null); then
                echo "$version"
            else
                echo "ERROR"
            fi
            ;;
    esac
done
