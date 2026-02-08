#!/usr/bin/env bash
# extract-validation.sh - Extract validation rules from OpenAPI schema
# Usage: ./extract-validation.sh <integration.json> <output.json>
#
# Extracts validation constraints (required fields, min/max, patterns)
# from UniFi's OpenAPI spec.

set -euo pipefail

INTEGRATION_JSON="${1:?Usage: $0 <integration.json> <output.json>}"
OUTPUT_JSON="${2:?Usage: $0 <integration.json> <output.json>}"

if [[ ! -f $INTEGRATION_JSON ]]; then
  echo "Error: File not found: $INTEGRATION_JSON" >&2
  exit 1
fi

# Extract validation rules
jq '
# Extract constraints from schema properties
def extract_constraints:
  to_entries | map(
    select(.value | type == "object") |
    select(.value.type != null or .value.enum != null) |
    {
      field: .key,
      type: (.value.type // "string"),
      required: false,
      constraints: (
        .value |
        (if has("minimum") and (.minimum | type == "number") then {minimum: .minimum} else {} end) +
        (if has("maximum") and (.maximum | type == "number") then {maximum: .maximum} else {} end) +
        (if has("minLength") and (.minLength | type == "number") then {minLength: .minLength} else {} end) +
        (if has("maxLength") and (.maxLength | type == "number") then {maxLength: .maxLength} else {} end) +
        (if has("pattern") and (.pattern | type == "string") then {pattern: .pattern} else {} end) +
        (if has("format") and (.format | type == "string") then {format: .format} else {} end) +
        (if has("enum") and (.enum | type == "array") then {enum: .enum} else {} end) +
        (if has("minItems") and (.minItems | type == "number") then {minItems: .minItems} else {} end) +
        (if has("maxItems") and (.maxItems | type == "number") then {maxItems: .maxItems} else {} end)
      )
    } |
    select(.constraints != {})
  ) // [];

# Process components/schemas safely
((.components.schemas // {}) | to_entries | map(
  select(.value | type == "object") |
  .key as $schema |
  .value as $def |
  (($def.required // []) | if type == "array" then . else [] end) as $required |
  {
    schema: $schema,
    required: $required,
    fields: (
      (($def.properties // {}) | extract_constraints)
    )
  }
) |

# Filter to schemas with constraints
map(select((.fields | length > 0) or (.required | length > 0))) |

# Convert to lookup
map({key: .schema, value: {required: .required, fields: .fields}}) |
from_entries) // {}
' "$INTEGRATION_JSON" >"$OUTPUT_JSON"

echo "Extracted validation rules to: $OUTPUT_JSON" >&2
