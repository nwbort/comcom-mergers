#!/usr/bin/env bash
#
# download.sh - Downloads a merger cases page, extracts the details,
#                      and saves them as a sorted JSON file.
#
# Usage: ./download.sh URL
# Dependencies: curl, pup, jq

set -e
set -o pipefail

# --- Configuration ---
OUTPUT_FILENAME="mergers.json"

# --- Main Script ---

# 1. Check for dependencies
for cmd in curl pup jq; do
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

# 3. Download the HTML to a temporary file
TEMP_FILE=$(mktemp)
# Ensure the temporary file is cleaned up on exit
trap 'rm -f "$TEMP_FILE"' EXIT

echo "Downloading HTML from $URL..."
curl -s -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" "$URL" -o "$TEMP_FILE" || {
  echo "Error: Failed to download URL: $URL" >&2
  exit 1
}

# 4. Determine the base URL for constructing absolute links
BASE_URL=$(echo "$URL" | awk -F/ '{print $1"//"$3}')

echo "Parsing HTML and extracting merger cases..."
# 5. Use pup to parse HTML and extract data into a raw JSON array.
# For each card, we extract the name, relative link, status, outcome, date, and tag.
RAW_JSON=$(pup -f "$TEMP_FILE" 'div.card.card--has-link' '{
    "name": "a.card__link text{}",
    "link_relative": "a.card__link attr{href}",
    "status": "div.card__status text{}",
    "outcome": "div.card__info-detail:has(span:contains(Outcome)) span:last-of-type text{}",
    "date": "div.card__info-detail:has(span:contains(Date Closed)) span:last-of-type text{}",
    "tag": "div.card__tag text{}"
}')

echo "Processing, cleaning, and sorting data..."
# 6. Use jq to process the raw JSON. This multi-step process will:
#    - map(): Iterate over each extracted case.
#    - Clean whitespace from each field.
#    - Create a full, absolute URL for the 'link'.
#    - Convert the date string (e.g., "17 October 2025") into a standard,
#      sortable format (YYYY-MM-DD). This is stored in a temporary field.
#    - sort_by(): Sort the array of cases first by the standardized date (ascending,
#      with open cases first), and then by name for cases with the same date.
#    - map(del()): Remove the temporary sorting key for a clean final output.
FINAL_JSON=$(echo "$RAW_JSON" | jq '
  map(
    # Clean up leading/trailing whitespace from all fields
    .name |= (sub("^\\s+|\\s+$"; "") | sub("\\s+"; " ")) |
    .status |= (sub("^\\s+|\\s+$"; "")) |
    .outcome |= (if . then sub("^\\s+|\\s+$"; "") else null end) |
    .date |= (if . then sub("^\\s+|\\s+$"; "") else null end) |
    .tag |= (sub("^\\s+|\\s+$"; "")) |

    # Create a full, absolute link and remove the relative one
    .link = "'"$BASE_URL"'" + .link_relative |
    del(.link_relative) |

    # Create a temporary, sortable date field (YYYY-MM-DD).
    # Cases with no date get `null`, which jq sorts first.
    .sort_date = (if .date then (.date | strptime("%d %B %Y") | strftime("%Y-%m-%d")) else null end)
  ) |
  # Sort by the standardized date (ascending), then by name (ascending)
  sort_by(.sort_date, .name) |
  # Remove the temporary sort key from the final output
  map(del(.sort_date))
')

# 7. Save the final JSON to the output file
echo "$FINAL_JSON" > "$OUTPUT_FILENAME"

echo "Success! Processed data saved to $OUTPUT_FILENAME"
