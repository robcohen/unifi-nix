#!/usr/bin/env bash
# unifi-eval: Evaluate a Nix site config and output JSON
set -euo pipefail

CONFIG_FILE="${1:-}"

if [[ -z $CONFIG_FILE ]]; then
  echo "Usage: unifi-eval <config.nix>"
  echo ""
  echo "Evaluates a UniFi site configuration and outputs JSON for deploy/diff."
  echo ""
  echo "Example:"
  echo "  unifi-eval ./sites/home.nix > config.json"
  echo "  unifi-diff config.json 192.168.1.1"
  exit 1
fi

if [[ ! -f $CONFIG_FILE ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Find the flake root (where flake.nix is)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$(realpath "$CONFIG_FILE")"

nix eval --json --impure --expr "
let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;

  unifiModule = import $FLAKE_ROOT/module.nix;
  siteConfig = import $CONFIG_FILE;

  evaluated = (lib.evalModules {
    modules = [ unifiModule siteConfig ];
  }).config;

  toMongo = import $FLAKE_ROOT/lib/to-mongo.nix { inherit lib; };

in toMongo evaluated.unifi
"
