#!/usr/bin/env bash
# generate-all.sh - Run all schema generators
# Usage: ./generate-all.sh <schema-version-dir> [output-dir]
#
# Runs all generators and outputs to the schema directory or custom location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_DIR="${1:?Usage: $0 <schema-version-dir> [output-dir]}"
OUTPUT_DIR="${2:-$SCHEMA_DIR/generated}"

# Verify input files exist
for file in integration.json mongodb-examples.json mongodb-fields.json; do
  if [[ ! -f "$SCHEMA_DIR/$file" ]]; then
    echo "Error: Required file not found: $SCHEMA_DIR/$file" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/json-schema"

echo "=== UniFi Schema Generation ===" >&2
echo "Input: $SCHEMA_DIR" >&2
echo "Output: $OUTPUT_DIR" >&2
echo "" >&2

# 1. Extract enums
echo "[1/4] Extracting enums from OpenAPI..." >&2
"$SCRIPT_DIR/extract-enums.sh" \
  "$SCHEMA_DIR/integration.json" \
  "$OUTPUT_DIR/enums.json"

# 2. Extract defaults
echo "[2/4] Extracting defaults from examples..." >&2
"$SCRIPT_DIR/extract-defaults.sh" \
  "$SCHEMA_DIR/mongodb-examples.json" \
  "$OUTPUT_DIR/defaults.json"

# 3. Extract validation rules
echo "[3/4] Extracting validation rules..." >&2
"$SCRIPT_DIR/extract-validation.sh" \
  "$SCHEMA_DIR/integration.json" \
  "$OUTPUT_DIR/validation.json"

# 4. Generate JSON Schema
echo "[4/4] Generating JSON Schema..." >&2
"$SCRIPT_DIR/generate-json-schema.sh" \
  "$SCHEMA_DIR/mongodb-fields.json" \
  "$SCHEMA_DIR/mongodb-examples.json" \
  "$OUTPUT_DIR/enums.json" \
  "$OUTPUT_DIR/json-schema"

# Summary
echo "" >&2
echo "=== Generation Complete ===" >&2
echo "Files created:" >&2
ls -la "$OUTPUT_DIR"/*.json 2>/dev/null | awk '{print "  " $NF}' >&2
echo "JSON schemas: $(ls "$OUTPUT_DIR/json-schema"/*.schema.json 2>/dev/null | wc -l) files" >&2
