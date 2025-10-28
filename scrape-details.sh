#!/usr/bin/env bash
#
# scrape-details.sh - Scrapes detailed information for each merger in mergers.json
# and updates the file in place.

set -e
set -o pipefail

# --- Configuration ---
INPUT_FILE="mergers.json"
OUTPUT_FILE="mergers-detailed.json"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
PARALLEL_JOBS=16

# --- Main Script ---
# 1. Check for dependencies
for cmd in curl pup jq parallel; do
    if ! command -v "$cmd" > /dev/null; then
        echo "Error: Command '$cmd' is not installed." >&2
        echo "Please install it to continue." >&2
        exit 1
    fi
done

# 2. Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found. Run ./download.sh first." >&2
    exit 1
fi

echo "Starting to scrape details for each merger (parallel mode with $PARALLEL_JOBS jobs)..."

# 3. Use parallel to process mergers concurrently
jq --compact-output '.[]' "$INPUT_FILE" | \
  parallel -j "$PARALLEL_JOBS" --keep-order --line-buffer '
    merger_json={}
    url=$(echo "$merger_json" | jq -r ".link")
    
    if [ -z "$url" ] || [ "$url" = "null" ]; then
      echo "$merger_json" | jq ". + {details: {}}"
      exit 0
    fi

    echo "Scraping details from $url..." >&2

    html_content=$(curl -s -L -A "'"$USER_AGENT"'" "$url") || {
      echo "Warning: Failed to download URL: $url" >&2
      echo "$merger_json" | jq ". + {details: {}}"
      exit 0
    }

    pup_output=$(echo "$html_content" | pup "body json{}")

    details_json=$(echo "$pup_output" | jq -s '\''
        .[0] |

        def get_case_details:
            [
                .. | select(.class? and .class == "case-details__record") | {
                    key: (.children[]? | select(.class? and .class == "case-details__record-title") | .text // "" | rtrimstr(":") | gsub(" "; "_") | ascii_downcase),
                    value: (.children[]? | select(.class? and .class == "case-details__record-value") | .text? // "")
                } | select(.key != "")
            ] | from_entries;

        def get_updates:
            (
                .. | select(.tag? == "" and .project?) | .project
                | gsub("&#34;"; "\"")
                | gsub("&amp;"; "&")
                | fromjson
            ) | .timeline;

        def get_description:
            .. | select(.class? and .class == "content-block__content") | .text?;

        {
          "description": (get_description // ""),
          "case_details": (get_case_details // {}),
          "updates": (get_updates // [])
        }
    '\'' 2>&1)

    if ! echo "$details_json" | jq empty 2>/dev/null; then
        echo "Warning: Invalid or empty JSON extracted for $url" >&2
        echo "$merger_json" | jq ". + {details: {}}"
        exit 0
    fi

    echo "$merger_json" | jq --argjson details "$details_json" ". + {details: \$details}"
  ' | jq -s '.' > "$OUTPUT_FILE"

echo "Success! Detailed data has been added to $OUTPUT_FILE"
