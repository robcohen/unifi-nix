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
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Required file not found: $f" >&2
    exit 1
  fi
done

CONFIG=$(cat "$CONFIG_JSON")

echo "Validating configuration..."

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
      if [[ -z "$has_default" ]]; then
        error "Network '$net_name': missing required field '$mongo_field'"
      fi
    fi
  done

  # Validate field names exist in MongoDB schema
  VALID_NETWORK_FIELDS=$(jq -r '.networkconf // [] | .[]' "$MONGODB_FIELDS")
  for field in $(echo "$net" | jq -r 'keys[]'); do
    # Skip internal fields
    [[ "$field" == "_"* ]] && continue
    if ! echo "$VALID_NETWORK_FIELDS" | grep -qxF "$field"; then
      warn "Network '$net_name': unknown field '$field' (not in MongoDB schema)"
    fi
  done

  # Validate VLAN range
  vlan=$(echo "$net" | jq -r '.vlan // empty')
  if [[ -n "$vlan" ]] && [[ "$vlan" != "null" ]]; then
    if [[ "$vlan" -lt 1 ]] || [[ "$vlan" -gt 4094 ]]; then
      error "Network '$net_name': VLAN $vlan out of range (1-4094)"
    fi
  fi

  # Validate IP subnet format
  ip_subnet=$(echo "$net" | jq -r '.ip_subnet // empty')
  if [[ -n "$ip_subnet" ]] && [[ "$ip_subnet" != "null" ]]; then
    if ! echo "$ip_subnet" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
      error "Network '$net_name': invalid ip_subnet format '$ip_subnet' (expected x.x.x.x/y)"
    fi
  fi

  # Validate purpose enum
  purpose=$(echo "$net" | jq -r '.purpose // empty')
  if [[ -n "$purpose" ]] && [[ "$purpose" != "null" ]]; then
    case "$purpose" in
      corporate|guest|wan|vlan-only|remote-user-vpn|site-vpn) ;;
      *) error "Network '$net_name': invalid purpose '$purpose'" ;;
    esac
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
  if [[ -z "$ssid" ]] || [[ "$ssid" == "null" ]]; then
    error "WiFi '$wifi_name': missing required field 'name' (SSID)"
  fi

  # Check SSID length (1-32 characters)
  if [[ -n "$ssid" ]] && [[ "$ssid" != "null" ]]; then
    ssid_len=${#ssid}
    if [[ $ssid_len -lt 1 ]] || [[ $ssid_len -gt 32 ]]; then
      error "WiFi '$wifi_name': SSID must be 1-32 characters (got $ssid_len)"
    fi
  fi

  # Check passphrase length (8-63 for WPA)
  passphrase=$(echo "$wifi" | jq -r '.x_passphrase // empty')
  if [[ -n "$passphrase" ]] && [[ "$passphrase" != "null" ]] && [[ "$passphrase" != *"_secret"* ]]; then
    pass_len=${#passphrase}
    if [[ $pass_len -lt 8 ]] || [[ $pass_len -gt 63 ]]; then
      error "WiFi '$wifi_name': passphrase must be 8-63 characters (got $pass_len)"
    fi
  fi

  # Check network reference exists
  net_name=$(echo "$wifi" | jq -r '._network_name // empty')
  if [[ -n "$net_name" ]] && [[ "$net_name" != "null" ]]; then
    if ! echo "$CONFIG" | jq -e ".networks[\"$net_name\"]" &>/dev/null; then
      error "WiFi '$wifi_name': references non-existent network '$net_name'"
    fi
  fi

  # Validate wlan_bands values
  bands=$(echo "$wifi" | jq -r '.wlan_bands // [] | .[]' 2>/dev/null)
  for band in $bands; do
    case "$band" in
      2g|5g|6g) ;;
      *) error "WiFi '$wifi_name': invalid band '$band' (must be 2g, 5g, or 6g)" ;;
    esac
  done

  # Validate security type
  security=$(echo "$wifi" | jq -r '.security // empty')
  if [[ -n "$security" ]] && [[ "$security" != "null" ]]; then
    case "$security" in
      open|wpapsk|wpaeap|wep) ;;
      *) error "WiFi '$wifi_name': invalid security type '$security'" ;;
    esac
  fi

  # Validate wpa_mode
  wpa_mode=$(echo "$wifi" | jq -r '.wpa_mode // empty')
  if [[ -n "$wpa_mode" ]] && [[ "$wpa_mode" != "null" ]]; then
    case "$wpa_mode" in
      wpa1|wpa2|wpa3|auto) ;;
      *) error "WiFi '$wifi_name': invalid wpa_mode '$wpa_mode'" ;;
    esac
  fi

  # Validate field names
  for field in $(echo "$wifi" | jq -r 'keys[]'); do
    [[ "$field" == "_"* ]] && continue
    if ! echo "$VALID_WIFI_FIELDS" | grep -qxF "$field"; then
      warn "WiFi '$wifi_name': unknown field '$field' (not in MongoDB schema)"
    fi
  done
