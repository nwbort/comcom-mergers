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
curl -s -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/5.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" "$URL" -o "$TEMP_FILE" || {
  echo "Error: Failed to download URL: $URL" >&2
  exit 1
}

# 4. Determine the base URL for constructing absolute links
BASE_URL=$(echo "$URL" | awk -F/ '{print $1"//"$3}')

echo "Parsing HTML into intermediate JSON..."
# 5. Use pup to convert each card into a structured JSON object.
#    This creates a JSON array where each object is a machine-readable
#    version of a card's HTML structure. This is the intermediate step.
INTERMEDIATE_JSON=$(pup -f "$TEMP_FILE" 'div.card.card--has-link json{}')

echo "Transforming intermediate JSON into final format..."
# 6. Use jq to parse the intermediate JSON and build the final, clean output.
FINAL_JSON=$(echo "$INTERMEDIATE_JSON" | jq '
  # Helper function to find a node by tag/class and get its text.
  # `..` is a recursive search, `?` prevents errors on missing keys.
  def find_text($tag; $class):
    .. | select(.tag? == $tag and (.class? | contains($class))) | .text? // null;

  # Helper function to find a node and get an attribute.
  def find_attr($tag; $class; $attr):
    .. | select(.tag? == $tag and (.class? | contains($class))) | ."\($attr)"? // null;

  # Helper function to extract a value from the "info_details" text blob.
  def get_info_value($title):
      # Find all info-detail nodes, get their text
      [.. | select(.tag? == "div" and .class? | contains("card__info-detail")) | .text?]
      # Find the first line that contains the title
      | map(select(. | contains($title))) | .[0] // null
      # If found, remove the title and trim whitespace
      | (if . then sub(".*" + $title; "") | sub("^\\s+|\\s+$"; "") else null end);

  # Main transformation logic for each card
  map(
    .name = find_text("a"; "card__link") |
    .link_relative = find_attr("a"; "card__link"; "href") |
    .status = find_text("div"; "card__status") |
    .tag = find_text("div"; "card__tag") |
    .outcome = get_info_value("Outcome:") |
    .date = get_info_value("Date Closed:") |

    # Create the full link
    .link = "'"$BASE_URL"'" + .link_relative |

    # Create a temporary, sortable date field (YYYY-MM-DD)
    .sort_date = (if .date then (.date | strptime("%d %B %Y") | strftime("%Y-%m-%d")) else null end) |

    # Remove intermediate and redundant fields to create the clean object
    del(.tag, .text, .children, .class, .link_relative)
  ) |
  # Sort by the standardized date (ascending), then by name (ascending)
  sort_by(.sort_date, .name) |
  # Remove the temporary sort key from the final output
  map(del(.sort_date))
')

# 7. Save the final JSON to the output file
echo "$FINAL_JSON" > "$OUTPUT_FILENAME"

echo "Success! Processed data saved to $OUTPUT_FILENAME"
