#!/usr/bin/env bash
# Validate UniFi configuration against OpenAPI and MongoDB schemas
# Usage: validate-config.sh <config.json> <openapi-schema-dir> <device-schema-dir>
#
# Returns exit code 0 if valid, 1 if invalid with errors printed to stderr
#
set -euo pipefail

CONFIG_JSON="${1:?Usage: validate-config.sh <config.json> <openapi-schema-dir> <device-schema-dir>}"
OPENAPI_DIR="${2:?Missing openapi-schema-dir}"
DEVICE_DIR="${3:?Missing device-schema-dir}"

OPENAPI_SCHEMA="$OPENAPI_DIR/integration.json"
MONGODB_FIELDS="$DEVICE_DIR/mongodb-fields.json"
MONGODB_EXAMPLES="$DEVICE_DIR/mongodb-examples.json"
MONGODB_ENUMS="$DEVICE_DIR/enums.json"
REFERENCE_IDS="$DEVICE_DIR/reference-ids.json"

ERRORS=()
WARNINGS=()

error() {
  ERRORS+=("ERROR: $1")
}

warn() {
  WARNINGS+=("WARNING: $1")
}

# Check required files exist
for f in "$CONFIG_JSON" "$OPENAPI_SCHEMA" "$MONGODB_FIELDS" "$REFERENCE_IDS"; do
  if [[ ! -f $f ]]; then
    echo "ERROR: Required file not found: $f" >&2
    exit 1
  fi
done

CONFIG=$(cat "$CONFIG_JSON")

echo "Validating configuration..."

# =============================================================================
# Load enum values from device schema
# =============================================================================
if [[ -f $MONGODB_ENUMS ]]; then
  echo "  Loading enums from device schema..."
  VALID_NETWORK_PURPOSES=$(jq -r '.network_purposes // [] | join(" ")' "$MONGODB_ENUMS")
  VALID_WIFI_SECURITY=$(jq -r '.wifi_security // [] | join(" ")' "$MONGODB_ENUMS")
  VALID_WIFI_WPA_MODES=$(jq -r '.wifi_wpa_modes // [] | join(" ")' "$MONGODB_ENUMS")
fi

# Defaults if not loaded from schema
VALID_NETWORK_PURPOSES="${VALID_NETWORK_PURPOSES:-corporate guest wan vlan-only remote-user-vpn site-vpn}"
VALID_WIFI_SECURITY="${VALID_WIFI_SECURITY:-open wpapsk wpaeap wep}"
VALID_WIFI_WPA_MODES="${VALID_WIFI_WPA_MODES:-wpa1 wpa2 wpa3 auto}"

# =============================================================================
# Validate Networks
# =============================================================================
echo "  Checking networks..."

NETWORK_SCHEMA=$(jq -r '.components.schemas.NetworkRequest // .components.schemas.Network // empty' "$OPENAPI_SCHEMA")
NETWORK_REQUIRED=$(echo "$NETWORK_SCHEMA" | jq -r '.required // []')