done

# =============================================================================
# Validate Firewall Rules
# =============================================================================
echo "  Checking firewall rules..."

for rule_name in $(echo "$CONFIG" | jq -r '.firewallRules // {} | keys[]'); do
  rule=$(echo "$CONFIG" | jq -c ".firewallRules[\"$rule_name\"]")

  # Check action is valid
  action=$(echo "$rule" | jq -r '.action // empty')
  if [[ -n "$action" ]] && [[ "$action" != "null" ]]; then
    case "$action" in
      accept|drop|reject) ;;
      *) error "Firewall rule '$rule_name': invalid action '$action'" ;;
    esac
  fi

  # Check protocol is valid
  protocol=$(echo "$rule" | jq -r '.protocol // empty')
  if [[ -n "$protocol" ]] && [[ "$protocol" != "null" ]]; then
    case "$protocol" in
      all|tcp|udp|tcp_udp|icmp|gre|esp|ah|sctp) ;;
      *) error "Firewall rule '$rule_name': invalid protocol '$protocol'" ;;
    esac
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

  if [[ -z "$dst_port" ]] || [[ "$dst_port" == "null" ]]; then
    error "Port forward '$pf_name': missing required field 'dst_port'"
  fi

  if [[ -z "$fwd_ip" ]] || [[ "$fwd_ip" == "null" ]]; then
    error "Port forward '$pf_name': missing required field 'fwd' (destination IP)"
  fi

  # Validate IP address format
  if [[ -n "$fwd_ip" ]] && [[ "$fwd_ip" != "null" ]]; then
    if ! echo "$fwd_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      error "Port forward '$pf_name': invalid IP address '$fwd_ip'"
    fi
  fi

  # Validate port range (1-65535)
  if [[ -n "$dst_port" ]] && [[ "$dst_port" != "null" ]]; then
    if [[ "$dst_port" -lt 1 ]] || [[ "$dst_port" -gt 65535 ]] 2>/dev/null; then
      error "Port forward '$pf_name': invalid dst_port '$dst_port' (must be 1-65535)"
    fi
  fi

  if [[ -n "$fwd_port" ]] && [[ "$fwd_port" != "null" ]]; then
    if [[ "$fwd_port" -lt 1 ]] || [[ "$fwd_port" -gt 65535 ]] 2>/dev/null; then
      error "Port forward '$pf_name': invalid fwd_port '$fwd_port' (must be 1-65535)"
    fi
  fi

  # Check protocol
  proto=$(echo "$pf" | jq -r '.proto // empty')
  if [[ -n "$proto" ]] && [[ "$proto" != "null" ]]; then
    case "$proto" in
      tcp|udp|tcp_udp) ;;
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
  ip=$(echo "$res" | jq -r '.fixed_ip // empty')

  if [[ -z "$mac" ]] || [[ "$mac" == "null" ]]; then
    error "DHCP reservation '$res_name': missing required field 'mac'"
  fi

  if [[ -z "$ip" ]] || [[ "$ip" == "null" ]]; then
    error "DHCP reservation '$res_name': missing required field 'fixed_ip'"
  fi

  # Validate MAC address format
  if [[ -n "$mac" ]] && [[ "$mac" != "null" ]]; then
    if ! echo "$mac" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
      error "DHCP reservation '$res_name': invalid MAC address '$mac' (expected xx:xx:xx:xx:xx:xx)"
    fi
  fi

  # Validate IP address format
  if [[ -n "$ip" ]] && [[ "$ip" != "null" ]]; then
    if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      error "DHCP reservation '$res_name': invalid IP address '$ip'"
    fi
  fi

  # Check network reference exists
  net_name=$(echo "$res" | jq -r '._network_name // empty')
  if [[ -n "$net_name" ]] && [[ "$net_name" != "null" ]]; then
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
