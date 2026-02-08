#!/usr/bin/env bash
# generate-module.sh - Generate Nix module code from MongoDB schema
# Usage: generate-module.sh <collection> [schema-dir]
#
# Reads extracted schema and generates:
#   1. Nix submodule options (module.nix format)
#   2. Conversion function (to-mongo.nix format)
#   3. Deploy script section (deploy.sh format)
#
set -euo pipefail

COLLECTION="${1:-}"
SCHEMA_DIR="${2:-}"

# Find schema directory if not specified
if [[ -z $SCHEMA_DIR ]]; then
  # Try to find latest schema
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SCHEMAS_BASE="$SCRIPT_DIR/../schemas"
  if [[ -d $SCHEMAS_BASE ]]; then
    SCHEMA_DIR=$(find "$SCHEMAS_BASE" -maxdepth 1 -type d | sort -V | tail -1)
  fi

  # Fall back to cache
  if [[ -z $SCHEMA_DIR ]] || [[ ! -d $SCHEMA_DIR ]]; then
    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/unifi-nix/devices"
    if [[ -d $CACHE_DIR ]]; then
      SCHEMA_DIR=$(find "$CACHE_DIR" -maxdepth 1 -type d | head -1)
    fi
  fi
fi

if [[ -z $COLLECTION ]]; then
  echo "Usage: generate-module.sh <collection> [schema-dir]"
  echo ""
  echo "Generate Nix module code from MongoDB schema."
  echo ""
  echo "Available collections:"
  if [[ -f "$SCHEMA_DIR/mongodb-fields.json" ]]; then
    jq -r 'keys[]' "$SCHEMA_DIR/mongodb-fields.json" | sed 's/^/  /'
  else
    echo "  (schema not found - run extract-device-schema.sh first)"
  fi
  exit 1
fi

if [[ ! -f "$SCHEMA_DIR/mongodb-fields.json" ]]; then
  echo "Error: Schema not found at $SCHEMA_DIR"
  echo "Run: ./scripts/extract-device-schema.sh <host>"
  exit 1
fi

FIELDS_FILE="$SCHEMA_DIR/mongodb-fields.json"
EXAMPLES_FILE="$SCHEMA_DIR/mongodb-examples.json"

# Check if collection exists
if ! jq -e ".[\"$COLLECTION\"]" "$FIELDS_FILE" >/dev/null 2>&1; then
  echo "Error: Collection '$COLLECTION' not found in schema"
  echo ""
  echo "Available collections:"
  jq -r 'keys[]' "$FIELDS_FILE" | sed 's/^/  /'
  exit 1
fi

echo "# ============================================================================="
echo "# Generated code for collection: $COLLECTION"
echo "# Schema: $SCHEMA_DIR"
echo "# Generated: $(date -Iseconds)"
echo "# ============================================================================="
echo ""

# Get fields for this collection
FIELDS=$(jq -r ".[\"$COLLECTION\"][]" "$FIELDS_FILE")

# Get example document if available
EXAMPLE="{}"
if [[ -f $EXAMPLES_FILE ]]; then
  EXAMPLE=$(jq -c ".[\"$COLLECTION\"] // {}" "$EXAMPLES_FILE")
fi

