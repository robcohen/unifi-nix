# Validation helpers for UniFi configuration
{ lib }:

let
  inherit (lib)
    filter
    mapAttrsToList
    attrNames
    flatten
    elem
    count
    concatMap
    ;

  # MAC address regex pattern (XX:XX:XX:XX:XX:XX)
  isValidMac =
    mac:
    let
      # Simple validation: 6 groups of 2 hex chars separated by colons
      parts = lib.splitString ":" mac;
      isHexPair = s: builtins.stringLength s == 2 && builtins.match "[0-9A-Fa-f]{2}" s != null;
    in
    builtins.length parts == 6 && builtins.all isHexPair parts;

  # IP address validation
  isValidIp =
    ip:
    let
      parts = lib.splitString "." ip;
      isOctet =
        s:
        let
          n = lib.toIntBase10 s;
        in
        builtins.stringLength s > 0 && n >= 0 && n <= 255;
    in
    builtins.length parts == 4 && builtins.all isOctet parts;

  # Convert IP string to integer for comparison
  ipToInt =
    ip:
    let
      parts = map lib.toInt (lib.splitString "." ip);
    in
    (builtins.elemAt parts 0) * 16777216
    + (builtins.elemAt parts 1) * 65536
    + (builtins.elemAt parts 2) * 256
    + (builtins.elemAt parts 3);

  # Check if IP is within a subnet
  ipInSubnet =
    ip: subnet:
    let
      subnetParts = lib.splitString "/" subnet;
      subnetIp = builtins.elemAt subnetParts 0;
      prefix = lib.toInt (builtins.elemAt subnetParts 1);
      subnetInt = ipToInt subnetIp;
      ipInt = ipToInt ip;
      hostBits = 32 - prefix;
      networkSize = if hostBits >= 32 then 4294967296 else pow2 hostBits;
      networkStart = subnetInt;
      networkEnd = subnetInt + networkSize - 1;
    in
    ipInt >= networkStart && ipInt <= networkEnd;

  # Check SSID length (1-32 characters)
  isValidSsidLength =
    ssid:
    let
      len = builtins.stringLength ssid;
    in
    len >= 1 && len <= 32;

  # Power of 2 helper
  pow2 = n: if n == 0 then 1 else 2 * pow2 (n - 1);

  # Parse subnet to get network address for overlap detection
  parseSubnetForOverlap =
    subnet:
    let
      parts = lib.splitString "/" subnet;
      ip = builtins.elemAt parts 0;
      prefix = lib.toInt (builtins.elemAt parts 1);
      ipParts = map lib.toInt (lib.splitString "." ip);
      # Convert IP to integer for comparison
      ipInt =
        (builtins.elemAt ipParts 0) * 16777216
        + (builtins.elemAt ipParts 1) * 65536
        + (builtins.elemAt ipParts 2) * 256
        + (builtins.elemAt ipParts 3);
      # Calculate network size
      hostBits = 32 - prefix;
      networkSize = if hostBits >= 32 then 4294967296 else pow2 hostBits;
    in
    {
      inherit ipInt networkSize prefix;
    };

  # Check if two subnets overlap
  subnetsOverlap =
    a: b:
    let
      aStart = a.info.ipInt;
      aEnd = a.info.ipInt + a.info.networkSize - 1;
      bStart = b.info.ipInt;
      bEnd = b.info.ipInt + b.info.networkSize - 1;
    in
    aStart <= bEnd && bStart <= aEnd;

  # Find overlapping subnet pairs
  findOverlaps =
    subnets:
    let
      pairs = filter (p: p.a.name < p.b.name) (concatMap (a: map (b: { inherit a b; }) subnets) subnets);
    in
    filter (p: subnetsOverlap p.a p.b) pairs;

