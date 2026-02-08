#!/usr/bin/env bash
# generate-all.sh - Run all schema generators
# Usage: ./generate-all.sh <schema-version-dir> [output-dir]
#
# Runs all generators and outputs to the schema directory or custom location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_DIR="${1:?Usage: $0 <schema-version-dir> [output-dir]}"
OUTPUT_DIR="${2:-$SCHEMA_DIR/generated}"

# Verify required files/directories exist
if [[ ! -d "$SCHEMA_DIR/jar-fields" ]]; then
  echo "Error: Required directory not found: $SCHEMA_DIR/jar-fields" >&2
  exit 1
fi

for file in mongodb-examples.json mongodb-fields.json; do
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

# 1. Extract enums and validation from JAR field definitions
echo "[1/3] Extracting enums and validation from JAR..." >&2
"$SCRIPT_DIR/extract-from-jar.sh" "$SCHEMA_DIR" "$OUTPUT_DIR"

# 2. Extract defaults
echo "[2/3] Extracting defaults from examples..." >&2
"$SCRIPT_DIR/extract-defaults.sh" \
  "$SCHEMA_DIR/mongodb-examples.json" \
  "$OUTPUT_DIR/defaults.json"

# 3. Generate JSON Schema
echo "[3/3] Generating JSON Schema..." >&2
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
