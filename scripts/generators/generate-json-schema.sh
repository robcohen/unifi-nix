#!/usr/bin/env bash
# generate-json-schema.sh - Generate JSON Schema from MongoDB schema
# Usage: ./generate-json-schema.sh <mongodb-fields.json> <mongodb-examples.json> <enums.json> <output-dir>
#
# Generates JSON Schema files for each collection, enabling IDE validation
# of raw JSON configs.

set -euo pipefail

FIELDS_JSON="${1:?Usage: $0 <fields.json> <examples.json> <enums.json> <output-dir>}"
EXAMPLES_JSON="${2:?Usage: $0 <fields.json> <examples.json> <enums.json> <output-dir>}"
ENUMS_JSON="${3:?Usage: $0 <fields.json> <examples.json> <enums.json> <output-dir>}"
OUTPUT_DIR="${4:?Usage: $0 <fields.json> <examples.json> <enums.json> <output-dir>}"

mkdir -p "$OUTPUT_DIR"

# Generate a JSON Schema for each collection
jq -r --slurpfile examples "$EXAMPLES_JSON" --slurpfile enums "$ENUMS_JSON" '
# Type inference from field name patterns
def infer_type_from_name:
  if test("_enabled$|_supported$|^is_|^has_|^enable_|^hide_|^no_") then "boolean"
  elif test("_id$|_ids$") then "string"
  elif test("_port$|_size$|_count$|_limit$|_time$|_interval$|_kbps$|_rate$|vlan$|index$") then "integer"
  elif test("_list$|_members$|_aps$|_keys$|^schedule|_ids$") then "array"
  elif test("_ip$|_subnet$|_cidr$|_gateway$") then "string"
  else "string"
  end;

# Type inference from example value
def infer_type_from_value:
  if . == null then "null"
  elif type == "boolean" then "boolean"
  elif type == "number" then
    if . == (. | floor) then "integer" else "number" end
  elif type == "string" then "string"
  elif type == "array" then "array"
  elif type == "object" then "object"
  else "string"
  end;

# Get enum values for a field if available
def get_enum($field; $enums):
  $enums[0][$field] // null;

# Build property schema
def build_property($field; $example; $enums):
  {
    type: (
      if $example != null then ($example | infer_type_from_value)
      else ($field | infer_type_from_name)
      end
    )
  } +
  (if get_enum($field; $enums) then {enum: get_enum($field; $enums)} else {} end) +
  (if $field | test("_id$") then {pattern: "^[0-9a-f]{24}$"} else {} end) +
  (if $field | test("_ip$") then {format: "ipv4"} else {} end) +
  (if $field | test("_subnet$|_cidr$") then {pattern: "^[0-9.]+/[0-9]+$"} else {} end);

to_entries[] |
.key as $collection |
.value as $fields |
($examples[0][$collection] // {}) as $example |
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "unifi-\($collection).schema.json",
  title: "UniFi \($collection) Configuration",
  type: "object",
  properties: (
    $fields | map(
      . as $field |
      {
        key: $field,
        value: build_property($field; $example[$field]; $enums)
      }
    ) | from_entries
  ),
  additionalProperties: true
} |
"\($collection)\t\(.)"
' "$FIELDS_JSON" | while IFS=$'\t' read -r collection schema; do
  echo "$schema" | jq '.' >"$OUTPUT_DIR/${collection}.schema.json"
done

# Generate a root schema that references all collections
jq -r 'keys[]' "$FIELDS_JSON" | jq -Rs '
split("\n") | map(select(. != "")) |
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "unifi-config.schema.json",
  title: "UniFi Configuration",
  type: "object",
  properties: (
    map({
      key: .,
      value: {"$ref": "./\(.).schema.json"}
    }) | from_entries
  )
}
' >"$OUTPUT_DIR/unifi-config.schema.json"

echo "Generated JSON schemas in: $OUTPUT_DIR" >&2
echo "Collections: $(ls "$OUTPUT_DIR"/*.schema.json 2>/dev/null | wc -l)" >&2
