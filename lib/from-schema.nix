# from-schema.nix - Generate Nix module options from MongoDB schema
#
# This provides functions to dynamically generate typed options from
# the extracted MongoDB schema, eliminating manual option definitions.
#
{ lib }:

let
  inherit (lib)
    mkOption
    types
    hasPrefix
    hasSuffix
    ;

  # Load schema files from a directory
  loadSchemaFiles =
    schemaDir:
    let
      fieldsPath = "${schemaDir}/mongodb-fields.json";
      examplesPath = "${schemaDir}/mongodb-examples.json";
    in
    {
      fields =
        if builtins.pathExists fieldsPath then builtins.fromJSON (builtins.readFile fieldsPath) else { };

      examples =
        if builtins.pathExists examplesPath then
          builtins.fromJSON (builtins.readFile examplesPath)
        else
          { };
    };

  # Internal fields to skip
  skipFields = [
    "_id"
    "site_id"
    "setting_preference"
    "external_id"
  ];

  isSkipField =
    field: builtins.elem field skipFields || hasPrefix "attr_" field || field == "key" && true; # 'key' is often internal

  # Convert snake_case to camelCase
  toCamelCase =
    s:
    let
      # builtins.split returns a mix of strings and lists, filter to only strings
      rawParts = builtins.split "_" s;
      parts = builtins.filter (x: builtins.isString x && x != "") rawParts;
      capitalize =
        str:
        if str == "" then "" else lib.toUpper (builtins.substring 0 1 str) + builtins.substring 1 (-1) str;
      first = builtins.head parts;
      rest = builtins.tail parts;
    in
    if parts == [ ] then s else first + builtins.concatStringsSep "" (map capitalize rest);

  # Infer Nix type from field name patterns
  inferTypeFromName =
    field:
    # Boolean patterns
    if
      hasSuffix "_enabled" field
      || hasSuffix "_enable" field
      || field == "enabled"
      || hasPrefix "is_" field
      || hasSuffix "_required" field
      || hasSuffix "_only_once" field
      || hasSuffix "_active" field
      || hasSuffix "_allowed" field
      || hasSuffix "_blocked" field
      || hasSuffix "_hidden" field
      || hasSuffix "_disabled" field
      || hasPrefix "auto_" field
      || hasPrefix "use_" field
      || hasPrefix "hide_" field
      || hasPrefix "allow_" field
      || hasPrefix "block_" field
      || hasPrefix "enable_" field
      || hasPrefix "disable_" field
      || hasPrefix "no_" field
    then
      {
        type = types.bool;
        default = false;
      }

    # Integer patterns
    else if
      hasSuffix "_timeout" field
      || hasSuffix "_time" field
      || hasSuffix "_port" field
      || hasSuffix "_rate" field
      || hasSuffix "_limit" field
      || hasSuffix "_max" field
      || hasSuffix "_min" field
      || hasSuffix "_count" field
      || hasSuffix "_size" field
      || hasSuffix "_length" field
      || hasSuffix "_interval" field
      || hasSuffix "_priority" field
      || hasSuffix "_index" field
      || hasSuffix "_order" field
      || field == "vlan"
      || field == "index"
      || field == "priority"
      || field == "port"
    then
      {
        type = types.int;
        default = 0;
      }

    # Reference ID list patterns
    else if hasSuffix "_ids" field then
      {
        type = types.listOf types.str;
        default = [ ];
        comment = "Reference IDs";
      }

    # Reference ID patterns (nullable)
    else if hasSuffix "_id" field then
      {
        type = types.nullOr types.str;
        default = null;
        comment = "Reference ID";
      }

    # IP/Network patterns
    else if
      hasSuffix "_ip" field
      || hasSuffix "_gateway" field
      || hasSuffix "_cidr" field
      || hasSuffix "_subnet" field
      || field == "ip_subnet"
      || field == "gateway"
    then
      {
        type = types.str;
        default = "";
        comment = "IP/CIDR";
      }

    # MAC address patterns
    else if hasSuffix "_mac" field || field == "mac" then
      {
        type = types.str;
        default = "";
        comment = "MAC address";
      }

    # List patterns
    else if
      hasSuffix "_list" field
      || hasSuffix "_members" field
      || hasSuffix "_networks" field
      || hasSuffix "_ips" field
      || hasSuffix "_ports" field
      || hasSuffix "_macs" field
      || hasSuffix "_domains" field
    then
      {
        type = types.listOf types.str;
        default = [ ];
      }

    # DHCP range patterns (start/stop for IP ranges)
    else if hasSuffix "_start" field || hasSuffix "_stop" field then
      {
        type = types.str;
        default = "";
        comment = "IP address";
      }

    # No match - return null to try value-based inference
    else
      null;

  # Infer Nix type from example value
  inferTypeFromValue =
    value:
    if value == null then
      null
    else if builtins.isBool value then
      {
        type = types.bool;
        default = value;
      }
    else if builtins.isInt value then
      {
        type = types.int;
        default = value;
      }
    else if builtins.isFloat value then
      {
        type = types.float;
        default = value;
      }
    else if builtins.isString value then
      {
        type = types.str;
        default = "";
      }
    else if builtins.isList value then
      if value == [ ] then
        {
          type = types.listOf types.str;
          default = [ ];
        }
      else
        let
          first = builtins.head value;
        in
        if builtins.isString first then
          {
            type = types.listOf types.str;
            default = [ ];
          }
        else if builtins.isInt first then
          {
            type = types.listOf types.int;
            default = [ ];
          }
        else if builtins.isAttrs first then
          {
            type = types.listOf types.attrs;
            default = [ ];
            comment = "Nested objects";
          }
        else
          {
            type = types.listOf types.str;
            default = [ ];
          }
    else if builtins.isAttrs value then
      {
        type = types.attrs;
        default = { };
        comment = "Nested object";
      }
    else
      null;

  # Get the best type inference for a field
  inferType =
    field: exampleValue:
    let
      fromName = inferTypeFromName field;
      fromValue = inferTypeFromValue exampleValue;
    in
    if fromName != null then
      fromName
    else if fromValue != null then
      fromValue
    else
      # Final fallback
      {
        type = types.nullOr types.str;
        default = null;
      };

  # Generate a single mkOption from field info
  mkFieldOption =
    field: typeInfo:
    mkOption {
      inherit (typeInfo) type default;
      description = field + (if typeInfo ? comment then " (${typeInfo.comment})" else "");
    };

  # Generate options for all fields in a collection
  mkCollectionOptions =
    fields: examples:
    let
      validFields = builtins.filter (f: !isSkipField f) fields;
    in
    builtins.listToAttrs (
      map (field: {
        name = toCamelCase field;
        value = mkFieldOption field (inferType field (examples.${field} or null));
      }) validFields
    );

  # Find latest schema directory
  # Base schemas directory
  schemasDir = ../schemas;
  hasSchemasDir = builtins.pathExists schemasDir;

  # List all available schema versions
  availableVersions =
    if hasSchemasDir then
      builtins.filter (
        name:
        let
          path = schemasDir + "/${name}";
        in
        builtins.pathExists (path + "/mongodb-fields.json")
      ) (builtins.attrNames (builtins.readDir schemasDir))
    else
      [ ];

  # Sort versions (newest first)
  sortedVersions = builtins.sort (a: b: a > b) availableVersions;

  # Find latest schema directory
  findLatestSchemaDir =
    if sortedVersions != [ ] then toString (schemasDir + "/${builtins.head sortedVersions}") else null;

  # Load schema for a specific version
  loadVersionedSchemaDir =
    version:
    let
      versionDir = schemasDir + "/${version}";
    in
    if builtins.pathExists (versionDir + "/mongodb-fields.json") then toString versionDir else null;

