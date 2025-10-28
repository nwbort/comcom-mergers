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
FIRST_RUN=true

# --- Main Script ---
# 1. Check for dependencies
for cmd in curl pup jq; do
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

echo "Starting to scrape details for each merger..."

# 3. Use jq to iterate over each merger, scrape details, and add them.
jq --compact-output '.[][]' "$INPUT_FILE" | while IFS= read -r merger_json; do
    # Note: I changed the jq filter above to '.[]' to handle a potential array of arrays. 
    # Adjust to '.[]' if your mergers.json is a single flat array.
    
    url=$(echo "$merger_json" | jq -r '.link')
    
    if [ -z "$url" ] || [ "$url" = "null" ]; then
        echo "$merger_json" | jq '. + {details: {}}'
        continue
    fi

    echo "Scraping details from $url..." >&2

    # Download the HTML content of the individual merger page
    html_content=$(curl -s -L -A "$USER_AGENT" "$url") || {
        echo "Warning: Failed to download URL: $url" >&2
        echo "$merger_json" | jq '. + {details: {}}'
        continue
    }

    # Use pup to convert the HTML body to JSON
    pup_output=$(echo "$html_content" | pup 'body json{}')

    # Save first case for debugging if needed
    if [ "$FIRST_RUN" = true ]; then
        echo "$pup_output" > westpac-pup-output.json
        echo "DEBUG: Saved Westpac pup output to westpac-pup-output.json" >&2
        FIRST_RUN=false
    fi

    # Use pup and jq to extract all required details
    details_json=$(echo "$pup_output" | jq -s '
        .[0] | # Work with the first element of the slurped array

        # 1. Function to extract the key-value pairs from the new div structure
        def get_case_details:
            [
                .. | select(.class? and .class == "case-details__record") | {
                    # Create a key from the title div text
                    key: (.children[]? | select(.class? and .class == "case-details__record-title") | .text // "" | rtrimstr(":") | gsub(" "; "_") | ascii_downcase),
                    # Create a value from the value div text
                    value: (.children[]? | select(.class? and .class == "case-details__record-value") | .text? // "")
                } | select(.key != "") # Filter out any empty keys
            ] | from_entries;

        # 2. Function to extract the updates from the embedded JSON data island
        def get_updates:
            (
                # Find the special tag that holds the data
                .. | select(.tag? == "" and .project?) | .project
                # Decode the HTML entities to make it a valid JSON string
                | gsub("&#34;"; "\"") # Decode quotes
                | gsub("&amp;"; "&")   # Decode ampersands
                # Parse the now-valid JSON string
                | fromjson
            # Select the "timeline" array from the resulting object. Can also get ".documents" or ".media"
            ) | .timeline;


        # 3. Function to get the main description text
        def get_description:
            .. | select(.class? and .class == "content-block__content") | .text?;

        # 4. Assemble the final details object
        {
          "description": (get_description // ""),
          "case_details": (get_case_details // {}),
          "updates": (get_updates // [])
        }
    ' 2>&1)

    # Check if details_json is empty or invalid
    if ! echo "$details_json" | jq empty 2>/dev/null; then
        echo "Warning: Invalid or empty JSON extracted for $url" >&2
        echo "DEBUG: Full details_json: $details_json" >&2
        echo "$merger_json" | jq '. + {details: {}}'
        continue
    fi

    # Add the extracted 'details' object to the original merger JSON
    echo "$merger_json" | jq --argjson details "$details_json" '. + {details: $details}'

done | jq -s '.' > "$OUTPUT_FILE"

echo "Success! Detailed data has been added to $OUTPUT_FILE"
