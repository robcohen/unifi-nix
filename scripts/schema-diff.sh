#!/usr/bin/env bash
# Show differences between UniFi schema versions
# Usage: schema-diff.sh <version1> <version2>
#        schema-diff.sh            # List available versions
#
# Examples:
#   schema-diff.sh 10.0.159 10.0.162   # Compare two versions
#   schema-diff.sh                      # List all cached versions
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMAS_DIR="$SCRIPT_DIR/../schemas"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

VERSION1="${1:-}"
VERSION2="${2:-}"

# List available versions
list_versions() {
  echo "Available schema versions:"
  echo ""
  if [[ -d $SCHEMAS_DIR ]]; then
    for version_dir in "$SCHEMAS_DIR"/*/; do
      if [[ -d $version_dir ]]; then
        version=$(basename "$version_dir")
        has_openapi=""
        has_enums=""
        [[ -f "$version_dir/integration.json" ]] && has_openapi=" (OpenAPI)"
        [[ -f "$version_dir/enums.json" ]] && has_enums=" (enums)"
        echo "  - $version$has_openapi$has_enums"
      fi
    done
  else
    echo "  No schemas found. Run: ./scripts/extract-device-schema.sh <host>"
  fi
  echo ""
  echo "Usage: schema-diff.sh <version1> <version2>"
}

if [[ -z $VERSION1 ]]; then
  list_versions
  exit 0
fi

if [[ -z $VERSION2 ]]; then
  echo "Error: Two versions required for comparison"
  echo ""
  list_versions
  exit 1
fi

# Validate versions exist
SCHEMA1="$SCHEMAS_DIR/$VERSION1"
SCHEMA2="$SCHEMAS_DIR/$VERSION2"

if [[ ! -d $SCHEMA1 ]]; then
  echo "Error: Schema version not found: $VERSION1"
  echo "  Expected: $SCHEMA1"
  exit 1
fi

if [[ ! -d $SCHEMA2 ]]; then
  echo "Error: Schema version not found: $VERSION2"
  echo "  Expected: $SCHEMA2"
  exit 1
fi

echo "=== Schema Diff: $VERSION1 → $VERSION2 ==="
echo ""

# Diff enums if both have them
if [[ -f "$SCHEMA1/enums.json" ]] && [[ -f "$SCHEMA2/enums.json" ]]; then
  echo -e "${BLUE}=== Enum Changes ===${NC}"
  echo ""

  # Compare each enum category
  for key in zone_keys policy_actions policy_protocols policy_ip_versions \
    network_purposes wifi_security wifi_wpa_modes \
    policy_src_matching_targets policy_dst_matching_targets; do

    VALUES1=$(jq -r ".${key} // [] | sort | .[]" "$SCHEMA1/enums.json" 2>/dev/null || true)
    VALUES2=$(jq -r ".${key} // [] | sort | .[]" "$SCHEMA2/enums.json" 2>/dev/null || true)

    if [[ $VALUES1 != "$VALUES2" ]]; then
      echo -e "${YELLOW}$key:${NC}"

      # Show removed values
      while IFS= read -r val; do
        if [[ -n $val ]] && ! echo "$VALUES2" | grep -qxF "$val"; then
          echo -e "  ${RED}- $val${NC}"
        fi
      done <<<"$VALUES1"

      # Show added values
      while IFS= read -r val; do
        if [[ -n $val ]] && ! echo "$VALUES1" | grep -qxF "$val"; then
          echo -e "  ${GREEN}+ $val${NC}"
        fi
      done <<<"$VALUES2"

      echo ""
    fi
  done

  echo -e "${GREEN}✓ Enum comparison complete${NC}"
  echo ""
else
  echo "Note: One or both versions don't have enums.json"
  [[ ! -f "$SCHEMA1/enums.json" ]] && echo "  - $VERSION1: No enums.json"
  [[ ! -f "$SCHEMA2/enums.json" ]] && echo "  - $VERSION2: No enums.json"
  echo ""
fi

# Diff OpenAPI schema if both have it
if [[ -f "$SCHEMA1/integration.json" ]] && [[ -f "$SCHEMA2/integration.json" ]]; then
  echo -e "${BLUE}=== OpenAPI Schema Changes ===${NC}"
  echo ""

  # Compare API paths
  PATHS1=$(jq -r '.paths | keys[]' "$SCHEMA1/integration.json" 2>/dev/null | sort || true)
  PATHS2=$(jq -r '.paths | keys[]' "$SCHEMA2/integration.json" 2>/dev/null | sort || true)

  # Count changes
  ADDED_PATHS=0
  REMOVED_PATHS=0

  while IFS= read -r path; do
    if [[ -n $path ]] && ! echo "$PATHS1" | grep -qxF "$path"; then
      ((ADDED_PATHS++)) || true
    fi
  done <<<"$PATHS2"

  while IFS= read -r path; do
    if [[ -n $path ]] && ! echo "$PATHS2" | grep -qxF "$path"; then
      ((REMOVED_PATHS++)) || true
    fi
  done <<<"$PATHS1"

  if [[ $ADDED_PATHS -gt 0 ]] || [[ $REMOVED_PATHS -gt 0 ]]; then
    echo "API Endpoints:"
    [[ $ADDED_PATHS -gt 0 ]] && echo -e "  ${GREEN}+ $ADDED_PATHS new endpoints${NC}"
    [[ $REMOVED_PATHS -gt 0 ]] && echo -e "  ${RED}- $REMOVED_PATHS removed endpoints${NC}"
    echo ""

    # Show first 10 added
    if [[ $ADDED_PATHS -gt 0 ]]; then
      echo "New endpoints (first 10):"
      count=0
      while IFS= read -r path; do
        if [[ -n $path ]] && ! echo "$PATHS1" | grep -qxF "$path"; then
          echo -e "  ${GREEN}+ $path${NC}"
          ((count++)) || true
          [[ $count -ge 10 ]] && break
        fi
      done <<<"$PATHS2"
      [[ $ADDED_PATHS -gt 10 ]] && echo "  ... and $((ADDED_PATHS - 10)) more"
      echo ""
    fi

    # Show first 10 removed
    if [[ $REMOVED_PATHS -gt 0 ]]; then
      echo "Removed endpoints (first 10):"
      count=0
      while IFS= read -r path; do
        if [[ -n $path ]] && ! echo "$PATHS2" | grep -qxF "$path"; then
          echo -e "  ${RED}- $path${NC}"
          ((count++)) || true
          [[ $count -ge 10 ]] && break
        fi
      done <<<"$PATHS1"
      [[ $REMOVED_PATHS -gt 10 ]] && echo "  ... and $((REMOVED_PATHS - 10)) more"
      echo ""
    fi
  else
    echo "API Endpoints: No changes"
    echo ""
  fi

  # Compare schemas (definitions)
  SCHEMAS1=$(jq -r '.components.schemas // .definitions // {} | keys[]' "$SCHEMA1/integration.json" 2>/dev/null | sort || true)
  SCHEMAS2=$(jq -r '.components.schemas // .definitions // {} | keys[]' "$SCHEMA2/integration.json" 2>/dev/null | sort || true)

  ADDED_SCHEMAS=0
  REMOVED_SCHEMAS=0

  while IFS= read -r schema; do
    if [[ -n $schema ]] && ! echo "$SCHEMAS1" | grep -qxF "$schema"; then
      ((ADDED_SCHEMAS++)) || true
    fi
  done <<<"$SCHEMAS2"

  while IFS= read -r schema; do
    if [[ -n $schema ]] && ! echo "$SCHEMAS2" | grep -qxF "$schema"; then
      ((REMOVED_SCHEMAS++)) || true
    fi
  done <<<"$SCHEMAS1"

  if [[ $ADDED_SCHEMAS -gt 0 ]] || [[ $REMOVED_SCHEMAS -gt 0 ]]; then
    echo "Schema Definitions:"
    [[ $ADDED_SCHEMAS -gt 0 ]] && echo -e "  ${GREEN}+ $ADDED_SCHEMAS new schemas${NC}"
    [[ $REMOVED_SCHEMAS -gt 0 ]] && echo -e "  ${RED}- $REMOVED_SCHEMAS removed schemas${NC}"
    echo ""
  else
    echo "Schema Definitions: No changes"
    echo ""
  fi

  echo -e "${GREEN}✓ OpenAPI comparison complete${NC}"
else
  echo "Note: One or both versions don't have integration.json (OpenAPI)"
  [[ ! -f "$SCHEMA1/integration.json" ]] && echo "  - $VERSION1: No integration.json"
  [[ ! -f "$SCHEMA2/integration.json" ]] && echo "  - $VERSION2: No integration.json"
fi

echo ""
echo "=== Summary ==="
echo "Compared: $VERSION1 → $VERSION2"