in
rec {
  inherit
    loadSchemaFiles
    toCamelCase
    inferType
    inferTypeFromName
    inferTypeFromValue
    mkFieldOption
    mkCollectionOptions
    findLatestSchemaDir
    availableVersions
    sortedVersions
    loadVersionedSchemaDir
    ;

  # Latest version string
  latestVersion = if sortedVersions != [ ] then builtins.head sortedVersions else null;

  # Load schema for a specific version (or latest if null)
  loadSchemaForVersion =
    version:
    let
      dir = if version == null then findLatestSchemaDir else loadVersionedSchemaDir version;
    in
    if dir != null then
      loadSchemaFiles dir
    else
      {
        fields = { };
        examples = { };
      };

  # Load the latest available schema (default)
  latestSchema = loadSchemaForVersion null;

  # Create a submodule for a collection (uses latest schema)
  # Usage: mkCollectionSubmodule "networkconf"
  mkCollectionSubmodule = collection: _: {
    options = mkCollectionOptions (latestSchema.fields.${collection} or [ ]) (
      latestSchema.examples.${collection} or { }
    );
  };

  # Create an attrsOf option for a collection (uses latest schema)
  # Usage in module.nix: dhcpOptions = mkCollectionOption "dhcp_option" "DHCP static leases";
  mkCollectionOption =
    collection: description:
    mkOption {
      type = types.attrsOf (types.submodule (mkCollectionSubmodule collection));
      default = { };
      inherit description;
    };

  # ============================================================================
  # Version-aware variants - use these when you need a specific schema version
  # ============================================================================

  # Create submodule for a specific version
  # Usage: mkCollectionSubmoduleV "10.0.162" "networkconf"
  mkCollectionSubmoduleV =
    version: collection:
    let
      schema = loadSchemaForVersion version;
    in
    _: {
      options = mkCollectionOptions (schema.fields.${collection} or [ ]) (
        schema.examples.${collection} or { }
      );
    };

  # Create option for a specific version
  mkCollectionOptionV =
    version: collection: description:
    mkOption {
      type = types.attrsOf (types.submodule (mkCollectionSubmoduleV version collection));
      default = { };
      inherit description;
    };

  # Convert collection for a specific version
  convertCollectionV =
    version: collection: items:
    let
      schema = loadSchemaForVersion version;
      configToMongoV =
        col: _name: cfg:
        let
          fields = builtins.filter (f: !isSkipField f) (schema.fields.${col} or [ ]);
          convertField =
            field:
            let
              nixName = toCamelCase field;
              value = cfg.${nixName} or null;
            in
            if value == null then
              null
            else if lib.hasSuffix "_id" field then
              {
                name = "_${field}_ref";
                inherit value;
              }
            else
              {
                name = field;
                inherit value;
              };
          converted = builtins.filter (x: x != null) (map convertField fields);
        in
        builtins.listToAttrs converted // { site_id = "_SITE_ID_"; };
    in
    lib.mapAttrs (configToMongoV collection) items;

  # List all available collections
  availableCollections = builtins.attrNames latestSchema.fields;

  # Get collections for a specific version
  getCollectionsForVersion = version: builtins.attrNames (loadSchemaForVersion version).fields;

  # Get fields for a collection (for inspection/debugging)
  getCollectionFields = collection: latestSchema.fields.${collection} or [ ];

  # Get example for a collection (for inspection/debugging)
  getCollectionExample = collection: latestSchema.examples.${collection} or { };

  # ============================================================================
  # MongoDB Conversion Functions
  # ============================================================================

  # Convert camelCase back to snake_case (for MongoDB field names)
  toSnakeCase =
    s:
    let
      chars = lib.stringToCharacters s;
      processChar = c: if lib.strings.isUpper c then "_" + lib.strings.toLower c else c;
    in
    lib.concatStrings (map processChar chars);

  # Build a mapping from camelCase to snake_case for a collection
  buildFieldMapping =
    collection:
    let
      fields = builtins.filter (f: !isSkipField f) (latestSchema.fields.${collection} or [ ]);
    in
    builtins.listToAttrs (
      map (field: {
        name = toCamelCase field;
        value = field;
      }) fields
    );

  # Convert a single config value to MongoDB document
  # Handles reference ID fields specially (marked for resolution at deploy time)
  configToMongo =
    collection: _name: cfg:
    let
      fields = builtins.filter (f: !isSkipField f) (latestSchema.fields.${collection} or [ ]);

      # Convert each field
      convertField =
        field:
        let
          nixName = toCamelCase field;
          value = cfg.${nixName} or null;
        in
        # Skip null values to not override defaults
        if value == null then
          null
        # Reference IDs get special handling
        else if lib.hasSuffix "_id" field then
          {
            name = "_${field}_ref";
            inherit value;
          }
        else
          {
            name = field;
            inherit value;
          };

      converted = builtins.filter (x: x != null) (map convertField fields);
    in
    builtins.listToAttrs converted // { site_id = "_SITE_ID_"; };

  # Create a toMongo function for a collection
  # Usage: mkToMongo "dhcp_option" -> (_name: cfg: { ... })
  mkToMongo = configToMongo;

  # Convert all items in a collection config
  # Usage: convertCollection "dhcp_option" config.dhcpOptions
  convertCollection = collection: items: lib.mapAttrs (mkToMongo collection) items;
}