for net_name in $(echo "$CONFIG" | jq -r '.networks // {} | keys[]'); do
  net=$(echo "$CONFIG" | jq -c ".networks[\"$net_name\"]")

  # Check required fields from OpenAPI
  for req_field in $(echo "$NETWORK_REQUIRED" | jq -r '.[]'); do
    # Map OpenAPI field names to MongoDB field names
    case "$req_field" in
    "name") mongo_field="name" ;;
    "enabled") mongo_field="enabled" ;;
    "vlanId") mongo_field="vlan" ;;
    *) mongo_field="$req_field" ;;
    esac

    if ! echo "$net" | jq -e ".$mongo_field // empty" &>/dev/null; then
      # Check if it has a default in the schema
      has_default=$(echo "$NETWORK_SCHEMA" | jq -e ".properties.$req_field.default // empty" 2>/dev/null || echo "")
      if [[ -z $has_default ]]; then
        error "Network '$net_name': missing required field '$mongo_field'"
      fi
    fi
  done

  # Validate field names exist in MongoDB schema
  VALID_NETWORK_FIELDS=$(jq -r '.networkconf // [] | .[]' "$MONGODB_FIELDS")
  for field in $(echo "$net" | jq -r 'keys[]'); do
    # Skip internal fields
    [[ $field == "_"* ]] && continue
    if ! echo "$VALID_NETWORK_FIELDS" | grep -qxF "$field"; then
      warn "Network '$net_name': unknown field '$field' (not in MongoDB schema)"
    fi
  done

  # Validate VLAN range (only if VLAN is enabled)
  vlan_enabled=$(echo "$net" | jq -r '.vlan_enabled // false')
  vlan=$(echo "$net" | jq -r '.vlan // empty')
  if [[ $vlan_enabled == "true" ]] && [[ -n $vlan ]] && [[ $vlan != "null" ]]; then
    if [[ $vlan -lt 1 ]] || [[ $vlan -gt 4094 ]]; then
      error "Network '$net_name': VLAN $vlan out of range (1-4094)"
    fi
  fi

  # Validate IP subnet format
  ip_subnet=$(echo "$net" | jq -r '.ip_subnet // empty')
  if [[ -n $ip_subnet ]] && [[ $ip_subnet != "null" ]]; then
    if ! echo "$ip_subnet" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
      error "Network '$net_name': invalid ip_subnet format '$ip_subnet' (expected x.x.x.x/y)"
    fi
  fi

  # Validate purpose enum (from schema)
  purpose=$(echo "$net" | jq -r '.purpose // empty')
  if [[ -n $purpose ]] && [[ $purpose != "null" ]]; then
    if ! echo "$VALID_NETWORK_PURPOSES" | grep -qw "$purpose"; then
      error "Network '$net_name': invalid purpose '$purpose' (valid: $VALID_NETWORK_PURPOSES)"
    fi
  fi
done

# =============================================================================
# Validate WiFi Networks
# =============================================================================
echo "  Checking WiFi networks..."

# Get WiFi schema from OpenAPI
WIFI_SCHEMA=$(jq -r '.components.schemas.WifiBroadcastRequest // .components.schemas.WifiNetwork // empty' "$OPENAPI_SCHEMA")
WIFI_REQUIRED=$(echo "$WIFI_SCHEMA" | jq -r '.required // []')

# Get valid field names from MongoDB
VALID_WIFI_FIELDS=$(jq -r '.wlanconf // [] | .[]' "$MONGODB_FIELDS")

for wifi_name in $(echo "$CONFIG" | jq -r '.wifi // {} | keys[]'); do
  wifi=$(echo "$CONFIG" | jq -c ".wifi[\"$wifi_name\"]")
  ssid=$(echo "$wifi" | jq -r '.name // empty')

  # Check SSID is present
  if [[ -z $ssid ]] || [[ $ssid == "null" ]]; then
    error "WiFi '$wifi_name': missing required field 'name' (SSID)"
  fi

  # Check SSID length (1-32 characters)
  if [[ -n $ssid ]] && [[ $ssid != "null" ]]; then
    ssid_len=${#ssid}
    if [[ $ssid_len -lt 1 ]] || [[ $ssid_len -gt 32 ]]; then
      error "WiFi '$wifi_name': SSID must be 1-32 characters (got $ssid_len)"
    fi
  fi

  # Check passphrase length (8-63 for WPA)
  passphrase=$(echo "$wifi" | jq -r '.x_passphrase // empty')
  if [[ -n $passphrase ]] && [[ $passphrase != "null" ]] && [[ $passphrase != *"_secret"* ]]; then
    pass_len=${#passphrase}
    if [[ $pass_len -lt 8 ]] || [[ $pass_len -gt 63 ]]; then
      error "WiFi '$wifi_name': passphrase must be 8-63 characters (got $pass_len)"
    fi
  fi

  # Check network reference exists
  net_name=$(echo "$wifi" | jq -r '._network_name // empty')
  if [[ -n $net_name ]] && [[ $net_name != "null" ]]; then
    if ! echo "$CONFIG" | jq -e ".networks[\"$net_name\"]" &>/dev/null; then
      error "WiFi '$wifi_name': references non-existent network '$net_name'"
    fi
  fi

  # Validate wlan_bands values
  bands=$(echo "$wifi" | jq -r '.wlan_bands // [] | .[]' 2>/dev/null)
  for band in $bands; do
    case "$band" in
    2g | 5g | 6g) ;;
    *) error "WiFi '$wifi_name': invalid band '$band' (must be 2g, 5g, or 6g)" ;;
    esac
  done

  # Validate security type (from schema)
  security=$(echo "$wifi" | jq -r '.security // empty')
  if [[ -n $security ]] && [[ $security != "null" ]]; then
    if ! echo "$VALID_WIFI_SECURITY" | grep -qw "$security"; then
      error "WiFi '$wifi_name': invalid security type '$security' (valid: $VALID_WIFI_SECURITY)"
    fi
  fi

  # Validate wpa_mode (from schema)
  wpa_mode=$(echo "$wifi" | jq -r '.wpa_mode // empty')
  if [[ -n $wpa_mode ]] && [[ $wpa_mode != "null" ]]; then
    if ! echo "$VALID_WIFI_WPA_MODES" | grep -qw "$wpa_mode"; then
      error "WiFi '$wifi_name': invalid wpa_mode '$wpa_mode' (valid: $VALID_WIFI_WPA_MODES)"
    fi
  fi

  # Validate field names
  for field in $(echo "$wifi" | jq -r 'keys[]'); do
    [[ $field == "_"* ]] && continue
    if ! echo "$VALID_WIFI_FIELDS" | grep -qxF "$field"; then
      warn "WiFi '$wifi_name': unknown field '$field' (not in MongoDB schema)"
    fi
  done
