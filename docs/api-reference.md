# API Reference

Complete reference for all unifi-nix module options.

## Table of Contents

- [Top-Level Options](#top-level-options)
- [Networks](#networks)
- [WiFi](#wifi)
- [Firewall](#firewall)
- [Port Forwards](#port-forwards)
- [DHCP Reservations](#dhcp-reservations)
- [VPN](#vpn)
- [Groups](#groups)
- [Advanced Options](#advanced-options)

---

## Top-Level Options

### `unifi.host`

| Property | Value           |
| -------- | --------------- |
| Type     | `string`        |
| Required | Yes             |
| Example  | `"192.168.1.1"` |

UDM IP address or hostname for SSH connections.

### `unifi.site`

| Property | Value       |
| -------- | ----------- |
| Type     | `string`    |
| Default  | `"default"` |

UniFi site name. Most installations use "default".

### `unifi.schemaVersion`

| Property | Value              |
| -------- | ------------------ |
| Type     | `null` or `string` |
| Default  | `null` (latest)    |
| Example  | `"10.0.162"`       |

Pin to a specific UniFi schema version for reproducibility.

---

## Networks

Define VLANs and network segments.

```nix
unifi.networks.<name> = { ... };
```

### Network Options

| Option           | Type            | Default       | Description                                                    |
| ---------------- | --------------- | ------------- | -------------------------------------------------------------- |
| `enable`         | `bool`          | `true`        | Whether this network is enabled                                |
| `vlan`           | `null` or `int` | `null`        | VLAN ID (1-4094), null for untagged                            |
| `subnet`         | `string`        | Required      | Network in CIDR notation (e.g., `"192.168.10.1/24"`)           |
| `purpose`        | `enum`          | `"corporate"` | Network type: `"corporate"`, `"guest"`, `"wan"`, `"vlan-only"` |
| `networkGroup`   | `enum`          | `"LAN"`       | Network group: `"LAN"`, `"WAN"`, `"WAN2"`                      |
| `isolate`        | `bool`          | `false`       | Block inter-VLAN routing                                       |
| `internetAccess` | `bool`          | `true`        | Allow internet access                                          |
| `mdns`           | `bool`          | `true`        | Enable mDNS/Bonjour forwarding                                 |
| `igmpSnooping`   | `bool`          | `false`       | Enable IGMP snooping                                           |

### Network DHCP Options

| Option           | Type             | Default | Description           |
| ---------------- | ---------------- | ------- | --------------------- |
| `dhcp.enable`    | `bool`           | `false` | Enable DHCP server    |
| `dhcp.start`     | `string`         | `null`  | DHCP range start IP   |
| `dhcp.end`       | `string`         | `null`  | DHCP range end IP     |
| `dhcp.dns`       | `list of string` | `[]`    | DNS servers (max 4)   |
| `dhcp.leasetime` | `int`            | `86400` | Lease time in seconds |

### Example

```nix
unifi.networks = {
  Default = {
    subnet = "192.168.1.1/24";
    dhcp = {
      enable = true;
      start = "192.168.1.100";
      end = "192.168.1.254";
      dns = [ "1.1.1.1" "8.8.8.8" ];
    };
  };

  IoT = {
    vlan = 10;
    subnet = "192.168.10.1/24";
    isolate = true;
    dhcp.enable = true;
  };
};
```

---

## WiFi

Configure wireless networks (SSIDs).

```nix
unifi.wifi.<name> = { ... };
```

### WiFi Options

| Option            | Type                 | Default        | Description                    |
| ----------------- | -------------------- | -------------- | ------------------------------ |
| `enable`          | `bool`               | `true`         | Whether this WiFi is enabled   |
| `ssid`            | `string`             | Required       | Network name (1-32 characters) |
| `passphrase`      | `string` or `secret` | Required       | WiFi password                  |
| `network`         | `string`             | Required       | Network name to bind to        |
| `hidden`          | `bool`               | `false`        | Hide SSID from broadcast       |
| `security`        | `enum`               | `"wpapsk"`     | Security mode                  |
| `bands`           | `list`               | `["2g", "5g"]` | Frequency bands                |
| `clientIsolation` | `bool`               | `false`        | Isolate wireless clients       |
| `guestMode`       | `bool`               | `false`        | Enable guest portal            |
| `fastRoaming`     | `bool`               | `false`        | Enable 802.11r                 |
| `bssTransition`   | `bool`               | `true`         | Enable 802.11v                 |

### WiFi WPA3 Options

| Option            | Type   | Default | Description                  |
| ----------------- | ------ | ------- | ---------------------------- |
| `wpa3.enable`     | `bool` | `false` | Enable WPA3                  |
| `wpa3.transition` | `bool` | `true`  | WPA2+WPA3 compatibility mode |

### WiFi MAC Filter Options

| Option             | Type             | Default   | Description                        |
| ------------------ | ---------------- | --------- | ---------------------------------- |
| `macFilter.enable` | `bool`           | `false`   | Enable MAC filtering               |
| `macFilter.policy` | `enum`           | `"allow"` | Filter policy: `"allow"`, `"deny"` |
| `macFilter.list`   | `list of string` | `[]`      | MAC addresses to filter            |

### Security Modes

| Value      | Description                       |
| ---------- | --------------------------------- |
| `"open"`   | No security (captive portal only) |
| `"wpapsk"` | WPA/WPA2 Personal                 |
| `"wpa2"`   | WPA2 Personal only                |
| `"wpaeap"` | WPA-Enterprise (RADIUS)           |

### Example

```nix
unifi.wifi = {
  main = {
    ssid = "MyNetwork";
    passphrase = { _secret = "wifi/main"; };
    network = "Default";
    wpa3.enable = true;
  };

  iot = {
    ssid = "IoT-Devices";
    passphrase = { _secret = "wifi/iot"; };
    network = "IoT";
    hidden = true;
    bands = [ "2g" ];
  };
};
```

---

## Firewall

Zone-based firewall policies (UniFi 10.x+).

> **Note:** Enable zone-based firewall first: Settings > Firewall & Security > "Upgrade to Zone-Based Firewall"

### Firewall Zones

| Zone       | Description          |
| ---------- | -------------------- |
| `internal` | All LAN networks     |
| `external` | WAN/Internet         |
| `gateway`  | UDM itself           |
| `vpn`      | VPN clients          |
| `hotspot`  | Hotspot/guest portal |
| `dmz`      | DMZ networks         |

### Policy Options

```nix
unifi.firewall.policies.<name> = { ... };
```

| Option                | Type              | Default      | Description                                   |
| --------------------- | ----------------- | ------------ | --------------------------------------------- |
| `enable`              | `bool`            | `true`       | Whether policy is active                      |
| `action`              | `enum`            | `"block"`    | Action: `"allow"`, `"block"`, `"reject"`      |
| `sourceZone`          | `enum`            | `"internal"` | Source zone                                   |
| `sourceType`          | `enum`            | `"any"`      | Match type: `"any"`, `"network"`, `"ip"`      |
| `sourceNetworks`      | `list`            | `[]`         | Network names (when type = network)           |
| `sourceIPs`           | `list`            | `[]`         | IP/CIDR list (when type = ip)                 |
| `destinationZone`     | `enum`            | `"internal"` | Destination zone                              |
| `destinationType`     | `enum`            | `"any"`      | Match type                                    |
| `destinationNetworks` | `list`            | `[]`         | Network names                                 |
| `destinationIPs`      | `list`            | `[]`         | IP/CIDR list                                  |
| `destinationPort`     | `int` or `string` | `null`       | Port or range (e.g., `"80-443"`)              |
| `protocol`            | `enum`            | `"all"`      | Protocol: `"all"`, `"tcp"`, `"udp"`, `"icmp"` |
| `index`               | `int`             | `10000`      | Priority (lower = higher priority)            |
| `logging`             | `bool`            | `false`      | Enable syslog logging                         |

### Firewall Groups

```nix
unifi.firewall.groups.<name> = { ... };
```

| Option    | Type             | Default           | Description   |
| --------- | ---------------- | ----------------- | ------------- |
| `type`    | `enum`           | `"address-group"` | Group type    |
| `members` | `list of string` | `[]`              | Group members |

Group types: `"address-group"`, `"port-group"`, `"ipv6-address-group"`

### Example

```nix
unifi.firewall = {
  groups = {
    trusted-servers = {
      type = "address-group";
      members = [ "192.168.1.100" "192.168.1.101" ];
    };
  };

  policies = {
    block-iot-to-lan = {
      action = "block";
      sourceZone = "internal";
      sourceType = "network";
      sourceNetworks = [ "IoT" ];
      destinationZone = "internal";
      destinationType = "network";
      destinationNetworks = [ "Default" ];
    };

    allow-iot-dns = {
      action = "allow";
      sourceZone = "internal";
      sourceType = "network";
      sourceNetworks = [ "IoT" ];
      destinationZone = "gateway";
      destinationPort = 53;
      protocol = "udp";
      index = 9000;  # Higher priority than block rule
    };
  };
};
```

---

## Port Forwards

NAT port forwarding rules.

```nix
unifi.portForwards.<name> = { ... };
```

| Option     | Type              | Default     | Description                             |
| ---------- | ----------------- | ----------- | --------------------------------------- |
| `enable`   | `bool`            | `true`      | Whether rule is active                  |
| `srcPort`  | `int` or `string` | Required    | External port or range                  |
| `dstIP`    | `string`          | Required    | Internal destination IP                 |
| `dstPort`  | `int` or `string` | `null`      | Internal port (default: same as src)    |
| `protocol` | `enum`            | `"tcp_udp"` | Protocol: `"tcp"`, `"udp"`, `"tcp_udp"` |
| `srcIP`    | `string`          | `null`      | Limit to source IP (default: any)       |
| `log`      | `bool`            | `false`     | Enable logging                          |

### Example

```nix
unifi.portForwards = {
  https = {
    srcPort = 443;
    dstIP = "192.168.1.100";
    protocol = "tcp";
  };

  minecraft = {
    srcPort = 25565;
    dstIP = "192.168.1.50";
    protocol = "tcp";
  };
};
```

---

## DHCP Reservations

Static IP assignments by MAC address.

```nix
unifi.dhcpReservations.<name> = { ... };
```

| Option    | Type     | Default  | Description                     |
| --------- | -------- | -------- | ------------------------------- |
| `mac`     | `string` | Required | MAC address (XX:XX:XX:XX:XX:XX) |
| `ip`      | `string` | Required | Reserved IP address             |
| `network` | `string` | Required | Network name                    |

### Example

```nix
unifi.dhcpReservations = {
  server = {
    mac = "00:11:22:33:44:55";
    ip = "192.168.1.100";
    network = "Default";
  };
};
```

---

## VPN

### WireGuard Server

```nix
unifi.vpn.wireguard.server = { ... };
```

| Option            | Type             | Default            | Description             |
| ----------------- | ---------------- | ------------------ | ----------------------- |
| `enable`          | `bool`           | `false`            | Enable WireGuard server |
| `port`            | `int`            | `51820`            | Listen port             |
| `network`         | `string`         | `"192.168.2.0/24"` | Client IP pool          |
| `dns`             | `list of string` | `[]`               | DNS servers for clients |
| `allowedNetworks` | `list of string` | `["0.0.0.0/0"]`    | Accessible networks     |

### WireGuard Peers

```nix
unifi.vpn.wireguard.peers.<name> = { ... };
```

| Option         | Type             | Default  | Description       |
| -------------- | ---------------- | -------- | ----------------- |
| `publicKey`    | `string`         | Required | Peer's public key |
| `presharedKey` | `secret`         | `null`   | Optional PSK      |
| `allowedIPs`   | `list of string` | `[]`     | Assigned IPs      |

### Site-to-Site VPN

```nix
unifi.vpn.siteToSite.<name> = { ... };
```

| Option           | Type             | Default   | Description                                     |
| ---------------- | ---------------- | --------- | ----------------------------------------------- |
| `enable`         | `bool`           | `true`    | Enable tunnel                                   |
| `type`           | `enum`           | `"ipsec"` | VPN type: `"ipsec"`, `"openvpn"`, `"wireguard"` |
| `remoteHost`     | `string`         | Required  | Remote endpoint                                 |
| `remoteNetworks` | `list of string` | `[]`      | Remote subnets                                  |
| `localNetworks`  | `list of string` | `[]`      | Local subnets to expose                         |
| `presharedKey`   | `secret`         | Required  | Shared secret                                   |

#### IPsec Options

| Option             | Type       | Default    | Description          |
| ------------------ | ---------- | ---------- | -------------------- |
| `ipsec.ikeVersion` | `1` or `2` | `2`        | IKE version          |
| `ipsec.encryption` | `string`   | `"aes256"` | Encryption algorithm |
| `ipsec.hash`       | `string`   | `"sha256"` | Hash algorithm       |
| `ipsec.dhGroup`    | `int`      | `14`       | DH group             |

### Example

```nix
unifi.vpn = {
  wireguard = {
    server = {
      enable = true;
      network = "10.8.0.0/24";
      dns = [ "1.1.1.1" ];
    };

    peers = {
      laptop = {
        publicKey = "abc123...";
        allowedIPs = [ "10.8.0.10/32" ];
      };
    };
  };

  siteToSite = {
    datacenter = {
      type = "ipsec";
      remoteHost = "vpn.datacenter.example.com";
      remoteNetworks = [ "10.0.0.0/24" ];
      localNetworks = [ "192.168.1.0/24" ];
      presharedKey = { _secret = "vpn/datacenter"; };
    };
  };
};
```

---

## Groups

### AP Groups

Assign SSIDs to specific access points.

```nix
unifi.apGroups.<name> = { ... };
```

| Option    | Type             | Default | Description      |
| --------- | ---------------- | ------- | ---------------- |
| `devices` | `list of string` | `[]`    | AP MAC addresses |

### User Groups

Bandwidth limits for clients.

```nix
unifi.userGroups.<name> = { ... };
```

| Option          | Type  | Default | Description            |
| --------------- | ----- | ------- | ---------------------- |
| `downloadLimit` | `int` | `null`  | Download limit in Kbps |
| `uploadLimit`   | `int` | `null`  | Upload limit in Kbps   |

### DPI Groups

Application categories for traffic rules.

```nix
unifi.dpiGroups.<name> = { ... };
```

| Option       | Type             | Default | Description        |
| ------------ | ---------------- | ------- | ------------------ |
| `categories` | `list of string` | `[]`    | DPI category names |

---

## Advanced Options

### Traffic Rules

QoS, rate limiting, and application blocking rules.

```nix
unifi.trafficRules.<name> = { ... };
```

| Option           | Type     | Default        | Description               |
| ---------------- | -------- | -------------- | ------------------------- |
| `enable`         | `bool`   | `true`         | Whether rule is active    |
| `name`           | `string` | attribute name | Display name              |
| `description`    | `string` | `""`           | Rule description          |
| `action`         | `enum`   | `"BLOCK"`      | Rule action (see below)   |
| `matchingTarget` | `enum`   | `"INTERNET"`   | What to match against     |
| `networkId`      | `string` | `null`         | Network name (null = all) |
| `index`          | `int`    | `4000`         | Priority (lower = higher) |

#### Traffic Rule Actions

| Value                 | Description            |
| --------------------- | ---------------------- |
| `"BLOCK"`             | Block matching traffic |
| `"QOS_RATE_LIMIT"`    | Apply bandwidth limit  |
| `"QOS_PRIORITY_HIGH"` | Set high QoS priority  |
| `"QOS_PRIORITY_LOW"`  | Set low QoS priority   |

#### Bandwidth Limit Options

| Option                    | Type  | Default | Description            |
| ------------------------- | ----- | ------- | ---------------------- |
| `bandwidthLimit.download` | `int` | `null`  | Download limit in kbps |
| `bandwidthLimit.upload`   | `int` | `null`  | Upload limit in kbps   |

#### Example

```nix
unifi.trafficRules = {
  guest-limit = {
    name = "Guest Bandwidth Limit";
    action = "QOS_RATE_LIMIT";
    matchingTarget = "INTERNET";
    networkId = "Guest";
    bandwidthLimit = {
      download = 25000;  # 25 Mbps
      upload = 10000;    # 10 Mbps
    };
    index = 2000;
  };

  block-p2p = {
    name = "Block P2P";
    action = "BLOCK";
    matchingTarget = "INTERNET";
    index = 100;
  };
};
```

---

### RADIUS Profiles

For WPA-Enterprise (802.1X) authentication.

```nix
unifi.radiusProfiles.<name> = { ... };
```

| Option         | Type     | Default        | Description                           |
| -------------- | -------- | -------------- | ------------------------------------- |
| `name`         | `string` | attribute name | Profile name                          |
| `useUsg`       | `bool`   | `false`        | Use UDM as RADIUS server              |
| `vlanEnabled`  | `bool`   | `false`        | Enable VLAN assignment                |
| `vlanWlanMode` | `enum`   | `"optional"`   | VLAN mode: `"required"`, `"optional"` |

#### Auth Server Options

```nix
unifi.radiusProfiles.<name>.authServers = [ { ... } ];
```

| Option   | Type     | Default  | Description      |
| -------- | -------- | -------- | ---------------- |
| `ip`     | `string` | Required | RADIUS server IP |
| `port`   | `int`    | `1812`   | RADIUS auth port |
| `secret` | `secret` | Required | Shared secret    |

#### Accounting Server Options

```nix
unifi.radiusProfiles.<name>.accountingServers = [ { ... } ];
```

| Option   | Type     | Default  | Description            |
| -------- | -------- | -------- | ---------------------- |
| `ip`     | `string` | Required | RADIUS server IP       |
| `port`   | `int`    | `1813`   | RADIUS accounting port |
| `secret` | `secret` | Required | Shared secret          |

#### Example

```nix
unifi.radiusProfiles = {
  corporate = {
    name = "Corporate RADIUS";
    authServers = [{
      ip = "192.168.1.50";
      port = 1812;
      secret = { _secret = "radius/corporate"; };
    }];
    accountingServers = [{
      ip = "192.168.1.50";
      port = 1813;
      secret = { _secret = "radius/corporate"; };
    }];
    vlanEnabled = true;
  };
};
```

---

### Port Profiles

Switch port VLAN and PoE configurations.

```nix
unifi.portProfiles.<name> = { ... };
```

| Option           | Type             | Default        | Description                |
| ---------------- | ---------------- | -------------- | -------------------------- |
| `name`           | `string`         | attribute name | Profile name               |
| `forward`        | `enum`           | `"all"`        | VLAN forwarding mode       |
| `nativeNetwork`  | `string`         | `null`         | Untagged VLAN network name |
| `taggedNetworks` | `list of string` | `[]`           | Tagged VLAN network names  |
| `poeMode`        | `enum`           | `"auto"`       | PoE power mode             |
| `speed`          | `enum`           | `"autoneg"`    | Port speed                 |
| `isolation`      | `bool`           | `false`        | Enable port isolation      |

#### Forward Modes

| Value         | Description                    |
| ------------- | ------------------------------ |
| `"all"`       | Forward all VLANs              |
| `"native"`    | Only native VLAN               |
| `"customize"` | Native + specific tagged VLANs |
| `"disabled"`  | Port disabled                  |

#### PoE Modes

| Value           | Description             |
| --------------- | ----------------------- |
| `"auto"`        | Automatic PoE detection |
| `"passthrough"` | PoE passthrough         |
| `"off"`         | PoE disabled            |

#### Port Speeds

| Value        | Description    |
| ------------ | -------------- |
| `"autoneg"`  | Auto-negotiate |
| `"10"`       | 10 Mbps        |
| `"100"`      | 100 Mbps       |
| `"1000"`     | 1 Gbps         |
| `"2500"`     | 2.5 Gbps       |
| `"10000"`    | 10 Gbps        |
| `"disabled"` | Port disabled  |

#### Storm Control Options

| Option                | Type   | Default | Description                   |
| --------------------- | ------ | ------- | ----------------------------- |
| `stormControl.enable` | `bool` | `false` | Enable storm control          |
| `stormControl.rate`   | `int`  | `100`   | Rate limit percentage (1-100) |

#### Example

```nix
unifi.portProfiles = {
  # Basic workstation port
  workstation = {
    name = "Workstation";
    forward = "native";
    nativeNetwork = "Default";
    poeMode = "auto";
  };

  # AP trunk port - multiple VLANs
  ap-trunk = {
    name = "AP Trunk";
    forward = "customize";
    nativeNetwork = "Default";
    taggedNetworks = [ "IoT" "Guest" ];
    poeMode = "auto";
  };

  # Camera port with isolation
  camera = {
    name = "Camera";
    forward = "native";
    nativeNetwork = "Cameras";
    poeMode = "auto";
    isolation = true;
    stormControl = {
      enable = true;
      rate = 80;
    };
  };

  # Disabled unused port
  disabled = {
    name = "Disabled";
    forward = "disabled";
    poeMode = "off";
  };
};
```

---

### Schema-Generated Options

These options are auto-generated from the UniFi MongoDB schema:

- `unifi.scheduledTasks` - Scheduled automation
- `unifi.wlanGroups` - WLAN group assignments
- `unifi.globalSettings` - Controller settings
- `unifi.firewallZones` - Zone definitions
- `unifi.dohServers` - DNS over HTTPS
- `unifi.sslInspectionProfiles` - SSL inspection

---

## Secret References

Secrets can be specified as plain strings or references:

```nix
# Plain string (not recommended for production)
passphrase = "mypassword";

# Secret reference (resolved at deploy time)
passphrase = { _secret = "wifi/main"; };
```

Secret paths are resolved from `$UNIFI_SECRETS_DIR` or via sops/agenix integration.

See [Secrets Guide](./secrets-guide.md) for detailed setup.
