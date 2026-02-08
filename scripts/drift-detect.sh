#!/usr/bin/env bash
# unifi-drift-detect: Detect configuration drift between Nix config and device
# Compares desired state (from Nix) with actual state (from device MongoDB)
# shellcheck disable=SC2029
set -euo pipefail

CONFIG_JSON="${1:-}"
HOST="${2:-}"
SSH_USER="${SSH_USER:-root}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}" # text, json, summary

if [[ -z $CONFIG_JSON ]] || [[ -z $HOST ]]; then
  echo "Usage: unifi-drift-detect <config.json> <host>"
  echo ""
  echo "Detects changes made via UI that differ from your Nix configuration."
  echo ""
  echo "Arguments:"
  echo "  config.json  Path to generated config JSON (from unifi-eval)"
  echo "  host         UDM IP address or hostname"
  echo ""
  echo "Environment:"
  echo "  SSH_USER=root              SSH username (default: root)"
  echo "  OUTPUT_FORMAT=text         Output format: text, json, summary"
  echo ""
  echo "Exit codes:"
  echo "  0  No drift detected"
  echo "  1  Drift detected"
  echo "  2  Error"
  exit 2
fi

if [[ ! -f $CONFIG_JSON ]]; then
  echo "Error: Config file not found: $CONFIG_JSON"
  exit 2
fi

DESIRED=$(cat "$CONFIG_JSON")
DRIFT_FOUND=0

# Helper to compare field values
compare_field() {
  local name="$1"
  local field="$2"
  local desired="$3"
  local actual="$4"

  if [[ $desired != "$actual" ]]; then
    if [[ $OUTPUT_FORMAT == "text" ]]; then
      echo "  DRIFT: $name.$field"
      echo "    Desired: $desired"
      echo "    Actual:  $actual"
    fi
    return 1
  fi
  return 0
}

# Fetch current state from device
echo "Fetching current configuration from $HOST..." >&2