done

# =============================================================================
# Validate Firewall Rules - DEPRECATED
# =============================================================================
echo "  Checking firewall rules..."

# firewall.rules is deprecated - it wrote to traffic_rule collection which is
# for Traffic Management (bandwidth limits, app filtering), NOT firewall blocking.
# The schema shows traffic_rule.action = "ALLOW" only, not accept/drop/reject.
#
# For proper implementation, use:
# - network_isolation_enabled on networks (isolate = true in config)
# - zone-based firewall (firewall_zone + firewall_policy collections)
#
# The firewall.rules option wrote to traffic_rule collection, but that collection
# is for Traffic Management rules (QoS/rate limiting), not firewall rules.
# Use firewall.policies instead (zone-based firewall, UniFi 10.x+).

rule_count=$(echo "$CONFIG" | jq '.firewallRules // {} | length')
if [[ $rule_count -gt 0 ]]; then
  error "firewall.rules is deprecated and broken - use firewall.policies instead (zone-based firewall)"
fi

# =============================================================================
# Validate Firewall Policies (zone-based, UniFi 10.x+)
# =============================================================================
echo "  Checking firewall policies..."

# Default known values (fallback if schema not available)
DEFAULT_ZONES="internal external gateway vpn hotspot dmz"
DEFAULT_ACTIONS="ALLOW BLOCK REJECT"
DEFAULT_PROTOCOLS="all tcp_udp tcp udp icmp icmpv6"
DEFAULT_IP_VERSIONS="BOTH IPV4 IPV6"
DEFAULT_MATCHING_TARGETS="ANY NETWORK IP MAC DEVICE APP DOMAIN REGION"

