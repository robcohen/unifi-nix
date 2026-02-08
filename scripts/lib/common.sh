#!/usr/bin/env bash
# common.sh - Shared library for unifi-nix scripts
# Source this file: source "$(dirname "$0")/lib/common.sh"

# =============================================================================
# Constants
# =============================================================================

# MongoDB port on UniFi devices
readonly UNIFI_MONGO_PORT="${UNIFI_MONGO_PORT:-27117}"

# Default SSH user for UDM/UDMP
readonly UNIFI_SSH_USER="${SSH_USER:-root}"

# SSH connection timeout
readonly UNIFI_SSH_TIMEOUT="${SSH_TIMEOUT:-10}"

# Default DHCP lease time (24 hours) - exported for use by sourcing scripts
export UNIFI_DEFAULT_LEASE_TIME=86400

# Valid VLAN range
readonly UNIFI_VLAN_MIN=1
readonly UNIFI_VLAN_MAX=4094

# Valid firewall zones
readonly UNIFI_ZONES=("internal" "external" "gateway" "vpn" "hotspot" "dmz")

# Backup directory - exported for use by sourcing scripts
export UNIFI_BACKUP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/unifi-nix/backups"

# Cache directory - exported for use by sourcing scripts
export UNIFI_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/unifi-nix"

# =============================================================================
# Colors and Output
# =============================================================================

# Check if stdout is a terminal
if [[ -t 1 ]]; then
  readonly COLOR_RED='\033[0;31m'
  readonly COLOR_GREEN='\033[0;32m'
  readonly COLOR_YELLOW='\033[0;33m'
  readonly COLOR_BLUE='\033[0;34m'
  readonly COLOR_CYAN='\033[0;36m'
  readonly COLOR_RESET='\033[0m'
  readonly COLOR_BOLD='\033[1m'
else
  readonly COLOR_RED=''
  readonly COLOR_GREEN=''
  readonly COLOR_YELLOW=''
  readonly COLOR_BLUE=''
  readonly COLOR_CYAN=''
  readonly COLOR_RESET=''
  readonly COLOR_BOLD=''
fi

# Print colored output
log_info() {
  echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
  echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" >&2
}

log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_step() {
  echo -e "${COLOR_CYAN}==>${COLOR_RESET} ${COLOR_BOLD}$*${COLOR_RESET}"
}

# Progress indicator for long operations
show_progress() {
  local message="$1"
  local pid="$2"
  local delay=0.1
  local spinstr='|/-\\'

  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c] %s\r" "$spinstr" "$message"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
  done
  printf "    %s\n" "$message"
}

# =============================================================================
# SSH Helpers
# =============================================================================

# Get SSH options with optional host key file
get_ssh_opts() {
  local host="$1"
  local opts="-o ConnectTimeout=${UNIFI_SSH_TIMEOUT}"
  opts+=" -o BatchMode=yes"

  # Check for pinned host keys
  local known_hosts="${UNIFI_KNOWN_HOSTS:-}"
  if [[ -n $known_hosts ]] && [[ -f $known_hosts ]]; then
    opts+=" -o UserKnownHostsFile=$known_hosts"
    opts+=" -o StrictHostKeyChecking=yes"
  else
    # Accept new keys but warn
    opts+=" -o StrictHostKeyChecking=accept-new"
  fi

  echo "$opts"
}