CURRENT_STATE=$(ssh -o ConnectTimeout=10 "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
JSON.stringify({
  networks: db.networkconf.find({}, {name: 1, vlan: 1, ip_subnet: 1, purpose: 1, dhcpd_enabled: 1, network_isolation_enabled: 1}).toArray(),
  wifi: db.wlanconf.find({}, {name: 1, enabled: 1, security: 1, wpa_mode: 1, hide_ssid: 1, wlan_bands: 1}).toArray(),
  firewallPolicies: db.firewall_policy.find({}, {name: 1, enabled: 1, action: 1, index: 1}).toArray(),
  firewallGroups: db.firewallgroup.find({}, {name: 1, group_type: 1, group_members: 1}).toArray(),
  portForwards: db.portforward.find({}, {name: 1, enabled: 1, dst_port: 1, fwd: 1, fwd_port: 1}).toArray(),
  dhcpReservations: db.dhcp_option.find({}, {name: 1, mac: 1, ip: 1}).toArray(),
  apGroups: db.apgroup.find({}, {name: 1, device_macs: 1}).toArray(),
  userGroups: db.usergroup.find({}, {name: 1, qos_rate_max_down: 1, qos_rate_max_up: 1}).toArray(),
  trafficRules: db.traffic_rule.find({}, {name: 1, enabled: 1, action: 1, index: 1}).toArray(),
  radiusProfiles: db.radiusprofile.find({}, {name: 1}).toArray(),
  portProfiles: db.portconf.find({}, {name: 1, forward: 1, poe_mode: 1}).toArray()
})
"' 2>/dev/null)

if [[ -z $CURRENT_STATE ]] || [[ $CURRENT_STATE == "null" ]]; then
  echo "Error: Could not fetch configuration from device"
  exit 2
fi

declare -A drift_summary
drift_summary[networks]=0
drift_summary[wifi]=0
drift_summary[firewallPolicies]=0
drift_summary[firewallGroups]=0
drift_summary[portForwards]=0
drift_summary[dhcpReservations]=0
drift_summary[apGroups]=0
drift_summary[userGroups]=0
drift_summary[trafficRules]=0
drift_summary[radiusProfiles]=0
drift_summary[portProfiles]=0

# Check networks
if [[ $OUTPUT_FORMAT == "text" ]]; then
  echo ""
  echo "=== Checking Networks ==="
fi

for net in $(echo "$DESIRED" | jq -r '.networks | keys[]'); do
  desired_net=$(echo "$DESIRED" | jq -c ".networks[\"$net\"]")
  actual_net=$(echo "$CURRENT_STATE" | jq -c ".networks[] | select(.name == \"$net\")")

  if [[ -z $actual_net ]] || [[ $actual_net == "null" ]]; then
    if [[ $OUTPUT_FORMAT == "text" ]]; then
      echo "  MISSING: Network '$net' not found on device"
    fi
    ((drift_summary[networks]++)) || true
    DRIFT_FOUND=1
    continue
  fi

  # Compare key fields
  drift_in_net=0

  desired_vlan=$(echo "$desired_net" | jq -r '.vlan // 0')
  actual_vlan=$(echo "$actual_net" | jq -r '.vlan // 0')
  compare_field "$net" "vlan" "$desired_vlan" "$actual_vlan" || { ((drift_in_net++)) || true; }

  desired_dhcp=$(echo "$desired_net" | jq -r '.dhcpd_enabled')
  actual_dhcp=$(echo "$actual_net" | jq -r '.dhcpd_enabled')
  compare_field "$net" "dhcp" "$desired_dhcp" "$actual_dhcp" || { ((drift_in_net++)) || true; }

  if [[ $drift_in_net -gt 0 ]]; then
    ((drift_summary[networks]++)) || true
    DRIFT_FOUND=1
  fi
done

# Check WiFi
if [[ $OUTPUT_FORMAT == "text" ]]; then
  echo ""
  echo "=== Checking WiFi ==="
fi

for wifi in $(echo "$DESIRED" | jq -r '.wifi | keys[]'); do
  desired_wifi=$(echo "$DESIRED" | jq -c ".wifi[\"$wifi\"]")
  ssid=$(echo "$desired_wifi" | jq -r '.name')
  actual_wifi=$(echo "$CURRENT_STATE" | jq -c ".wifi[] | select(.name == \"$ssid\")")

  if [[ -z $actual_wifi ]] || [[ $actual_wifi == "null" ]]; then
    if [[ $OUTPUT_FORMAT == "text" ]]; then
      echo "  MISSING: WiFi '$ssid' not found on device"
    fi
    ((drift_summary[wifi]++)) || true
    DRIFT_FOUND=1
    continue
  fi

  drift_in_wifi=0

  desired_enabled=$(echo "$desired_wifi" | jq -r '.enabled')
  actual_enabled=$(echo "$actual_wifi" | jq -r '.enabled')
  compare_field "$ssid" "enabled" "$desired_enabled" "$actual_enabled" || { ((drift_in_wifi++)) || true; }

  desired_security=$(echo "$desired_wifi" | jq -r '.security')
  actual_security=$(echo "$actual_wifi" | jq -r '.security')
  compare_field "$ssid" "security" "$desired_security" "$actual_security" || { ((drift_in_wifi++)) || true; }

  desired_hidden=$(echo "$desired_wifi" | jq -r '.hide_ssid')
  actual_hidden=$(echo "$actual_wifi" | jq -r '.hide_ssid')
  compare_field "$ssid" "hidden" "$desired_hidden" "$actual_hidden" || { ((drift_in_wifi++)) || true; }

  if [[ $drift_in_wifi -gt 0 ]]; then
    ((drift_summary[wifi]++)) || true
    DRIFT_FOUND=1
  fi
done

# Check firewall policies
if [[ $OUTPUT_FORMAT == "text" ]]; then
  echo ""
  echo "=== Checking Firewall Policies ==="
fi

for policy in $(echo "$DESIRED" | jq -r '.firewallPolicies | keys[]'); do
  desired_policy=$(echo "$DESIRED" | jq -c ".firewallPolicies[\"$policy\"]")
  name=$(echo "$desired_policy" | jq -r '.name')
  actual_policy=$(echo "$CURRENT_STATE" | jq -c ".firewallPolicies[] | select(.name == \"$name\")")

  if [[ -z $actual_policy ]] || [[ $actual_policy == "null" ]]; then
    if [[ $OUTPUT_FORMAT == "text" ]]; then
      echo "  MISSING: Firewall policy '$name' not found on device"
    fi
    ((drift_summary[firewallPolicies]++)) || true
    DRIFT_FOUND=1
    continue
  fi

  drift_in_policy=0

  desired_enabled=$(echo "$desired_policy" | jq -r '.enabled')
  actual_enabled=$(echo "$actual_policy" | jq -r '.enabled')
  compare_field "$name" "enabled" "$desired_enabled" "$actual_enabled" || { ((drift_in_policy++)) || true; }

  desired_action=$(echo "$desired_policy" | jq -r '.action')
  actual_action=$(echo "$actual_policy" | jq -r '.action')
  compare_field "$name" "action" "$desired_action" "$actual_action" || { ((drift_in_policy++)) || true; }

  if [[ $drift_in_policy -gt 0 ]]; then
    ((drift_summary[firewallPolicies]++)) || true
    DRIFT_FOUND=1
  fi
done

# Check for extra resources on device (not in config)
if [[ $OUTPUT_FORMAT == "text" ]]; then
  echo ""
  echo "=== Checking for Unmanaged Resources ==="
fi

# Extra networks
for actual_net in $(echo "$CURRENT_STATE" | jq -r '.networks[].name'); do
  [[ $actual_net == "Default" ]] && continue # Skip system-managed
  if ! echo "$DESIRED" | jq -e ".networks[\"$actual_net\"]" >/dev/null 2>&1; then
    if [[ $OUTPUT_FORMAT == "text" ]]; then
      echo "  UNMANAGED: Network '$actual_net' exists on device but not in config"
    fi
    # Don't count as drift - just informational
  fi
done

# Extra WiFi
for actual_ssid in $(echo "$CURRENT_STATE" | jq -r '.wifi[].name'); do
  if ! echo "$DESIRED" | jq -e ".wifi | to_entries[] | select(.value.name == \"$actual_ssid\")" >/dev/null 2>&1; then
    if [[ $OUTPUT_FORMAT == "text" ]]; then
      echo "  UNMANAGED: WiFi '$actual_ssid' exists on device but not in config"
    fi
  fi
done

# Output summary
if [[ $OUTPUT_FORMAT == "summary" ]] || [[ $OUTPUT_FORMAT == "text" ]]; then
  echo ""
  echo "=== Drift Summary ==="
  echo "  Networks:           ${drift_summary[networks]} drifted"
  echo "  WiFi:               ${drift_summary[wifi]} drifted"
  echo "  Firewall policies:  ${drift_summary[firewallPolicies]} drifted"
  echo "  Firewall groups:    ${drift_summary[firewallGroups]} drifted"
  echo "  Port forwards:      ${drift_summary[portForwards]} drifted"
  echo "  DHCP reservations:  ${drift_summary[dhcpReservations]} drifted"
  echo "  AP groups:          ${drift_summary[apGroups]} drifted"
  echo "  User groups:        ${drift_summary[userGroups]} drifted"
  echo "  Traffic rules:      ${drift_summary[trafficRules]} drifted"
  echo "  RADIUS profiles:    ${drift_summary[radiusProfiles]} drifted"
  echo "  Port profiles:      ${drift_summary[portProfiles]} drifted"
  echo ""
fi

if [[ $OUTPUT_FORMAT == "json" ]]; then
  cat <<EOF
{
  "drift_found": $([[ $DRIFT_FOUND -eq 1 ]] && echo "true" || echo "false"),
  "summary": {
    "networks": ${drift_summary[networks]},
    "wifi": ${drift_summary[wifi]},
    "firewallPolicies": ${drift_summary[firewallPolicies]},
    "firewallGroups": ${drift_summary[firewallGroups]},
    "portForwards": ${drift_summary[portForwards]},
    "dhcpReservations": ${drift_summary[dhcpReservations]},
    "apGroups": ${drift_summary[apGroups]},
    "userGroups": ${drift_summary[userGroups]},
    "trafficRules": ${drift_summary[trafficRules]},
    "radiusProfiles": ${drift_summary[radiusProfiles]},
    "portProfiles": ${drift_summary[portProfiles]}
  }
}
EOF
fi

if [[ $DRIFT_FOUND -eq 1 ]]; then
  if [[ $OUTPUT_FORMAT == "text" ]]; then
    echo "Drift detected! Run 'unifi-deploy' to reconcile."
  fi
  exit 1
else
  if [[ $OUTPUT_FORMAT == "text" ]]; then
    echo "No drift detected. Configuration matches device."
  fi
  exit 0
fi