# Read valid values from device schema
if [[ -f $MONGODB_ENUMS ]]; then
  echo "    Reading enum values from device schema..."

  # Zone keys from device
  SCHEMA_ZONES=$(jq -r '.zone_keys // [] | join(" ")' "$MONGODB_ENUMS")
  VALID_ZONES="${SCHEMA_ZONES:-$DEFAULT_ZONES}"

  # Merge schema values with defaults (schema values take precedence for validation)
  SCHEMA_ACTIONS=$(jq -r '.policy_actions // [] | join(" ")' "$MONGODB_ENUMS")
  SCHEMA_PROTOCOLS=$(jq -r '.policy_protocols // [] | join(" ")' "$MONGODB_ENUMS")
  SCHEMA_IP_VERSIONS=$(jq -r '.policy_ip_versions // [] | join(" ")' "$MONGODB_ENUMS")
  SCHEMA_MATCHING_TARGETS=$(jq -r '([.policy_src_matching_targets // [], .policy_dst_matching_targets // []] | flatten | unique | join(" "))' "$MONGODB_ENUMS")

  # Use defaults but warn if schema has values we don't recognize
  VALID_ACTIONS="$DEFAULT_ACTIONS"
  VALID_PROTOCOLS="$DEFAULT_PROTOCOLS"
  VALID_IP_VERSIONS="$DEFAULT_IP_VERSIONS"
  VALID_MATCHING_TARGETS="$DEFAULT_MATCHING_TARGETS"

  # Check if schema has any values not in our defaults
  for action in $SCHEMA_ACTIONS; do
    if ! echo "$DEFAULT_ACTIONS" | grep -qw "$action"; then
      warn "Device schema has unknown action '$action' - adding to valid list"
      VALID_ACTIONS="$VALID_ACTIONS $action"
    fi
  done
  for proto in $SCHEMA_PROTOCOLS; do
    if ! echo "$DEFAULT_PROTOCOLS" | grep -qw "$proto"; then
      warn "Device schema has unknown protocol '$proto' - adding to valid list"
      VALID_PROTOCOLS="$VALID_PROTOCOLS $proto"
    fi
  done
  for ipv in $SCHEMA_IP_VERSIONS; do
    if ! echo "$DEFAULT_IP_VERSIONS" | grep -qw "$ipv"; then
      warn "Device schema has unknown ip_version '$ipv' - adding to valid list"
      VALID_IP_VERSIONS="$VALID_IP_VERSIONS $ipv"
    fi
  done
  for target in $SCHEMA_MATCHING_TARGETS; do
    if ! echo "$DEFAULT_MATCHING_TARGETS" | grep -qw "$target"; then
      warn "Device schema has unknown matching_target '$target' - adding to valid list"
      VALID_MATCHING_TARGETS="$VALID_MATCHING_TARGETS $target"
    fi
  done

  # Get valid field names for firewall_policy
  VALID_POLICY_FIELDS=$(jq -r '.firewall_policy // [] | .[]' "$MONGODB_FIELDS" 2>/dev/null || echo "")

  echo "    Zones from device: $VALID_ZONES"
elif [[ -f $MONGODB_EXAMPLES ]]; then
  # Fallback to examples file
  VALID_ZONES=$(jq -r '.firewall_zones_all // [] | .[].zone_key // empty' "$MONGODB_EXAMPLES" | tr '\n' ' ')
  VALID_ZONES="${VALID_ZONES:-$DEFAULT_ZONES}"
  VALID_ACTIONS="$DEFAULT_ACTIONS"
  VALID_PROTOCOLS="$DEFAULT_PROTOCOLS"
  VALID_IP_VERSIONS="$DEFAULT_IP_VERSIONS"
  VALID_MATCHING_TARGETS="$DEFAULT_MATCHING_TARGETS"
  VALID_POLICY_FIELDS=$(jq -r '.firewall_policy // [] | .[]' "$MONGODB_FIELDS" 2>/dev/null || echo "")

  echo "    Zones from examples: $VALID_ZONES"
else
  warn "No device schema found - using default validation values"
  VALID_ZONES="$DEFAULT_ZONES"
  VALID_ACTIONS="$DEFAULT_ACTIONS"
  VALID_PROTOCOLS="$DEFAULT_PROTOCOLS"
  VALID_IP_VERSIONS="$DEFAULT_IP_VERSIONS"
  VALID_MATCHING_TARGETS="$DEFAULT_MATCHING_TARGETS"
  VALID_POLICY_FIELDS=""

  echo "    Using defaults (no schema)"
fi

