#!/usr/bin/env bash
#
# download.sh - Downloads a merger cases page, extracts the details,
#                      and saves them as a sorted JSON file.
#
# Usage: ./download.sh URL
# Dependencies: curl, jq

set -e
set -o pipefail

# --- Configuration ---
OUTPUT_FILENAME="mergers.json"

# --- Main Script ---

# 1. Check for dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    echo "Please install it to continue." >&2
    exit 1
  fi
done

# 2. Check if URL provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 URL" >&2
  exit 1
fi

URL="$1"

# 3. Download the JSON data from the API to a temporary file
TEMP_FILE=$(mktemp)
# Ensure the temporary file is cleaned up on exit
trap 'rm -f "$TEMP_FILE"' EXIT

echo "Downloading JSON data from $URL..."
# We add specific headers to tell the server we want JSON, mimicking the
# JavaScript application's behavior. This is the key to the solution.
curl -s -L \
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -H "Accept: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  "$URL" -o "$TEMP_FILE" || {
  echo "Error: Failed to download data from URL: $URL" >&2
  exit 1
}

# 4. Determine the base URL for constructing absolute links
BASE_URL=$(echo "$URL" | awk -F/ '{print $1"//"$3}')

echo "Processing, cleaning, and sorting data..."
# 5. Use jq to process the JSON API response. This is far more reliable than
#    parsing HTML. We map the API fields to our desired output format.
FINAL_JSON=$(jq '
  # Access the "results" array from the API response
  .results
  | map(
      # Create our desired object structure
      {
        "name": .Title,
        "link": "'"$BASE_URL"'" + .Link,
        "status": .Status,
        # The API provides "Outcomes" as a simple string, which is great.
        # We ensure it is null if empty, otherwise we trim it.
        "outcome": (.Outcomes | if . and . != "" then sub("^\\s+|\\s+$"; "") else null end),
        # The API provides a clean "DateClosed" field.
        "date": (.DateClosed | if . and . != "" then . else null end),
        "tag": .CaseCategory
      }
    )
  | map(
      # Create a temporary, sortable date field (YYYY-MM-DD).
      # strptime understands the "DD MMMM YYYY" format from the API.
      # Cases with no date (null) will be sorted first, which is desired.
      .sort_date = (if .date then (.date | strptime("%d %B %Y") | strftime("%Y-%m-%d")) else null end)
    )
  # Sort by the standardized date (ascending), then by name (ascending)
  | sort_by(.sort_date, .name)
  # Remove the temporary sort key from the final output for a clean result
  | map(del(.sort_date))
' "$TEMP_FILE")

# 6. Save the final JSON to the output file
echo "$FINAL_JSON" > "$OUTPUT_FILENAME"

echo "Success! Processed data saved to $OUTPUT_FILENAME"
