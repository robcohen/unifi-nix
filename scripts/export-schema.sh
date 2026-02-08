#!/usr/bin/env bash
# export-schema: Export JSON schema for IDE autocompletion
# This generates a JSON Schema that can be used with VSCode, IntelliJ, etc.
set -euo pipefail

OUTPUT="${1:-./unifi-schema.json}"

cat >"$OUTPUT" <<'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/robcohen/unifi-nix/unifi-config.json",
  "title": "UniFi Configuration",
  "description": "Schema for unifi-nix configuration files",
  "type": "object",
  "properties": {
    "unifi": {
      "type": "object",
      "description": "UniFi configuration root",
      "required": ["host"],
      "properties": {
        "host": {
          "type": "string",
          "description": "UDM IP address or hostname",
          "examples": ["192.168.1.1"]
        },
        "site": {
          "type": "string",
          "description": "UniFi site name",
          "default": "default"
        },
        "schemaVersion": {
          "type": ["string", "null"],
          "description": "Pin to specific UniFi schema version",
          "examples": ["10.0.162"]
        },
        "networks": {
          "type": "object",
          "description": "Network (VLAN) configurations",
          "additionalProperties": {
            "$ref": "#/definitions/network"
          }
        },
        "wifi": {
          "type": "object",
          "description": "WiFi network configurations",
          "additionalProperties": {
            "$ref": "#/definitions/wifi"
          }
        },
        "portForwards": {
          "type": "object",
          "description": "Port forwarding rules",
          "additionalProperties": {
            "$ref": "#/definitions/portForward"
          }
        },
        "dhcpReservations": {
          "type": "object",
          "description": "Static DHCP reservations",
          "additionalProperties": {
            "$ref": "#/definitions/dhcpReservation"
          }
        },
        "firewall": {
          "type": "object",
          "properties": {
            "policies": {
              "type": "object",
              "description": "Zone-based firewall policies",
              "additionalProperties": {
                "$ref": "#/definitions/firewallPolicy"
              }
            },
            "groups": {
              "type": "object",
              "description": "Firewall groups (IP/port groups)",
              "additionalProperties": {
                "$ref": "#/definitions/firewallGroup"
              }
            }
          }
        },
        "vpn": {
          "type": "object",
          "properties": {
            "wireguard": {
              "type": "object",
              "properties": {
                "server": {
                  "$ref": "#/definitions/wireguardServer"
                },
                "peers": {
                  "type": "object",
                  "additionalProperties": {
                    "$ref": "#/definitions/wireguardPeer"
                  }
                }
              }
            },
            "siteToSite": {
              "type": "object",
              "additionalProperties": {
                "$ref": "#/definitions/siteToSiteVpn"
              }
            }
          }
        }
      }
    }
  },
  "definitions": {
    "secretRef": {
      "oneOf": [
        { "type": "string" },
        {
          "type": "object",
          "properties": {
            "_secret": {
              "type": "string",
              "description": "Path to secret (resolved at deploy time)"
            }
          },
          "required": ["_secret"]
        }
      ]
    },
    "network": {
      "type": "object",
      "required": ["subnet"],
      "properties": {
        "enable": {
          "type": "boolean",
          "default": true
        },
        "vlan": {
          "type": ["integer", "null"],
          "minimum": 1,
          "maximum": 4094,
          "description": "VLAN ID (null for untagged)"
        },
        "subnet": {
          "type": "string",
          "pattern": "^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}/\\d{1,2}$",
          "description": "Network subnet in CIDR notation"
        },
        "purpose": {
          "type": "string",
          "enum": ["corporate", "guest", "wan", "vlan-only"],
          "default": "corporate"
        },
        "networkGroup": {
          "type": "string",
          "enum": ["LAN", "WAN", "WAN2"],
          "default": "LAN"
        },
        "dhcp": {
          "type": "object",
          "properties": {
            "enable": { "type": "boolean", "default": false },
            "start": { "type": "string" },
            "end": { "type": "string" },
            "dns": {
              "type": "array",
              "items": { "type": "string" },
              "maxItems": 4
            },
            "leasetime": { "type": "integer", "default": 86400 }
          }
        },
        "isolate": { "type": "boolean", "default": false },
        "internetAccess": { "type": "boolean", "default": true },
        "mdns": { "type": "boolean", "default": true },
        "igmpSnooping": { "type": "boolean", "default": false }
      }
    },
    "wifi": {
      "type": "object",
      "required": ["ssid", "passphrase", "network"],
      "properties": {
        "enable": { "type": "boolean", "default": true },
        "ssid": { "type": "string", "description": "WiFi network name" },
        "passphrase": { "$ref": "#/definitions/secretRef" },
        "network": { "type": "string", "description": "Network name to bind to" },
        "hidden": { "type": "boolean", "default": false },
        "security": {
          "type": "string",
          "enum": ["open", "wpapsk", "wpa2", "wpaeap"],
          "default": "wpapsk"
        },
        "wpa3": {
          "type": "object",
          "properties": {
            "enable": { "type": "boolean", "default": false },
            "transition": { "type": "boolean", "default": true }
          }
        },
        "bands": {
          "type": "array",
          "items": { "type": "string", "enum": ["2g", "5g", "6g"] },
          "default": ["2g", "5g"]
        },
        "clientIsolation": { "type": "boolean", "default": false },
        "guestMode": { "type": "boolean", "default": false },
        "fastRoaming": { "type": "boolean", "default": false }
      }
    },
    "portForward": {
      "type": "object",
      "required": ["srcPort", "dstIP"],
      "properties": {
        "enable": { "type": "boolean", "default": true },
        "name": { "type": "string" },
        "srcPort": { "type": ["integer", "string"] },
        "dstIP": { "type": "string" },
        "dstPort": { "type": ["integer", "string", "null"] },
        "protocol": {
          "type": "string",
          "enum": ["tcp", "udp", "tcp_udp"],
          "default": "tcp_udp"
        },
        "srcIP": { "type": ["string", "null"] },
        "log": { "type": "boolean", "default": false }
      }
    },
    "dhcpReservation": {
      "type": "object",
      "required": ["mac", "ip", "network"],
      "properties": {
        "mac": {
          "type": "string",
          "pattern": "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
        },
        "ip": { "type": "string" },
        "name": { "type": "string" },
        "network": { "type": "string" }
      }
    },
    "firewallPolicy": {
      "type": "object",
      "properties": {
        "enable": { "type": "boolean", "default": true },
        "name": { "type": "string" },
        "description": { "type": "string" },
        "action": {
          "type": "string",
          "enum": ["allow", "block", "reject"],
          "default": "block"
        },
        "sourceZone": {
          "type": "string",
          "enum": ["internal", "external", "gateway", "vpn", "hotspot", "dmz"]
        },
        "sourceType": {
          "type": "string",
          "enum": ["any", "network", "ip"]
        },
        "sourceNetworks": {
          "type": "array",
          "items": { "type": "string" }
        },
        "destinationZone": {
          "type": "string",
          "enum": ["internal", "external", "gateway", "vpn", "hotspot", "dmz"]
        },
        "destinationType": {
          "type": "string",
          "enum": ["any", "network", "ip"]
        },
        "destinationNetworks": {
          "type": "array",
          "items": { "type": "string" }
        },
        "destinationPort": { "type": ["integer", "string", "null"] },
        "protocol": {
          "type": "string",
          "enum": ["all", "tcp", "udp", "tcp_udp", "icmp"],
          "default": "all"
        },
        "index": { "type": "integer", "default": 10000 },
        "logging": { "type": "boolean", "default": false }
      }
    },
    "firewallGroup": {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "type": {
          "type": "string",
          "enum": ["address-group", "port-group", "ipv6-address-group"]
        },
        "members": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "wireguardServer": {
      "type": "object",
      "properties": {
        "enable": { "type": "boolean", "default": false },
        "port": { "type": "integer", "default": 51820 },
        "network": { "type": "string", "default": "192.168.2.0/24" },
        "dns": {
          "type": "array",
          "items": { "type": "string" }
        },
        "allowedNetworks": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "wireguardPeer": {
      "type": "object",
      "required": ["publicKey"],
      "properties": {
        "name": { "type": "string" },
        "publicKey": { "type": "string" },
        "presharedKey": { "$ref": "#/definitions/secretRef" },
        "allowedIPs": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "siteToSiteVpn": {
      "type": "object",
      "required": ["remoteHost", "presharedKey"],
      "properties": {
        "enable": { "type": "boolean", "default": true },
        "name": { "type": "string" },
        "type": {
          "type": "string",
          "enum": ["ipsec", "openvpn", "wireguard"],
          "default": "ipsec"
        },
        "remoteHost": { "type": "string" },
        "remoteNetworks": {
          "type": "array",
          "items": { "type": "string" }
        },
        "localNetworks": {
          "type": "array",
          "items": { "type": "string" }
        },
        "presharedKey": { "$ref": "#/definitions/secretRef" },
        "ipsec": {
          "type": "object",
          "properties": {
            "ikeVersion": { "type": "integer", "enum": [1, 2], "default": 2 },
            "encryption": { "type": "string", "default": "aes256" },
            "hash": { "type": "string", "default": "sha256" },
            "dhGroup": { "type": "integer", "default": 14 }
          }
        }
      }
    }
  }
}
EOF

echo "JSON schema exported to: $OUTPUT"
echo ""
echo "To use with VSCode, add to .vscode/settings.json:"
echo ""
echo '  "json.schemas": ['
echo '    {'
echo '      "fileMatch": ["sites/*.json", "*.unifi.json"],'
echo "      \"url\": \"./$OUTPUT\""
echo '    }'
echo '  ]'