for policy_name in $(echo "$CONFIG" | jq -r '.firewallPolicies // {} | keys[]'); do
  policy=$(echo "$CONFIG" | jq -c ".firewallPolicies[\"$policy_name\"]")

  # Check required fields
  name=$(echo "$policy" | jq -r '.name // empty')
  if [[ -z $name ]] || [[ $name == "null" ]]; then
    error "Firewall policy '$policy_name': missing required field 'name'"
  fi

  # Validate action
  action=$(echo "$policy" | jq -r '.action // empty')
  if [[ -n $action ]] && [[ $action != "null" ]]; then
    if ! echo "$VALID_ACTIONS" | grep -qw "$action"; then
      error "Firewall policy '$policy_name': invalid action '$action' (must be ALLOW, BLOCK, or REJECT)"
    fi
  fi

  # Validate source zone
  src_zone=$(echo "$policy" | jq -r '.source._zone_key // empty')
  if [[ -n $src_zone ]] && [[ $src_zone != "null" ]]; then
    if ! echo "$VALID_ZONES" | grep -qw "$src_zone"; then
      error "Firewall policy '$policy_name': invalid source zone '$src_zone'"
    fi
  fi

  # Validate destination zone
  dst_zone=$(echo "$policy" | jq -r '.destination._zone_key // empty')
  if [[ -n $dst_zone ]] && [[ $dst_zone != "null" ]]; then
    if ! echo "$VALID_ZONES" | grep -qw "$dst_zone"; then
      error "Firewall policy '$policy_name': invalid destination zone '$dst_zone'"
    fi
  fi

  # Validate source matching_target
  src_target=$(echo "$policy" | jq -r '.source.matching_target // empty')
  if [[ -n $src_target ]] && [[ $src_target != "null" ]]; then
    if ! echo "$VALID_MATCHING_TARGETS" | grep -qw "$src_target"; then
      error "Firewall policy '$policy_name': invalid source matching_target '$src_target'"
    fi
  fi

  # Validate destination matching_target
  dst_target=$(echo "$policy" | jq -r '.destination.matching_target // empty')
  if [[ -n $dst_target ]] && [[ $dst_target != "null" ]]; then
    if ! echo "$VALID_MATCHING_TARGETS" | grep -qw "$dst_target"; then
      error "Firewall policy '$policy_name': invalid destination matching_target '$dst_target'"
    fi
  fi

  # Validate protocol
  proto=$(echo "$policy" | jq -r '.protocol // empty')
  if [[ -n $proto ]] && [[ $proto != "null" ]]; then
    if ! echo "$VALID_PROTOCOLS" | grep -qw "$proto"; then
      # Check if it's a numeric protocol (0-255)
      if ! [[ $proto =~ ^[0-9]+$ ]] || [[ $proto -lt 0 ]] || [[ $proto -gt 255 ]]; then
        error "Firewall policy '$policy_name': invalid protocol '$proto'"
      fi
    fi
  fi

  # Validate ip_version
  ip_ver=$(echo "$policy" | jq -r '.ip_version // empty')
  if [[ -n $ip_ver ]] && [[ $ip_ver != "null" ]]; then
    if ! echo "$VALID_IP_VERSIONS" | grep -qw "$ip_ver"; then
      error "Firewall policy '$policy_name': invalid ip_version '$ip_ver'"
    fi
  fi

  # Validate index range (user policies should be 0-29999)
  idx=$(echo "$policy" | jq -r '.index // empty')
  if [[ -n $idx ]] && [[ $idx != "null" ]]; then
    if [[ $idx -ge 30000 ]]; then
      warn "Firewall policy '$policy_name': index $idx >= 30000 may conflict with system rules"
    fi
  fi

  # Check network references exist
  for net_ref in $(echo "$policy" | jq -r '.source._network_names // [] | .[]'); do
    if ! echo "$CONFIG" | jq -e ".networks[\"$net_ref\"]" &>/dev/null; then
      error "Firewall policy '$policy_name': source references non-existent network '$net_ref'"
    fi
  done

  for net_ref in $(echo "$policy" | jq -r '.destination._network_names // [] | .[]'); do
    if ! echo "$CONFIG" | jq -e ".networks[\"$net_ref\"]" &>/dev/null; then
      error "Firewall policy '$policy_name': destination references non-existent network '$net_ref'"
    fi
  done

  # Validate field names against schema (if available)
  if [[ -n $VALID_POLICY_FIELDS ]]; then
    for field in $(echo "$policy" | jq -r 'keys[]'); do
      [[ $field == "_"* ]] && continue     # Skip internal fields
      [[ $field == "source" ]] && continue # Nested objects handled separately
      [[ $field == "destination" ]] && continue
      [[ $field == "schedule" ]] && continue
      if ! echo "$VALID_POLICY_FIELDS" | grep -qxF "$field"; then
        warn "Firewall policy '$policy_name': unknown field '$field' (not in device schema)"
      fi
    done
  fi
done

