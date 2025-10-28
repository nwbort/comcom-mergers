#!/usr/bin/env bash
#
# download.sh - Downloads a merger cases page, extracts the details,
#                      and saves them as a sorted JSON file.
#
# Usage: ./download.sh URL
# Dependencies: curl, pup, jq

# --- Enhanced Debugging ---
set -e
set -o pipefail
set -x

# --- Configuration ---
OUTPUT_FILENAME="mergers.json"
LOG_RAW_JSON="raw_json.log"

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
trap 'echo "--- SCRIPT EXITING ---"; rm -f "$TEMP_FILE" "$LOG_RAW_JSON"; set +x' EXIT

echo "Downloading HTML from $URL..."
curl -s -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" "$URL" -o "$TEMP_FILE" || {
  echo "Error: Failed to download URL: $URL" >&2
  exit 1
}
echo "HTML downloaded to $TEMP_FILE"

# 4. Determine the base URL for constructing absolute links
BASE_URL=$(echo "$URL" | awk -F/ '{print $1"//"$3}')
echo "Base URL determined as: $BASE_URL"

echo "--- PARSING HTML WITH PUP ---"
# 5. Use pup to parse HTML with a simplified approach
RAW_PUP_OUTPUT=$(pup -f "$TEMP_FILE" 'div.card.card--has-link' '
    a.card__link text{},
    a.card__link attr{href},
    div.card__status text{},
    div.card__tag text{},
    div.card__info-detail text{}
' | sed 's/&amp;/\&/g')

# Log the raw output from pup for inspection
echo "--- RAW PUP OUTPUT ---" > "$LOG_RAW_JSON"
echo "$RAW_PUP_OUTPUT" >> "$LOG_RAW_JSON"
echo "Raw pup output has been saved to $LOG_RAW_JSON for debugging."
echo "--- END RAW PUP OUTPUT ---"

echo "--- PROCESSING DATA WITH JQ ---"
# 6. Use jq to process the raw text output and build the JSON
FINAL_JSON=$(echo "$RAW_PUP_OUTPUT" | jq -R -s '
  def trim: sub("^\\s+|\\s+$"; "");

  split("\n") | map(select(length > 0)) |

  reduce . as $lines ([];
    . as $acc |
    if $lines | length == 0 then
      $acc
    else
      ( ($lines | to_entries | map(select(.value | contains("Merger application"))))[0].key ) as $end_index |
      $lines[0:$end_index+1] as $current_record |
      $lines[$end_index+1:] as $remaining_lines |

      (
        {
          "name": $current_record[0] | trim,
          "link_relative": $current_record[1] | trim,
          "status": $current_record[2] | trim,
          "tag": ($current_record | last) | trim
        } + (
          $current_record[3:-1] | reduce .[] as $item ({};
            if $item | contains("Outcome:") then
              . + {"outcome": ($item | sub("Outcome:"; "") | trim)}
            elif $item | contains("Date Closed:") then
              . + {"date": ($item | sub("Date Closed:"; "") | trim)}
            else
              .
            end
          )
        )
      ) as $new_object |

      $acc + [$new_object] | reduce $remaining_lines as $lines (.; .)
    end
  ) |

  map(
    .outcome |= (. // null) |
    .date |= (. // null) |

    .link = "'"$BASE_URL"'" + .link_relative |
    del(.link_relative) |

    .sort_date = (if .date then (.date | strptime("%d %B %Y") | strftime("%Y-%m-%d")) else null end)
  ) |
  sort_by(.sort_date, .name) |
  map(del(.sort_date))
')

set +x

# 7. Save the final JSON to the output file
echo "$FINAL_JSON" > "$OUTPUT_FILENAME"

echo "Success! Processed data saved to $OUTPUT_FILENAME"