in
{
  # Validate a UniFi configuration and return validation results
  validate = cfg: {
    # Get all VLAN IDs that are set
    vlanIds = filter (v: v != null) (mapAttrsToList (_: n: n.vlan) cfg.networks);

    # Check for duplicate VLANs
    duplicateVlans =
      let
        vlanIds = filter (v: v != null) (mapAttrsToList (_: n: n.vlan) cfg.networks);
      in
      filter (v: count (x: x == v) vlanIds > 1) vlanIds;

    # Get all network names
    networkNames = attrNames cfg.networks;

    # Check WiFi network references
    invalidWifiRefs =
      let
        networkNames = attrNames cfg.networks;
        wifiNetworkRefs = mapAttrsToList (_: w: w.network) cfg.wifi;
      in
      filter (n: !(elem n networkNames)) wifiNetworkRefs;

    # Check firewall policy network references
    invalidPolicyNetRefs =
      let
        networkNames = attrNames cfg.networks;
        policySourceNets = flatten (mapAttrsToList (_: p: p.sourceNetworks) cfg.firewall.policies);
        policyDestNets = flatten (mapAttrsToList (_: p: p.destinationNetworks) cfg.firewall.policies);
        allPolicyNetRefs = policySourceNets ++ policyDestNets;
      in
      filter (n: !(elem n networkNames)) allPolicyNetRefs;

    # Check for overlapping subnets
    overlappingSubnets =
      let
        subnetInfos = mapAttrsToList (name: n: {
          inherit name;
          info = parseSubnetForOverlap n.subnet;
          inherit (n) subnet;
        }) cfg.networks;
      in
      findOverlaps subnetInfos;

    # Check for DNS server limit (UniFi supports max 4)
    dnsLimitWarnings =
      let
        networksWithTooManyDns = filter (n: builtins.length n.dns > 4) (
          mapAttrsToList (name: net: {
            inherit name;
            inherit (net.dhcp) dns;
          }) cfg.networks
        );
      in
      map (
        n:
        "Network '${n.name}': ${toString (builtins.length n.dns)} DNS servers specified, only first 4 will be used"
      ) networksWithTooManyDns;

    # Check for invalid VLAN IDs (must be 1-4094)
    invalidVlans =
      let
        vlansWithNames = filter (v: v.vlan != null) (
          mapAttrsToList (name: n: {
            inherit name;
            inherit (n) vlan;
          }) cfg.networks
        );
        invalidOnes = filter (v: v.vlan < 1 || v.vlan > 4094) vlansWithNames;
      in
      map (v: "Network '${v.name}': VLAN ID ${toString v.vlan} is invalid (must be 1-4094)") invalidOnes;

    # Check for invalid MAC addresses in DHCP reservations
    invalidMacs =
      let
        reservations = mapAttrsToList (name: r: {
          inherit name;
          inherit (r) mac;
        }) cfg.dhcpReservations;
        invalidOnes = filter (r: !(isValidMac r.mac)) reservations;
      in
      map (r: "DHCP reservation '${r.name}': Invalid MAC address '${r.mac}'") invalidOnes;

    # Check for invalid IP addresses in DHCP reservations
    invalidIps =
      let
        reservations = mapAttrsToList (name: r: {
          inherit name;
          inherit (r) ip;
        }) cfg.dhcpReservations;
        invalidOnes = filter (r: !(isValidIp r.ip)) reservations;
      in
      map (r: "DHCP reservation '${r.name}': Invalid IP address '${r.ip}'") invalidOnes;

    # Check for invalid IPs in port forwards
    invalidPortForwardIps =
      let
        forwards = mapAttrsToList (name: pf: {
          inherit name;
          ip = pf.dstIP;
        }) cfg.portForwards;
        invalidOnes = filter (pf: !(isValidIp pf.ip)) forwards;
      in
      map (pf: "Port forward '${pf.name}': Invalid destination IP '${pf.ip}'") invalidOnes;

    # Check DHCP range validity (start < end)
    invalidDhcpRanges =
      let
        networksWithDhcp = filter (n: n.dhcpEnabled && n.start != null && n.end != null) (
          mapAttrsToList (name: net: {
            inherit name;
            inherit (net) subnet;
            dhcpEnabled = net.dhcp.enable;
            inherit (net.dhcp) start end;
          }) cfg.networks
        );
        invalidRanges = filter (n: ipToInt n.start >= ipToInt n.end) networksWithDhcp;
      in
      map (
        n: "Network '${n.name}': DHCP start (${n.start}) must be less than end (${n.end})"
      ) invalidRanges;

    # Check DHCP range is within subnet
    dhcpRangeOutsideSubnet =
      let
        networksWithDhcp = filter (n: n.dhcpEnabled && n.start != null && n.end != null) (
          mapAttrsToList (name: net: {
            inherit name;
            inherit (net) subnet;
            dhcpEnabled = net.dhcp.enable;
            inherit (net.dhcp) start end;
          }) cfg.networks
        );
        outsideSubnet = filter (
          n: !(ipInSubnet n.start n.subnet) || !(ipInSubnet n.end n.subnet)
        ) networksWithDhcp;
      in
      map (
        n: "Network '${n.name}': DHCP range (${n.start}-${n.end}) is outside subnet ${n.subnet}"
      ) outsideSubnet;

    # Check WiFi SSID length (1-32 characters)
    invalidSsidLengths =
      let
        wifiWithSsid = mapAttrsToList (name: w: {
          inherit name;
          inherit (w) ssid;
        }) cfg.wifi;
        invalidOnes = filter (w: !(isValidSsidLength w.ssid)) wifiWithSsid;
      in
      map (
        w:
        "WiFi '${w.name}': SSID '${w.ssid}' has invalid length (${toString (builtins.stringLength w.ssid)} chars, must be 1-32)"
      ) invalidOnes;
  };
}
