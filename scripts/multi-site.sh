#!/usr/bin/env bash
# unifi-multi-site: Manage multiple UniFi sites from a single config directory
# Usage: unifi-multi-site <command> [sites...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITES_DIR="${UNIFI_SITES_DIR:-./sites}"
COMMAND="${1:-help}"
shift || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
  cat <<EOF
unifi-multi-site - Manage multiple UniFi sites

Usage: unifi-multi-site <command> [sites...]

Commands:
  list              List all configured sites
  status [sites]    Show status of sites (drift detection)
  diff [sites]      Show diff for sites
  deploy [sites]    Deploy configuration to sites
  backup [sites]    Backup sites
  help              Show this help

Arguments:
  sites             Site names to operate on (default: all)

Environment:
  UNIFI_SITES_DIR   Directory containing site configs (default: ./sites)
  PARALLEL=true     Run operations in parallel (default: false)

Site Configuration:
  Each site should have a directory in \$UNIFI_SITES_DIR with:
    - config.nix    Site configuration (imports module.nix)
    - OR config.json  Pre-evaluated JSON config

Example:
  # Directory structure:
  sites/
    home/
      config.nix
    office/
      config.nix
    datacenter/
      config.nix

  # Deploy all sites
  unifi-multi-site deploy

  # Deploy specific sites
  unifi-multi-site deploy home office

  # Check status of all sites
  unifi-multi-site status
EOF
}

# Get list of all sites
get_all_sites() {
  if [[ ! -d $SITES_DIR ]]; then
    log_error "Sites directory not found: $SITES_DIR"
    exit 1
  fi

  find "$SITES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# Get sites to operate on (from args or all)
get_target_sites() {
  if [[ $# -gt 0 ]]; then
    echo "$@"
  else
    get_all_sites
  fi
}

# Get site config path
get_site_config() {
  local site="$1"
  local site_dir="$SITES_DIR/$site"

  if [[ -f "$site_dir/config.json" ]]; then
    echo "$site_dir/config.json"
  elif [[ -f "$site_dir/config.nix" ]]; then
    # Evaluate Nix config to JSON
    local json_path="/tmp/unifi-$site-config.json"
    if nix eval --json -f "$site_dir/config.nix" >"$json_path" 2>/dev/null; then
      echo "$json_path"
    else
      log_error "Failed to evaluate $site_dir/config.nix"
      return 1
    fi
  else
    log_error "No config.nix or config.json found in $site_dir"
    return 1
  fi
}

# Get host from config
get_site_host() {
  local config="$1"
  jq -r '._meta.host // .host // empty' "$config" 2>/dev/null || echo ""
}

# Command: list
cmd_list() {
  log_info "Configured sites in $SITES_DIR:"
  echo ""

  for site in $(get_all_sites); do
    local site_dir="$SITES_DIR/$site"
    local config_type="none"
    local host="unknown"

    if [[ -f "$site_dir/config.json" ]]; then
      config_type="json"
      host=$(jq -r '._meta.host // .host // "unknown"' "$site_dir/config.json" 2>/dev/null || echo "unknown")
    elif [[ -f "$site_dir/config.nix" ]]; then
      config_type="nix"
      host="(evaluate to get host)"
    fi

    printf "  %-20s %s (%s)\n" "$site" "$host" "$config_type"
  done
}

# Command: status
cmd_status() {
  local sites
  sites=$(get_target_sites "$@")
  local has_drift=0

  log_info "Checking status of sites..."
  echo ""

  for site in $sites; do
    echo "=== $site ==="

    local config
    config=$(get_site_config "$site") || continue

    local host
    host=$(get_site_host "$config")
    if [[ -z $host ]]; then
      log_error "Could not determine host for $site"
      continue
    fi

    # Run drift detection
    if OUTPUT_FORMAT=summary "$SCRIPT_DIR/drift-detect.sh" "$config" "$host" 2>/dev/null; then
      log_success "$site: No drift"
    else
      log_warn "$site: Drift detected"
      has_drift=1
    fi
    echo ""
  done

  return $has_drift
}

# Command: diff
cmd_diff() {
  local sites
  sites=$(get_target_sites "$@")

  for site in $sites; do
    echo "=== $site ==="

    local config
    config=$(get_site_config "$site") || continue

    local host
    host=$(get_site_host "$config")
    if [[ -z $host ]]; then
      log_error "Could not determine host for $site"
      continue
    fi

    "$SCRIPT_DIR/diff.sh" "$config" "$host" || true
    echo ""
  done
}

# Command: deploy
cmd_deploy() {
  local sites
  sites=$(get_target_sites "$@")
  local failed=0

  log_info "Deploying to sites..."
  echo ""

  for site in $sites; do
    echo "=== Deploying: $site ==="

    local config
    config=$(get_site_config "$site") || {
      ((failed++)) || true
      continue
    }

    local host
    host=$(get_site_host "$config")
    if [[ -z $host ]]; then
      log_error "Could not determine host for $site"
      ((failed++)) || true
      continue
    fi

    if AUTO_CONFIRM=true "$SCRIPT_DIR/deploy.sh" "$config" "$host"; then
      log_success "$site: Deployed successfully"
    else
      log_error "$site: Deploy failed"
      ((failed++)) || true
    fi
    echo ""
  done

  if [[ $failed -gt 0 ]]; then
    log_error "$failed site(s) failed to deploy"
    return 1
  fi

  log_success "All sites deployed successfully"
}

# Command: backup
cmd_backup() {
  local sites
  sites=$(get_target_sites "$@")
  local backup_dir="${UNIFI_BACKUP_DIR:-$HOME/.local/share/unifi-nix/backups}"

  log_info "Backing up sites to $backup_dir..."
  echo ""

  for site in $sites; do
    echo "=== Backing up: $site ==="

    local config
    config=$(get_site_config "$site") || continue

    local host
    host=$(get_site_host "$config")
    if [[ -z $host ]]; then
      log_error "Could not determine host for $site"
      continue
    fi

    local backup_file="$backup_dir/$(date +%Y%m%d-%H%M%S)-$site.json"
    mkdir -p "$backup_dir"

    if ssh "${SSH_USER:-root}@$host" 'mongo --quiet --port 27117 ace --eval "
      JSON.stringify({
        _backup_meta: {
          timestamp: new Date().toISOString(),
          site: \"'"$site"'\",
          host: \"'"$host"'\"
        },
        networkconf: db.networkconf.find({}).toArray(),
        wlanconf: db.wlanconf.find({}).toArray(),
        firewall_policy: db.firewall_policy.find({}).toArray(),
        portforward: db.portforward.find({}).toArray()
      })
    "' >"$backup_file" 2>/dev/null; then
      log_success "$site: Backed up to $backup_file"
    else
      log_error "$site: Backup failed"
    fi
    echo ""
  done
}

# Main
case "$COMMAND" in
list)
  cmd_list
  ;;
status)
  cmd_status "$@"
  ;;
diff)
  cmd_diff "$@"
  ;;
deploy)
  cmd_deploy "$@"
  ;;
backup)
  cmd_backup "$@"
  ;;
help | --help | -h)
  usage
  ;;
*)
  log_error "Unknown command: $COMMAND"
  usage
  exit 1
  ;;
esac
