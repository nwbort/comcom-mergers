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
jq --compact-output '.[:5][]' "$INPUT_FILE" | while IFS= read -r merger_json; do
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

    echo "DEBUG: Downloaded HTML, length: ${#html_content}" >&2

    # Test pup output first
    pup_output=$(echo "$html_content" | pup 'body json{}')
    echo "DEBUG: pup output length: ${#pup_output}" >&2
    echo "DEBUG: pup output first 500 chars: ${pup_output:0:500}" >&2

    # Use pup and jq to extract all required details
    details_json=$(echo "$pup_output" | jq -s '
        .[0] | # Work with the first element of the slurped array
        # Helper function to find text of a node by its class
        def find_text($class): .. | select(.tag? and (.class? // "" | contains($class))) | .text?;

        # Helper function to find an attribute of a node by its class
        def find_attr($class; $attr): .. | select(.tag? and (.class? // "" | contains($class))) | ."\($attr)"?;

        # Function to extract the key-value pairs from the <dl> list
        def get_case_details:
            (.. | select(.tag? == "dl") | .children? // []) as $children |
            [
                # Get the indices of all <dt> elements
                [foreach range(0; $children | length) as $i (null; if $children[$i].tag == "dt" then $i else empty end)] as $dt_indices |
                # For each <dt> index, create a key-value object
                foreach range(0; $dt_indices | length) as $k (null;
                    {
                        key: ($children[$dt_indices[$k]].text | rtrimstr(":") | gsub(" "; "_") | ascii_downcase),
                        value: (
                            # Get all <dd> elements between this <dt> and the next one
                            $children[($dt_indices[$k] + 1) : ($dt_indices[$k+1]? // null)] |
                            map(select(.tag == "dd") | .text) | join("\n")
                        )
                    }
                )
            ] | from_entries; # Convert the array of {key,value} objects into a single JSON object

        # Function to extract the list of updates
        def get_updates:
            [.. | select(.tag? and (.class? // "" | contains("case-register-update"))) | {
                date: find_text("case-register-update__date"),
                title: find_text("case-register-update__title"),
                document_link_relative: find_attr("a.case-register-update__document"; "href"),
                document_title: find_text("a.case-register-update__document")
            }];

        # Assemble the final details object
        {
          "description": (.. | select(.tag? and .class? == "prose") | .text? // ""),
          "case_details": get_case_details,
          "updates": get_updates
        }
    ' 2>&1) 

    echo "DEBUG: details_json length: ${#details_json}" >&2
    echo "DEBUG: details_json content: '$details_json'" >&2

    # Check if details_json is empty or whitespace
    if [ -z "$details_json" ] || [ -z "$(echo "$details_json" | tr -d '[:space:]')" ]; then
        echo "Warning: Empty details extracted for $url" >&2
        echo "$merger_json" | jq '. + {details: {}}'
        continue
    fi

    # Validate details_json before using it
    if ! echo "$details_json" | jq empty 2>/dev/null; then
        echo "Warning: Invalid JSON extracted for $url" >&2
        echo "DEBUG: Full details_json: $details_json" >&2
        echo "$merger_json" | jq '. + {details: {}}'
        continue
    fi

    # Add the extracted 'details' object to the original merger JSON
    echo "$merger_json" | jq --argjson details "$details_json" '. + {details: $details}'

done | jq -s '.' > "$OUTPUT_FILE"

echo "Success! Detailed data has been added to $OUTPUT_FILE"
