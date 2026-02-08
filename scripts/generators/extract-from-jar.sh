#!/usr/bin/env bash
# extract-from-jar.sh - Extract enums and validation from UniFi field definitions
# Usage: ./extract-from-jar.sh <schema-dir> <output-dir>
#
# Expects <schema-dir>/jar-fields/ to contain *.json field definitions
# (extracted from core.jar's api/fields/ directory)
#
# Generates:
# - enums.json: Extracted enum values from field patterns
# - validation.json: Validation patterns for fields
# - fields-combined.json: All field definitions merged

set -euo pipefail

SCHEMA_DIR="${1:?Usage: $0 <schema-dir> <output-dir>}"
OUTPUT_DIR="${2:?Usage: $0 <schema-dir> <output-dir>}"
FIELDS_DIR="$SCHEMA_DIR/jar-fields"

if [[ ! -d $FIELDS_DIR ]]; then
  echo "Error: Fields directory not found: $FIELDS_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Processing field definitions from $FIELDS_DIR..." >&2
echo "  Found $(ls "$FIELDS_DIR/"*.json 2>/dev/null | wc -l) field definition files" >&2

# Generate combined fields.json
{
  echo "{"
  first=true
  for f in "$FIELDS_DIR/"*.json; do
    name=$(basename "$f" .json)
    if [[ $first == true ]]; then
      first=false
    else
      echo ","
    fi
    printf '"%s": %s' "$name" "$(cat "$f")"
  done
  echo "}"
} >"$OUTPUT_DIR/fields-combined.json"

# Validate it's proper JSON
if ! jq -e . "$OUTPUT_DIR/fields-combined.json" >/dev/null 2>&1; then
  echo "Error: Generated fields-combined.json is not valid JSON" >&2
  exit 1
fi

# Extract enums from field patterns
# Enum patterns look like: "field": "value1|value2|value3"
# We detect these by looking for pipe-separated alphanumeric values without regex chars
jq '
def is_enum:
  type == "string" and
  test("^[a-zA-Z0-9_-]+([|][a-zA-Z0-9_-]+)+$");

def extract_enum:
  split("|");

# Process each collection
to_entries | map(
  .key as $collection |
  .value | to_entries | map(
    select(.value | is_enum) |
    {
      collection: $collection,
      field: .key,
      values: (.value | extract_enum)
    }
  )
) | flatten |

# Group by field name and merge values across collections
group_by(.field) | map({
  key: .[0].field,
  value: {
    values: (map(.values) | add | unique | sort),
    collections: (map(.collection) | unique | sort)
  }
}) | from_entries
' "$OUTPUT_DIR/fields-combined.json" >"$OUTPUT_DIR/enums.json"

echo "  Generated enums.json with $(jq 'keys | length' "$OUTPUT_DIR/enums.json") enum types" >&2

# Generate validation patterns (non-enum string patterns)
jq '
def is_pattern:
  type == "string" and
  (test("^[a-zA-Z0-9_-]+([|][a-zA-Z0-9_-]+)+$") | not) and
  (test("[\\\\^$.*+?{}\\[\\]()]") or test("^true\\|false$"));

to_entries | map(
  .key as $collection |
  .value | to_entries | map(
    select(.value | is_pattern) |
    {
      collection: $collection,
      field: .key,
      pattern: .value
    }
  )
) | flatten |
group_by(.field) | map({
  key: .[0].field,
  value: {
    pattern: .[0].pattern,
    collections: (map(.collection) | unique | sort)
  }
}) | from_entries
' "$OUTPUT_DIR/fields-combined.json" >"$OUTPUT_DIR/validation.json"

echo "  Generated validation.json with $(jq 'keys | length' "$OUTPUT_DIR/validation.json") patterns" >&2

echo "Extraction complete: $OUTPUT_DIR" >&2
