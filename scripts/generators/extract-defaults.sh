#!/usr/bin/env bash
# extract-defaults.sh - Extract default values from MongoDB examples
# Usage: ./extract-defaults.sh <mongodb-examples.json> <output.json>
#
# Extracts default values from example documents, inferring types
# and providing realistic defaults for Nix module generation.

set -euo pipefail

EXAMPLES_JSON="${1:?Usage: $0 <mongodb-examples.json> <output.json>}"
OUTPUT_JSON="${2:?Usage: $0 <mongodb-examples.json> <output.json>}"

if [[ ! -f $EXAMPLES_JSON ]]; then
  echo "Error: File not found: $EXAMPLES_JSON" >&2
  exit 1
fi

# Extract defaults with type inference - simplified approach
jq '
# Infer Nix type from value
def nix_type:
  type as $t |
  if $t == "null" then "null"
  elif $t == "boolean" then "bool"
  elif $t == "number" then (if . == floor then "int" else "float" end)
  elif $t == "array" then "list"
  elif $t == "object" then
    if has("$oid") then "mongoId"
    elif has("$binary") then "binary"
    else "attrs"
    end
  else "string"
  end;

# Process a single document into field info
def extract_fields:
  [to_entries[] |
   select(.key | startswith("_") | not) |
   select(.key | startswith("x_") | not) |
   select(.value | type | . != "object" or . == "null") |
   {
     name: .key,
     type: (.value | nix_type),
     default: .value,
     optional: ((.value == null) or (.value == false) or (.value == "") or (.value == []))
   }
  ];

# Build result object
reduce (to_entries[] | select(.value | type == "object")) as $e (
  {};
  . + {($e.key): ($e.value | extract_fields)}
)
' "$EXAMPLES_JSON" >"$OUTPUT_JSON"

echo "Extracted defaults to: $OUTPUT_JSON" >&2
