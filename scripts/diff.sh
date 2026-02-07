#!/usr/bin/env bash
# unifi-diff: Show differences between current UDM config and desired state
set -euo pipefail

CONFIG_JSON="${1:-}"
HOST="${2:-}"
SSH_USER="${SSH_USER:-root}"

if [[ -z "$CONFIG_JSON" ]] || [[ -z "$HOST" ]]; then
  echo "Usage: unifi-diff <config.json> <host>"
  echo ""
  echo "Arguments:"
  echo "  config.json  Path to generated config JSON (from unifi-eval)"
  echo "  host         UDM IP address or hostname"
  echo ""
  echo "Example:"
  echo "  unifi-eval ./sites/mysite.nix > config.json"
  echo "  unifi-diff config.json 192.168.1.1"
  exit 1
fi

if [[ ! -f "$CONFIG_JSON" ]]; then
  echo "Error: Config file not found: $CONFIG_JSON"
  exit 1
fi

echo "=== UniFi Configuration Diff ==="
echo "Host: $HOST"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fetch current state from UDM via SSH+MongoDB
echo "Fetching current configuration..."
CURRENT=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
JSON.stringify({
  networks: db.networkconf.find({}, {
    _id: 0, name: 1, vlan: 1, ip_subnet: 1, dhcpd_enabled: 1,
    dhcpd_start: 1, dhcpd_stop: 1, dhcpd_dns_1: 1, dhcpd_dns_2: 1,
    internet_access_enabled: 1, network_isolation_enabled: 1, enabled: 1
  }).toArray(),
  wifi: db.wlanconf.find({}, {
    _id: 0, name: 1, enabled: 1, hide_ssid: 1, security: 1,
    wpa3_support: 1, l2_isolation: 1, networkconf_id: 1
  }).toArray()
})
"')

DESIRED=$(cat "$CONFIG_JSON")

echo ""
echo -e "${BLUE}=== Networks ===${NC}"

for net in $(echo "$DESIRED" | jq -r '.networks | keys[]'); do
  desired_net=$(echo "$DESIRED" | jq ".networks[\"$net\"]")
  current_net=$(echo "$CURRENT" | jq ".networks[] | select(.name == \"$net\")" 2>/dev/null || echo "null")

  if [[ "$current_net" == "null" ]] || [[ -z "$current_net" ]]; then
    echo -e "${GREEN}+ $net: NEW${NC}"
    echo "    subnet: $(echo "$desired_net" | jq -r '.ip_subnet')"
    echo "    vlan: $(echo "$desired_net" | jq -r '.vlan // "untagged"')"
  else
    changes=""

    d_subnet=$(echo "$desired_net" | jq -r '.ip_subnet')
    c_subnet=$(echo "$current_net" | jq -r '.ip_subnet // ""')
    [[ "$d_subnet" != "$c_subnet" ]] && changes+="    subnet: $c_subnet → $d_subnet\n"

    d_dhcp=$(echo "$desired_net" | jq -r '.dhcpd_enabled')
    c_dhcp=$(echo "$current_net" | jq -r '.dhcpd_enabled // false')
    [[ "$d_dhcp" != "$c_dhcp" ]] && changes+="    dhcp: $c_dhcp → $d_dhcp\n"

    d_dns1=$(echo "$desired_net" | jq -r '.dhcpd_dns_1')
    c_dns1=$(echo "$current_net" | jq -r '.dhcpd_dns_1 // ""')
    [[ "$d_dns1" != "$c_dns1" ]] && [[ -n "$d_dns1" ]] && changes+="    dns: $c_dns1 → $d_dns1\n"

    d_iso=$(echo "$desired_net" | jq -r '.network_isolation_enabled')
    c_iso=$(echo "$current_net" | jq -r '.network_isolation_enabled // false')
    [[ "$d_iso" != "$c_iso" ]] && changes+="    isolation: $c_iso → $d_iso\n"

    if [[ -n "$changes" ]]; then
      echo -e "${YELLOW}~ $net:${NC}"
      echo -e "$changes"
    else
      echo "  $net: (no changes)"
    fi
  fi
done

echo ""
echo -e "${BLUE}=== WiFi ===${NC}"

for wifi in $(echo "$DESIRED" | jq -r '.wifi | keys[]'); do
  desired_wifi=$(echo "$DESIRED" | jq ".wifi[\"$wifi\"]")
  ssid=$(echo "$desired_wifi" | jq -r '.name')
  current_wifi=$(echo "$CURRENT" | jq ".wifi[] | select(.name == \"$ssid\")" 2>/dev/null || echo "null")

  if [[ "$current_wifi" == "null" ]] || [[ -z "$current_wifi" ]]; then
    echo -e "${GREEN}+ $ssid: NEW${NC}"
  else
    changes=""

    d_hidden=$(echo "$desired_wifi" | jq -r '.hide_ssid')
    c_hidden=$(echo "$current_wifi" | jq -r '.hide_ssid // false')
    [[ "$d_hidden" != "$c_hidden" ]] && changes+="    hidden: $c_hidden → $d_hidden\n"

    d_wpa3=$(echo "$desired_wifi" | jq -r '.wpa3_support')
    c_wpa3=$(echo "$current_wifi" | jq -r '.wpa3_support // false')
    [[ "$d_wpa3" != "$c_wpa3" ]] && changes+="    wpa3: $c_wpa3 → $d_wpa3\n"

    if [[ -n "$changes" ]]; then
      echo -e "${YELLOW}~ $ssid:${NC}"
      echo -e "$changes"
    else
      echo "  $ssid: (no changes)"
    fi
  fi
done

echo ""
echo -e "${BLUE}=== Firewall Rules ===${NC}"
rule_count=$(echo "$DESIRED" | jq '.firewallRules | length')
if [[ "$rule_count" -gt 0 ]]; then
  for rule in $(echo "$DESIRED" | jq -r '.firewallRules | keys[]'); do
    r=$(echo "$DESIRED" | jq ".firewallRules[\"$rule\"]")
    action=$(echo "$r" | jq -r '.action')
    src=$(echo "$r" | jq -r '._source_networks | join(", ")')
    dst=$(echo "$r" | jq -r '._dest_networks | join(", ")')
    echo "  $rule: ${action^^} [$src] → [$dst]"
  done
else
  echo "  (none defined)"
fi

echo ""
echo "=== Summary ==="
echo "Networks: $(echo "$DESIRED" | jq '.networks | length')"
echo "WiFi: $(echo "$DESIRED" | jq '.wifi | length')"
echo "Firewall: $rule_count"
