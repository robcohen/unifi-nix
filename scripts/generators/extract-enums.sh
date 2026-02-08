#!/usr/bin/env bash
# extract-enums.sh - Extract enum values from OpenAPI schema
# Usage: ./extract-enums.sh <integration.json> <output.json>
#
# Extracts all enum definitions from UniFi's OpenAPI spec and outputs
# a structured JSON file mapping field names to their possible values.

set -euo pipefail

INTEGRATION_JSON="${1:?Usage: $0 <integration.json> <output.json>}"
OUTPUT_JSON="${2:?Usage: $0 <integration.json> <output.json>}"

if [[ ! -f $INTEGRATION_JSON ]]; then
  echo "Error: File not found: $INTEGRATION_JSON" >&2
  exit 1
fi

# Extract enums with their property context
jq '
# Recursively find all properties with enum values
def find_enums:
  . as $root |
  [
    # Search in components/schemas
    (.components.schemas // {}) | to_entries[] |
    .key as $schema |
    (.value.properties // {}) | to_entries[] |
    select(.value.enum) |
    {
      schema: $schema,
      field: .key,
      values: .value.enum
    }
  ] +
  [
    # Search in path request/response bodies
    (.paths // {}) | to_entries[] |
    .value | to_entries[] |
    (.value.requestBody.content // {}) | to_entries[] |
    (.value.schema.properties // {}) | to_entries[] |
    select(.value.enum) |
    {
      field: .key,
      values: .value.enum
    }
  ] +
  [
    # Search in nested items (arrays)
    (.components.schemas // {}) | to_entries[] |
    .key as $schema |
    (.value.properties // {}) | to_entries[] |
    select(.value.items.enum) |
    {
      schema: $schema,
      field: .key,
      values: .value.items.enum
    }
  ];

# Group by field name and merge values
find_enums |
group_by(.field) |
map({
  key: .[0].field,
  value: (map(.values) | add | unique | sort)
}) |
from_entries |

# Also add categorized enums for common patterns
. + {
  # Actions
  policy_actions: (.action // []),
  traffic_actions: (.action // []),

  # Protocols
  protocols: (.protocol // []),
  ip_versions: (.ip_version // []),

  # WiFi
  wifi_bands: (.wlan_band // .band // []),
  wifi_security: (.security // []),
  wifi_wpa_modes: (.wpa_mode // []),
  wifi_pmf_modes: (.pmf_mode // []),

  # Network
  network_purposes: (.purpose // []),
  network_groups: (.networkgroup // []),
  wan_types: (.wan_type // []),

  # Firewall
  zone_keys: (.zone_key // []),
  matching_targets: (.matching_target // []),

  # Schedule
  days_of_week: (.day // []),

  # Port profiles
  port_operations: (.poe_mode // [])
}
' "$INTEGRATION_JSON" >"$OUTPUT_JSON"

echo "Extracted enums to: $OUTPUT_JSON" >&2
