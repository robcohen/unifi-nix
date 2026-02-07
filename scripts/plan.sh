#!/usr/bin/env bash
# unifi-plan: Show full plan including deletions
set -euo pipefail

CONFIG_JSON="${1:-}"
HOST="${2:-}"
SSH_USER="${SSH_USER:-root}"

if [[ -z $CONFIG_JSON ]] || [[ -z $HOST ]]; then
  echo "Usage: unifi-plan <config.json> <host>"
  echo ""
  echo "Shows what changes would be made, including deletions."
  echo "Use 'unifi-apply' to apply the changes."
  echo ""
  echo "Environment:"
  echo "  SSH_USER=root  SSH username (default: root)"
  exit 1
fi

if [[ ! -f $CONFIG_JSON ]]; then
  echo "Error: Config file not found: $CONFIG_JSON"
  exit 1
fi

echo "=== UniFi Configuration Plan ==="
echo "Host: $HOST"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DESIRED=$(cat "$CONFIG_JSON")

# Fetch current state
echo "Fetching current configuration..."
CURRENT=$(ssh -o ConnectTimeout=10 "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
JSON.stringify({
  networks: db.networkconf.find({}, {name: 1, ip_subnet: 1, vlan: 1, purpose: 1}).toArray(),
  wifi: db.wlanconf.find({}, {name: 1, enabled: 1}).toArray(),
  firewallRules: db.traffic_rule.find({}, {description: 1, action: 1, enabled: 1}).toArray()
})
"')

# Track counts
CREATES=0
UPDATES=0
DELETES=0

echo ""
echo -e "${BLUE}=== Networks ===${NC}"

# Get desired and current network names
desired_networks=$(echo "$DESIRED" | jq -r '.networks | keys[]' | sort)
current_networks=$(echo "$CURRENT" | jq -r '.networks[].name' | sort)

# Check for creates and updates
for net in $desired_networks; do
  if echo "$current_networks" | grep -qx "$net"; then
    echo -e "  ${YELLOW}~${NC} $net (update)"
    ((UPDATES++)) || true
  else
    echo -e "  ${GREEN}+${NC} $net (create)"
    subnet=$(echo "$DESIRED" | jq -r ".networks[\"$net\"].ip_subnet")
    echo "      subnet: $subnet"
    ((CREATES++)) || true
  fi
done

# Check for deletes
for net in $current_networks; do
  # Skip system networks
  [[ $net == "Default" ]] && continue

  if ! echo "$desired_networks" | grep -qx "$net"; then
    echo -e "  ${RED}-${NC} $net (delete)"
    ((DELETES++)) || true
  fi
done

echo ""
echo -e "${BLUE}=== WiFi Networks ===${NC}"

# Get desired and current SSID names
desired_ssids=$(echo "$DESIRED" | jq -r '.wifi[].name' | sort)
current_ssids=$(echo "$CURRENT" | jq -r '.wifi[].name' | sort)

for ssid in $desired_ssids; do
  if echo "$current_ssids" | grep -qxF "$ssid"; then
    echo -e "  ${YELLOW}~${NC} $ssid (update)"
    ((UPDATES++)) || true
  else
    echo -e "  ${GREEN}+${NC} $ssid (create)"
    ((CREATES++)) || true
  fi
done

for ssid in $current_ssids; do
  if ! echo "$desired_ssids" | grep -qxF "$ssid"; then
    echo -e "  ${RED}-${NC} $ssid (delete)"
    ((DELETES++)) || true
  fi
done

echo ""
echo -e "${BLUE}=== Firewall Rules ===${NC}"

# Get desired and current rule descriptions (handle multi-word descriptions)
desired_rules_json=$(echo "$DESIRED" | jq -c '[.firewallRules[].description]')
current_rules_json=$(echo "$CURRENT" | jq -c '[.firewallRules[].description // empty | select(. != "")]')

# Check creates/updates for desired rules
echo "$DESIRED" | jq -r '.firewallRules[].description' | while IFS= read -r rule; do
  [[ -z $rule ]] && continue
  if echo "$current_rules_json" | jq -e --arg r "$rule" 'index($r) != null' >/dev/null; then
    echo -e "  ${YELLOW}~${NC} $rule (update)"
  else
    echo -e "  ${GREEN}+${NC} $rule (create)"
  fi
done

# Check deletes for current rules not in desired
echo "$CURRENT" | jq -r '.firewallRules[].description // empty' | while IFS= read -r rule; do
  [[ -z $rule ]] && continue
  if ! echo "$desired_rules_json" | jq -e --arg r "$rule" 'index($r) != null' >/dev/null; then
    echo -e "  ${RED}-${NC} $rule (delete)"
  fi
done

# Count actual changes by re-analyzing
total_creates=0
total_updates=0
total_deletes=0

# Count network changes
for net in $desired_networks; do
  if echo "$current_networks" | grep -qx "$net"; then
    ((total_updates++)) || true
  else
    ((total_creates++)) || true
  fi
done
for net in $current_networks; do
  [[ $net == "Default" ]] && continue
  if ! echo "$desired_networks" | grep -qx "$net"; then
    ((total_deletes++)) || true
  fi
done

# Count WiFi changes
for ssid in $desired_ssids; do
  if echo "$current_ssids" | grep -qxF "$ssid"; then
    ((total_updates++)) || true
  else
    ((total_creates++)) || true
  fi
done
for ssid in $current_ssids; do
  if ! echo "$desired_ssids" | grep -qxF "$ssid"; then
    ((total_deletes++)) || true
  fi
done

# Count firewall changes
while IFS= read -r rule; do
  [[ -z $rule ]] && continue
  if echo "$current_rules_json" | jq -e --arg r "$rule" 'index($r) != null' >/dev/null; then
    ((total_updates++)) || true
  else
    ((total_creates++)) || true
  fi
done < <(echo "$DESIRED" | jq -r '.firewallRules[].description')

while IFS= read -r rule; do
  [[ -z $rule ]] && continue
  if ! echo "$desired_rules_json" | jq -e --arg r "$rule" 'index($r) != null' >/dev/null; then
    ((total_deletes++)) || true
  fi
done < <(echo "$CURRENT" | jq -r '.firewallRules[].description // empty')

echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}Creates:${NC} $total_creates"
echo -e "  ${YELLOW}Updates:${NC} $total_updates"
echo -e "  ${RED}Deletes:${NC} $total_deletes"
echo ""

if [[ $total_deletes -gt 0 ]]; then
  echo -e "${RED}WARNING:${NC} This plan includes deletions!"
  echo "Run with ALLOW_DELETES=true to apply deletions."
fi