# Infer Nix type from JSON value AND field name
infer_nix_type() {
  local field="$1"
  local value="$2"

  # Skip internal fields
  case "$field" in
  _id | site_id | attr_* | setting_preference | external_id)
    echo "SKIP"
    return
    ;;
  esac

  # First, try to infer from field name patterns (more reliable)
  case "$field" in
  *_enabled | *_enable | enabled | is_* | *_required | *_only_once | *_active | *_allowed | *_blocked | *_hidden | *_disabled | auto_* | use_*)
    echo "types.bool"
    return
    ;;
  *_timeout | *_time | *_port | *_rate | *_limit | *_max | *_min | *_count | *_size | *_length | vlan | index)
    echo "types.int"
    return
    ;;
  *_ids)
    echo "types.listOf types.str  # Reference IDs"
    return
    ;;
  *_id)
    echo "types.nullOr types.str  # Reference ID"
    return
    ;;
  *_ip | *_gateway | *_start | *_stop | *_cidr | *_subnet | ip_subnet)
    echo "types.str  # IP/CIDR"
    return
    ;;
  *_mac | mac)
    echo "types.str  # MAC address"
    return
    ;;
  *_list | *_members | *_networks | *_ips)
    echo "types.listOf types.str"
    return
    ;;
  esac

  # Then try to infer from value if available
  if [[ $value != "null" ]]; then
    case "$value" in
    true | false)
      echo "types.bool"
      return
      ;;
    \"*\")
      echo "types.str"
      return
      ;;
    [0-9]*)
      echo "types.int"
      return
      ;;
    \[*)
      if echo "$value" | jq -e '.[0] | type == "string"' >/dev/null 2>&1; then
        echo "types.listOf types.str"
      elif echo "$value" | jq -e '.[0] | type == "number"' >/dev/null 2>&1; then
        echo "types.listOf types.int"
      elif echo "$value" | jq -e '.[0] | type == "object"' >/dev/null 2>&1; then
        echo "types.listOf types.attrs  # Nested objects"
      else
        echo "types.listOf types.str"
      fi
      return
      ;;
    \{*)
      echo "types.attrs  # Nested object"
      return
      ;;
    esac
  fi

  # Default fallback
  echo "types.nullOr types.str"
}

# Convert field name to Nix option name (camelCase)
to_nix_name() {
  local name="$1"
  # Convert snake_case to camelCase
  echo "$name" | sed -E 's/_([a-z])/\U\1/g'
}

# Convert collection name to Nix name
COLLECTION_NIX=$(echo "$COLLECTION" | sed -E 's/_([a-z])/\U\1/g')
COLLECTION_OPTS="${COLLECTION_NIX}Opts"

echo "# ============================================================================="
echo "# PART 1: Nix Module Options (add to module.nix)"
echo "# ============================================================================="
echo ""
echo "  # ${COLLECTION} options"
echo "  ${COLLECTION_OPTS} ="
echo "    { name, ... }:"
echo "    {"
echo "      options = {"

# Generate options for each field
for field in $FIELDS; do
  # Get example value
  value=$(echo "$EXAMPLE" | jq -c ".[\"$field\"] // null")

  # Infer type
  nix_type=$(infer_nix_type "$field" "$value")

  # Skip internal fields
  if [[ $nix_type == "SKIP" ]]; then
    continue
  fi

  # Convert to Nix name
  nix_name=$(to_nix_name "$field")

  # Determine default based on type
  default="null"
  case "$nix_type" in
  "types.bool")
    # Try to get from example, default to false
    if [[ $value == "true" ]]; then
      default="true"
    else
      default="false"
    fi
    ;;
  "types.int")
    # Try to get from example, default to 0
    if [[ $value =~ ^[0-9]+$ ]]; then
      default="$value"
    else
      default="0"
    fi
    ;;
  "types.str"*)
    default='""'
    ;;
  "types.listOf"*)
    default="[ ]"
    ;;
  "types.attrs"*)
    default="{ }"
    ;;
  "types.nullOr"*)
    default="null"
    ;;
  esac

  echo ""
  echo "        $nix_name = mkOption {"
  echo "          type = $nix_type;"
  echo "          default = $default;"
  echo "          description = \"$field\";"
  echo "        };"
done

echo "      };"
echo "    };"
echo ""

echo "# Add to options.unifi in module.nix:"
echo "#"
echo "#   ${COLLECTION_NIX} = mkOption {"
echo "#     type = types.attrsOf (types.submodule ${COLLECTION_OPTS});"
echo "#     default = { };"
echo "#     description = \"${COLLECTION} configuration\";"
echo "#   };"
echo ""

