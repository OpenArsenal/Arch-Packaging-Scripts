#!/usr/bin/env bash
set -uo pipefail

# check-news.sh - Check Arch Linux news
#
# Fetches news from archlinux.org RSS feed and shows items
# since last check or a specified date.
#
# Examples:
#   ./check-news.sh                    # Show unread news
#   ./check-news.sh --all              # Show all recent news
#   ./check-news.sh --since 2025-01-01 # News since date

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Configuration
# ============================================================================

declare -r NEWS_URL="https://archlinux.org/feeds/news/"
declare -r STATE_FILE="$HOME/.cache/pkg-mgmt/last-news-check"
declare -r CACHE_FILE="$HOME/.cache/pkg-mgmt/news-cache.xml"
declare -r CACHE_MAX_AGE=3600  # 1 hour

# ============================================================================
# Options
# ============================================================================

declare SHOW_ALL="false"
declare SINCE_DATE=""
declare OUTPUT_JSON="false"
declare MARK_READ="true"

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Check Arch Linux news for important updates.

OPTIONS:
  --all               Show all recent news (not just unread)
  --since <date>      Show news since date (YYYY-MM-DD)
  --json              Output JSON
  --no-mark-read      Don't update last-read timestamp
  -h, --help          Show this help

STATE FILE:
  $STATE_FILE

EXAMPLES:
  # Check for unread news
  $0

  # Show all news from last 30 days
  $0 --all

  # Show news since specific date
  $0 --since 2025-01-01

  # JSON output for scripting
  $0 --json
EOF
}

# ============================================================================
# Dependency Checking
# ============================================================================

check_deps() {
  local -a missing=()
  
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v xmllint >/dev/null 2>&1 || missing+=("libxml2")
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ============================================================================
# State Management
# ============================================================================

get_last_check_date() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo ""
  fi
}

set_last_check_date() {
  local date="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$date" > "$STATE_FILE"
}

# ============================================================================
# News Fetching
# ============================================================================

fetch_news() {
  local cache_file="$CACHE_FILE"
  
  # Use cache if recent enough
  if [[ -f "$cache_file" ]]; then
    local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
      log_debug "Using cached news (age: ${cache_age}s)"
      cat "$cache_file"
      return 0
    fi
  fi
  
  log_debug "Fetching news from: $NEWS_URL"
  
  local news=""
  if ! news=$(curl -sf --max-time 10 "$NEWS_URL" 2>/dev/null); then
    log_error "Failed to fetch news from $NEWS_URL"
    
    # Fallback to cache if available
    if [[ -f "$cache_file" ]]; then
      log_warning "Using stale cache"
      cat "$cache_file"
      return 0
    fi
    
    return 1
  fi
  
  # Cache for future
  mkdir -p "$(dirname "$cache_file")"
  echo "$news" > "$cache_file"
  
  echo "$news"
}

# ============================================================================
# News Parsing
# ============================================================================

parse_news_xml() {
  local xml="$1"
  local since_date="${2:-}"
  
  # Parse RSS feed with xmllint
  # Extract: title, link, pubDate, description
  
  echo "$xml" | xmllint --xpath "//item" - 2>/dev/null | \
    awk -v since="$since_date" '
      BEGIN { RS="</item>"; FS="</?[^>]+>"; OFS="|" }
      
      /<title>/ {
        title = ""
        link = ""
        pubDate = ""
        desc = ""
        
        for (i=1; i<=NF; i++) {
          if ($i ~ /^<title>/) {
            title = $(i+1)
            gsub(/^[ \t]+|[ \t]+$/, "", title)
          }
          else if ($i ~ /^<link>/) {
            link = $(i+1)
            gsub(/^[ \t]+|[ \t]+$/, "", link)
          }
          else if ($i ~ /^<pubDate>/) {
            pubDate = $(i+1)
            gsub(/^[ \t]+|[ \t]+$/, "", pubDate)
          }
          else if ($i ~ /^<description>/) {
            desc = $(i+1)
            gsub(/^[ \t]+|[ \t]+$/, "", desc)
            # Strip HTML tags from description
            gsub(/<[^>]+>/, "", desc)
            # Decode HTML entities
            gsub(/&lt;/, "<", desc)
            gsub(/&gt;/, ">", desc)
            gsub(/&amp;/, "\\&", desc)
            gsub(/&quot;/, "\"", desc)
          }
        }
        
        if (title != "" && link != "") {
          # Convert pubDate to comparable format (YYYY-MM-DD)
          cmd = "date -d \"" pubDate "\" +%Y-%m-%d 2>/dev/null"
          cmd | getline dateStr
          close(cmd)
          
          # Filter by date if specified
          if (since == "" || dateStr >= since) {
            print title, link, dateStr, desc
          }
        }
      }
    '
}

# ============================================================================
# Output Formatting
# ============================================================================

format_news_plain() {
  local -a items=()
  local line=""
  
  while IFS='|' read -r title link date desc; do
    [[ -z "$title" ]] && continue
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}${title}${NC}"
    echo "Date: $date"
    echo "Link: $link"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Format description (wrap text)
    echo "$desc" | fold -s -w 78
    echo ""
  done
}

format_news_json() {
  local line=""
  
  echo "["
  local first="true"
  
  while IFS='|' read -r title link date desc; do
    [[ -z "$title" ]] && continue
    
    if [[ "$first" != "true" ]]; then
      echo ","
    fi
    first="false"
    
    jq -n \
      --arg title "$title" \
      --arg link "$link" \
      --arg date "$date" \
      --arg desc "$desc" \
      '{
        title: $title,
        link: $link,
        date: $date,
        description: $desc
      }'
  done
  
  echo "]"
}

# ============================================================================
# Main Logic
# ============================================================================

show_news() {
  local since_date="$SINCE_DATE"
  
  # Determine since date
  if [[ "$SHOW_ALL" != "true" && -z "$since_date" ]]; then
    since_date=$(get_last_check_date)
    if [[ -z "$since_date" ]]; then
      # Default to 30 days ago
      since_date=$(date -d "30 days ago" +%Y-%m-%d)
    fi
  fi
  
  log_debug "Showing news since: ${since_date:-all}"
  
  # Fetch news
  local news_xml=""
  if ! news_xml=$(fetch_news); then
    return 1
  fi
  
  # Parse news
  local news_items=""
  news_items=$(parse_news_xml "$news_xml" "$since_date")
  
  if [[ -z "$news_items" ]]; then
    log_info "No news items found"
    return 0
  fi
  
  # Count items
  local item_count=0
  item_count=$(echo "$news_items" | wc -l)
  
  log_info "Found $item_count news item(s)"
  
  # Output
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    echo "$news_items" | format_news_json
  else
    echo "$news_items" | format_news_plain
  fi
  
  # Update last-read timestamp if marking as read
  if [[ "$MARK_READ" == "true" ]]; then
    local now=""
    now=$(date +%Y-%m-%d)
    set_last_check_date "$now"
    log_debug "Updated last check date: $now"
  fi
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) SHOW_ALL="true"; shift ;;
      --since) SINCE_DATE="${2:?missing date}"; shift 2 ;;
      --json) OUTPUT_JSON="true"; shift ;;
      --no-mark-read) MARK_READ="false"; shift ;;
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
  check_deps
  
  show_news
}

main "$@"