# Test SSH connectivity with detailed error reporting
test_ssh() {
  local host="$1"
  local user="${2:-$UNIFI_SSH_USER}"
  local opts
  opts=$(get_ssh_opts "$host")

  # shellcheck disable=SC2086
  local ssh_output
  local ssh_exit
  ssh_output=$(ssh $opts "$user@$host" "echo ok" 2>&1)
  ssh_exit=$?

  if [[ $ssh_exit -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Test SSH with helpful error messages
test_ssh_verbose() {
  local host="$1"
  local user="${2:-$UNIFI_SSH_USER}"
  local opts
  opts=$(get_ssh_opts "$host")

  # First check if host is reachable
  if ! ping -c 1 -W 2 "$host" &>/dev/null; then
    log_error "Cannot reach host '$host' - check network connectivity"
    log_info "Suggestions:"
    log_info "  1. Verify the IP address/hostname is correct"
    log_info "  2. Check that the device is powered on"
    log_info "  3. Ensure no firewall is blocking access"
    return 1
  fi

  # Try SSH connection
  # shellcheck disable=SC2086
  local ssh_output
  local ssh_exit
  ssh_output=$(ssh $opts -v "$user@$host" "echo ok" 2>&1)
  ssh_exit=$?

  if [[ $ssh_exit -eq 0 ]]; then
    return 0
  fi

  # Analyze the error
  if echo "$ssh_output" | grep -q "Permission denied"; then
    log_error "SSH authentication failed for $user@$host"
    log_info "Suggestions:"
    log_info "  1. Ensure SSH is enabled on UDM (Settings > System > SSH)"
    log_info "  2. Add your SSH key: ssh-copy-id $user@$host"
    log_info "  3. Verify the correct SSH key is being used"
  elif echo "$ssh_output" | grep -q "Connection refused"; then
    log_error "SSH connection refused by $host"
    log_info "Suggestions:"
    log_info "  1. Enable SSH in UniFi settings (Settings > System > SSH)"
    log_info "  2. Check that SSH port 22 is not blocked"
  elif echo "$ssh_output" | grep -q "Connection timed out"; then
    log_error "SSH connection timed out to $host"
    log_info "Suggestions:"
    log_info "  1. Verify the device is fully booted (can take 5+ minutes)"
    log_info "  2. Check network path to the device"
    log_info "  3. Increase timeout: SSH_TIMEOUT=30 unifi ..."
  elif echo "$ssh_output" | grep -q "Host key verification failed"; then
    log_error "SSH host key verification failed for $host"
    log_info "Suggestions:"
    log_info "  1. The device may have been reset/replaced"
    log_info "  2. Remove old key: ssh-keygen -R $host"
    log_info "  3. Or use key pinning: UNIFI_KNOWN_HOSTS=./known_hosts"
  elif echo "$ssh_output" | grep -q "No route to host"; then
    log_error "No route to host $host"
    log_info "Suggestions:"
    log_info "  1. Check your network configuration"
    log_info "  2. Verify VPN connection if accessing remotely"
    log_info "  3. Check firewall rules"
  else
    log_error "SSH connection failed to $user@$host (exit code: $ssh_exit)"
    log_info "Run with SSH_DEBUG=1 for more details"
    if [[ ${SSH_DEBUG:-} == "1" ]]; then
      echo "$ssh_output" | head -50
    fi
  fi

  return 1
}

# Run command via SSH
run_ssh() {
  local host="$1"
  local cmd="$2"
  local user="${3:-$UNIFI_SSH_USER}"
  local opts
  opts=$(get_ssh_opts "$host")

  # shellcheck disable=SC2086,SC2029
  ssh $opts "$user@$host" "$cmd"
}

# =============================================================================
# MongoDB Helpers
# =============================================================================

# Run MongoDB command on UniFi device
run_mongo() {
  local host="$1"
  local cmd="$2"
  local user="${3:-$UNIFI_SSH_USER}"

  run_ssh "$host" "mongo --quiet --port ${UNIFI_MONGO_PORT} ace --eval '$cmd'" "$user"
}

# Test MongoDB connectivity
test_mongo() {
  local host="$1"
  local user="${2:-$UNIFI_SSH_USER}"

  if run_mongo "$host" "db.stats()" "$user" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Get site ID from MongoDB
get_site_id() {
  local host="$1"
  local site_name="${2:-default}"
  local user="${3:-$UNIFI_SSH_USER}"

  local site_info
  site_info=$(run_mongo "$host" "JSON.stringify(db.site.findOne({name: \"$site_name\"}))" "$user")
  echo "$site_info" | jq -r '._id."$oid"'
}

# =============================================================================
# Validation Helpers
# =============================================================================

# Validate VLAN ID
validate_vlan() {
  local vlan="$1"
  if [[ $vlan -lt $UNIFI_VLAN_MIN ]] || [[ $vlan -gt $UNIFI_VLAN_MAX ]]; then
    log_error "Invalid VLAN ID: $vlan (must be $UNIFI_VLAN_MIN-$UNIFI_VLAN_MAX)"
    return 1
  fi
  return 0
}

# Validate MAC address
validate_mac() {
  local mac="$1"
  local mac_regex='^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
  if [[ ! $mac =~ $mac_regex ]]; then
    log_error "Invalid MAC address: $mac"
    return 1
  fi
  return 0
}

# Validate IP address
validate_ip() {
  local ip="$1"
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if [[ ! $ip =~ $ip_regex ]]; then
    log_error "Invalid IP address: $ip"
    return 1
  fi

  # Check each octet
  IFS='.' read -ra octets <<<"$ip"
  for octet in "${octets[@]}"; do
    if [[ $octet -gt 255 ]]; then
      log_error "Invalid IP address: $ip (octet $octet > 255)"
      return 1
    fi
  done
  return 0
}

# Validate CIDR notation
validate_cidr() {
  local cidr="$1"
  local cidr_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
  if [[ ! $cidr =~ $cidr_regex ]]; then
    log_error "Invalid CIDR: $cidr"
    return 1
  fi

  local ip="${cidr%/*}"
  local prefix="${cidr#*/}"

  validate_ip "$ip" || return 1

  if [[ $prefix -lt 0 ]] || [[ $prefix -gt 32 ]]; then
    log_error "Invalid CIDR prefix: /$prefix (must be 0-32)"
    return 1
  fi
  return 0
}

# Validate zone name
validate_zone() {
  local zone="$1"
  for valid_zone in "${UNIFI_ZONES[@]}"; do
    if [[ $zone == "$valid_zone" ]]; then
      return 0
    fi
  done
  log_error "Invalid zone: $zone (valid: ${UNIFI_ZONES[*]})"
  return 1
}

# =============================================================================
# File Helpers
# =============================================================================

# Ensure directory exists
ensure_dir() {
  local dir="$1"
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir" || {
      log_error "Failed to create directory: $dir"
      return 1
    }
  fi
}

# Create timestamped backup filename
backup_filename() {
  local host="$1"
  local prefix="${2:-backup}"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  echo "${prefix}-${timestamp}-${host}.json"
}

# =============================================================================
# Secret Resolution
# =============================================================================

# Resolve a secret from file or environment variable
resolve_secret() {
  local secret_path="$1"
  local resolved=""

  # Try file in secrets directory
  if [[ -n ${UNIFI_SECRETS_DIR:-} ]] && [[ -f "${UNIFI_SECRETS_DIR}/${secret_path}" ]]; then
    resolved=$(cat "${UNIFI_SECRETS_DIR}/${secret_path}")
  else
    # Fall back to environment variable (path/to/secret -> PATH_TO_SECRET)
    local env_var
    env_var=$(echo "$secret_path" | tr '/' '_' | tr '[:lower:]' '[:upper:]')
    resolved="${!env_var:-}"
  fi

  echo "$resolved"
}

# Resolve JSON secret (handles both string and {_secret: path} format)
resolve_json_secret() {
  local json_value="$1"
  local field_name="${2:-secret}"

  # Check if it's a secret reference object
  if echo "$json_value" | jq -e '._secret' >/dev/null 2>&1; then
    local secret_path
    secret_path=$(echo "$json_value" | jq -r '._secret')
    local resolved
    resolved=$(resolve_secret "$secret_path")

    if [[ -z $resolved ]]; then
      log_error "Could not resolve $field_name secret '$secret_path'"
      log_error "Set UNIFI_SECRETS_DIR or environment variable: $(echo "$secret_path" | tr '/' '_' | tr '[:lower:]' '[:upper:]')"
      return 1
    fi

    echo "$resolved"
  else
    # Plain string value
    echo "$json_value" | jq -r '.'
  fi
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Run all pre-flight checks
preflight_check() {
  local host="$1"
  local config_file="${2:-}"
  local user="${3:-$UNIFI_SSH_USER}"
  local errors=0

  log_step "Running pre-flight checks..."

  # Check SSH connectivity
  echo -n "  SSH connectivity... "
  if test_ssh "$host" "$user"; then
    echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}FAILED${COLOR_RESET}"
    # Run verbose check for detailed error messages
    test_ssh_verbose "$host" "$user"
    ((errors++))
  fi

  # Check MongoDB connectivity
  echo -n "  MongoDB connectivity... "
  if test_mongo "$host" "$user"; then
    echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}FAILED${COLOR_RESET}"
    log_error "Cannot connect to MongoDB on port $UNIFI_MONGO_PORT"
    log_error "Ensure the UDM has fully booted and MongoDB is running"
    ((errors++))
  fi

  # Check config file if provided
  if [[ -n $config_file ]]; then
    echo -n "  Config file... "
    if [[ -f $config_file ]]; then
      echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
    else
      echo -e "${COLOR_RED}FAILED${COLOR_RESET}"
      log_error "Config file not found: $config_file"
      ((errors++))
    fi
  fi

  # Check for required tools
  echo -n "  Required tools... "
  local missing_tools=()
  for tool in jq ssh mongo; do
    if ! command -v "$tool" &>/dev/null; then
      missing_tools+=("$tool")
    fi
  done

  if [[ ${#missing_tools[@]} -eq 0 ]]; then
    echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}FAILED${COLOR_RESET}"
    log_error "Missing required tools: ${missing_tools[*]}"
    ((errors++))
  fi

  echo ""
  if [[ $errors -gt 0 ]]; then
    log_error "Pre-flight checks failed with $errors error(s)"
    return 1
  else
    log_success "All pre-flight checks passed"
    return 0
  fi
}