echo "# ============================================================================="
echo "# PART 2: Conversion Function (add to lib/to-mongo.nix)"
echo "# ============================================================================="
echo ""
echo "  # Convert ${COLLECTION_NIX} to MongoDB document"
echo "  ${COLLECTION_NIX}ToMongo = _name: cfg: {"

for field in $FIELDS; do
  value=$(echo "$EXAMPLE" | jq -c ".[\"$field\"] // null")
  nix_type=$(infer_nix_type "$field" "$value")

  if [[ $nix_type == "SKIP" ]]; then
    continue
  fi

  nix_name=$(to_nix_name "$field")

  # Handle field mapping
  if [[ $field == "name" ]]; then
    echo "    inherit (cfg) name;"
  elif [[ $field == "enabled" ]]; then
    echo "    enabled = cfg.enable;"
  elif [[ $field == *"_id" ]] && [[ $field != "_id" ]]; then
    # Reference field - needs resolution at deploy time
    echo "    _${field}_ref = cfg.${nix_name};  # Resolve at deploy time"
  else
    echo "    $field = cfg.${nix_name};"
  fi
done

echo ""
echo '    site_id = "_SITE_ID_";'
echo "  };"
echo ""

echo "# Add to export block in lib/to-mongo.nix:"
echo "#"
echo "#   ${COLLECTION_NIX} = mapAttrs ${COLLECTION_NIX}ToMongo config.${COLLECTION_NIX};"
echo ""

echo "# ============================================================================="
echo "# PART 3: Deploy Script Section (add to scripts/deploy.sh)"
echo "# ============================================================================="
echo ""

# Generate deploy script with placeholders replaced
cat <<'DEPLOY_EOF' | sed \
  -e "s/COLLECTION_NAME/${COLLECTION}/g" \
  -e "s/COLLECTION_NIX/${COLLECTION_NIX}/g" \
  -e "s/COLLECTION_DB/${COLLECTION}/g" \
  -e "s/COLLECTION_VAR/${COLLECTION_NIX}/g"
echo ""
echo "=== Applying COLLECTION_NAME ==="

COLLECTION_VAR_count=$(echo "$DESIRED" | jq '.COLLECTION_NIX | length')
if [[ $COLLECTION_VAR_count -gt 0 ]]; then
  for item in $(echo "$DESIRED" | jq -r '.COLLECTION_NIX | keys[]'); do
    desired_item=$(echo "$DESIRED" | jq -c ".COLLECTION_NIX[\"$item\"]")
    name=$(echo "$desired_item" | jq -r '.name')
    echo "Processing: $name"

    item_doc=$(echo "$desired_item" | jq -c ". + {site_id: \"$SITE_ID\"}")

    existing=$(ssh "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '
      JSON.stringify(db.COLLECTION_DB.findOne({name: \"$name\"}, {_id: 1}))
    '" 2>/dev/null || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new COLLECTION_NAME"
      run_mongo "db.COLLECTION_DB.insertOne($item_doc)"
    else
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      update_doc=$(echo "$item_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.COLLECTION_DB.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
else
  echo "  (none defined)"
fi
DEPLOY_EOF

echo ""
echo "# ============================================================================="
echo "# Summary"
echo "# ============================================================================="
echo "#"
echo "# Generated code for: $COLLECTION"
echo "# Fields processed: $(echo "$FIELDS" | wc -w)"
echo "#"
echo "# To use this code:"
echo "#   1. Copy PART 1 into module.nix (submodule + option)"
echo "#   2. Copy PART 2 into lib/to-mongo.nix (conversion + export)"
echo "#   3. Copy PART 3 into scripts/deploy.sh (deploy logic)"
echo "#   4. Add to confirmation summary in deploy.sh"
echo "#   5. Run 'nix fmt' to format"
echo "#   6. Test with 'nix eval'"
echo "#"