# =============================================================================
# Validate Port Forwards
# =============================================================================
echo "  Checking port forwards..."

for pf_name in $(echo "$CONFIG" | jq -r '.portForwards // {} | keys[]'); do
  pf=$(echo "$CONFIG" | jq -c ".portForwards[\"$pf_name\"]")

  # Check required fields
  dst_port=$(echo "$pf" | jq -r '.dst_port // empty')
  fwd_ip=$(echo "$pf" | jq -r '.fwd // empty')
  fwd_port=$(echo "$pf" | jq -r '.fwd_port // empty')

  if [[ -z $dst_port ]] || [[ $dst_port == "null" ]]; then
    error "Port forward '$pf_name': missing required field 'dst_port'"
  fi

  if [[ -z $fwd_ip ]] || [[ $fwd_ip == "null" ]]; then
    error "Port forward '$pf_name': missing required field 'fwd' (destination IP)"
  fi

  # Validate IP address format
  if [[ -n $fwd_ip ]] && [[ $fwd_ip != "null" ]]; then
    if ! echo "$fwd_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      error "Port forward '$pf_name': invalid IP address '$fwd_ip'"
    fi
  fi

  # Validate port range (1-65535)
  if [[ -n $dst_port ]] && [[ $dst_port != "null" ]]; then
    if [[ $dst_port -lt 1 ]] || [[ $dst_port -gt 65535 ]] 2>/dev/null; then
      error "Port forward '$pf_name': invalid dst_port '$dst_port' (must be 1-65535)"
    fi
  fi

  if [[ -n $fwd_port ]] && [[ $fwd_port != "null" ]]; then
    if [[ $fwd_port -lt 1 ]] || [[ $fwd_port -gt 65535 ]] 2>/dev/null; then
      error "Port forward '$pf_name': invalid fwd_port '$fwd_port' (must be 1-65535)"
    fi
  fi

  # Check protocol
  proto=$(echo "$pf" | jq -r '.proto // empty')
  if [[ -n $proto ]] && [[ $proto != "null" ]]; then
    case "$proto" in
    tcp | udp | tcp_udp) ;;
    *) error "Port forward '$pf_name': invalid protocol '$proto'" ;;
    esac
  fi
done

# =============================================================================
# Validate DHCP Reservations
# =============================================================================
echo "  Checking DHCP reservations..."

for res_name in $(echo "$CONFIG" | jq -r '.dhcpReservations // {} | keys[]'); do
  res=$(echo "$CONFIG" | jq -c ".dhcpReservations[\"$res_name\"]")

  # Check required fields
  mac=$(echo "$res" | jq -r '.mac // empty')
  ip=$(echo "$res" | jq -r '.ip // empty')

  if [[ -z $mac ]] || [[ $mac == "null" ]]; then
    error "DHCP reservation '$res_name': missing required field 'mac'"
  fi

  if [[ -z $ip ]] || [[ $ip == "null" ]]; then
    error "DHCP reservation '$res_name': missing required field 'ip'"
  fi

  # Validate MAC address format
  if [[ -n $mac ]] && [[ $mac != "null" ]]; then
    if ! echo "$mac" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
      error "DHCP reservation '$res_name': invalid MAC address '$mac' (expected xx:xx:xx:xx:xx:xx)"
    fi
  fi

  # Validate IP address format
  if [[ -n $ip ]] && [[ $ip != "null" ]]; then
    if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      error "DHCP reservation '$res_name': invalid IP address '$ip'"
    fi
  fi

  # Check network reference exists
  net_name=$(echo "$res" | jq -r '._network_name // empty')
  if [[ -n $net_name ]] && [[ $net_name != "null" ]]; then
    if ! echo "$CONFIG" | jq -e ".networks[\"$net_name\"]" &>/dev/null; then
      error "DHCP reservation '$res_name': references non-existent network '$net_name'"
    fi
  fi
done

# =============================================================================
# Output Results
# =============================================================================
echo ""

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo "Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  $w" >&2
  done
  echo ""
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Validation FAILED with ${#ERRORS[@]} error(s):" >&2
  for e in "${ERRORS[@]}"; do
    echo "  $e" >&2
  done
  exit 1
fi

echo "Validation passed ✓"
exit 0
