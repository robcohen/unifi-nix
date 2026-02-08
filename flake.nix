{
  description = "Declarative UniFi network configuration via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    flake-parts.url = "github:hercules-ci/flake-parts";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      treefmt-nix,
      ...
    }:
    let
      # The module that defines UniFi configuration options
      unifiModule = import ./module.nix;

      # Helper to evaluate a site configuration
      evalSite =
        { pkgs, config }:
        let
          evaluated =
            (pkgs.lib.evalModules {
              modules = [
                unifiModule
                config
              ];
            }).config;

          toMongo = import ./lib/to-mongo.nix { inherit (pkgs) lib; };
        in
        {
          inherit (evaluated.unifi) host;
          config = evaluated.unifi;
          mongoDocuments = toMongo evaluated.unifi;

          # JSON export for deploy scripts
          configJson = pkgs.writeText "unifi-config.json" (builtins.toJSON (toMongo evaluated.unifi));
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        # Export the module for use in other flakes
        nixosModules = {
          default = unifiModule;
          unifi = unifiModule;
          service = import ./nixos-module.nix;
        };

        # Library functions
        lib = {
          inherit evalSite;

          # Convenience function to build a deployable site
          mkSite = { pkgs, config }: evalSite { inherit pkgs config; };

          # Schema-based code generation (for adding new collections)
          # Usage:
          #   fromSchema = unifi-nix.lib.mkFromSchema pkgs.lib;
          #   options.myCollection = fromSchema.mkCollectionOption "collection_name" "Description";
          mkFromSchema = lib: import ./lib/from-schema.nix { inherit lib; };
        };

        # Templates for nix flake init
        templates = {
          default = {
            path = ./templates/default;
            description = "UniFi declarative configuration starter template";
          };
        };

        # Overlay for adding unifi-nix tools to pkgs
        overlays.default =
          final: _prev:
          let
            packages = self.packages.${final.system};
          in
          {
            unifi-nix = {
              inherit (packages)
                deploy
                diff
                eval
                validate
                extract-schema
                generate-schema
                ;
            };
          };
      };

      perSystem =
        { pkgs, ... }:
        let
          treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

          # Common meta for all packages
          meta = {
            description = "Declarative UniFi network configuration";
            homepage = "https://github.com/robcohen/unifi-nix";
            license = pkgs.lib.licenses.mit;
            maintainers = [ ];
            platforms = pkgs.lib.platforms.unix;
          };

          # Deploy script (uses lib/deploy/ modules)
          deploy = pkgs.stdenv.mkDerivation {
            pname = "unifi-deploy";
            version = "1.0.0";
            src = ./scripts;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              mkdir -p $out/bin $out/lib/deploy

              # Install deploy libraries
              if [ -d lib/deploy ]; then
                cp -r lib/deploy/* $out/lib/deploy/
              fi

              # Install main script
              install -m755 deploy.sh $out/bin/unifi-deploy

              # Fix paths in script - update SCRIPT_DIR to point to lib parent
              substituteInPlace $out/bin/unifi-deploy \
                --replace 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"' "SCRIPT_DIR=\"$out\""

              # Fix library source paths
              substituteInPlace $out/bin/unifi-deploy \
                --replace 'source "$SCRIPT_DIR/lib/deploy/' "source \"$out/lib/deploy/"

              # Wrap with dependencies
              wrapProgram $out/bin/unifi-deploy \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    [
                      jq
                      openssh
                      coreutils
                      diffutils
                    ]
                  )
                }
            '';

            inherit meta;
          };

          # Diff script
          diff = pkgs.writeShellApplication {
            name = "unifi-diff";
            runtimeInputs = with pkgs; [
              jq
              openssh
              coreutils
              diffutils
            ];
            text = builtins.readFile ./scripts/diff.sh;
            excludeShellChecks = [
              "SC2034" # Color variables defined for potential future use
            ];
            inherit meta;
          };

          # Eval helper
          eval = pkgs.writeShellApplication {
            name = "unifi-eval";
            runtimeInputs = with pkgs; [
              nix
              jq
            ];
            text = builtins.readFile ./scripts/eval.sh;
            inherit meta;
          };

          # Validation script
          validate = pkgs.writeShellApplication {
            name = "unifi-validate";
            runtimeInputs = with pkgs; [
              jq
              coreutils
            ];
            text = builtins.readFile ./scripts/validate-config.sh;
            excludeShellChecks = [
              "SC2034" # Variables defined for schema validation
            ];
            inherit meta;
          };

          # Schema extraction script
          extract-schema = pkgs.writeShellApplication {
            name = "unifi-extract-schema";
            runtimeInputs = with pkgs; [
              jq
              openssh
              coreutils
            ];
            text = builtins.readFile ./scripts/extract-schema.sh;
            excludeShellChecks = [
              "SC2029" # Variables intentionally expanded client-side for SSH
            ];
            inherit meta;
          };

          # Restore script
          restore = pkgs.writeShellApplication {
            name = "unifi-restore";
            runtimeInputs = with pkgs; [
              jq
              openssh
              coreutils
            ];
            text = builtins.readFile ./scripts/restore.sh;
            excludeShellChecks = [
              "SC2029" # Variables intentionally expanded client-side for SSH
            ];
            inherit meta;
          };

          # Schema diff script
          schema-diff = pkgs.writeShellApplication {
            name = "unifi-schema-diff";
            runtimeInputs = with pkgs; [
              jq
              coreutils
            ];
            text = builtins.readFile ./scripts/schema-diff.sh;
            inherit meta;
          };

          # Drift detection script
          drift-detect = pkgs.writeShellApplication {
            name = "unifi-drift-detect";
            runtimeInputs = with pkgs; [
              jq
              openssh
              coreutils
            ];
            text = builtins.readFile ./scripts/drift-detect.sh;
            excludeShellChecks = [
              "SC2029" # Variables intentionally expanded client-side for SSH
            ];
            inherit meta;
          };

          # Multi-site management script
          multi-site = pkgs.writeShellApplication {
            name = "unifi-multi-site";
            runtimeInputs = with pkgs; [
              jq
              openssh
              coreutils
              nix
            ];
            text = builtins.readFile ./scripts/multi-site.sh;
            excludeShellChecks = [
              "SC2029" # Variables intentionally expanded client-side for SSH
              "SC2034" # Color variables
            ];
            inherit meta;
          };

          # Code generator from schema
          generate-module = pkgs.writeShellApplication {
            name = "unifi-generate-module";
            runtimeInputs = with pkgs; [
              jq
              coreutils
            ];
            text = builtins.readFile ./scripts/generate-module.sh;
            inherit meta;
          };

          # Schema generators - extracts enums, defaults, validation, JSON schema
          generate-schema =
            let
              schemasDir = ./schemas;
              generatorsDir = ./scripts/generators;
            in
            pkgs.stdenv.mkDerivation {
              pname = "unifi-generate-schema";
              version = "1.0.0";

              # No src - we use specific paths
              dontUnpack = true;

              nativeBuildInputs = with pkgs; [ jq ];

              buildPhase = ''
                # Find latest version
                LATEST=$(ls -1 ${schemasDir} | grep -E '^[0-9]' | sort -V | tail -1)
                if [ -z "$LATEST" ]; then
                  echo "No schema versions found"
                  exit 1
                fi

                SCHEMA_VERSION_DIR="${schemasDir}/$LATEST"
                echo "Using schema version: $LATEST"

                # Run all generators
                mkdir -p generated

                if [ -f "$SCHEMA_VERSION_DIR/integration.json" ]; then
                  echo "Extracting enums..."
                  bash ${generatorsDir}/extract-enums.sh "$SCHEMA_VERSION_DIR/integration.json" generated/enums.json

                  echo "Extracting validation rules..."
                  bash ${generatorsDir}/extract-validation.sh "$SCHEMA_VERSION_DIR/integration.json" generated/validation.json
                else
                  echo "Warning: integration.json not found, skipping enum/validation extraction"
                fi

                if [ -f "$SCHEMA_VERSION_DIR/mongodb-examples.json" ]; then
                  echo "Extracting defaults..."
                  bash ${generatorsDir}/extract-defaults.sh "$SCHEMA_VERSION_DIR/mongodb-examples.json" generated/defaults.json
                else
                  echo "Warning: mongodb-examples.json not found, skipping defaults extraction"
                fi

                if [ -f "$SCHEMA_VERSION_DIR/mongodb-fields.json" ] && \
                   [ -f "$SCHEMA_VERSION_DIR/mongodb-examples.json" ] && \
                   [ -f generated/enums.json ]; then
                  echo "Generating JSON schemas..."
                  mkdir -p generated/json-schema
                  bash ${generatorsDir}/generate-json-schema.sh \
                    "$SCHEMA_VERSION_DIR/mongodb-fields.json" \
                    "$SCHEMA_VERSION_DIR/mongodb-examples.json" \
                    generated/enums.json \
                    generated/json-schema
                else
                  echo "Warning: Missing files for JSON schema generation"
                fi

                echo "$LATEST" > generated/version
              '';

              installPhase = ''
                mkdir -p $out/share/unifi-nix/generated
                cp -r generated/* $out/share/unifi-nix/generated/

                # Also install generator scripts for manual use
                mkdir -p $out/bin
                for script in ${generatorsDir}/*.sh; do
                  install -m755 "$script" $out/bin/unifi-$(basename "$script" .sh)
                done
              '';

              inherit meta;
            };

          # Unified CLI wrapper
          unifi = pkgs.stdenv.mkDerivation {
            pname = "unifi-cli";
            version = "1.0.0";
            src = ./scripts;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              mkdir -p $out/bin $out/lib/deploy $out/share/unifi-nix

              # Install libraries
              cp lib/common.sh $out/lib/
              if [ -d lib/deploy ]; then
                cp -r lib/deploy/* $out/lib/deploy/
              fi

              # Install all scripts
              for script in *.sh; do
                install -m755 "$script" $out/share/unifi-nix/
              done

              # Install unified CLI
              install -m755 unifi $out/bin/unifi

              # Wrap with correct paths
              wrapProgram $out/bin/unifi \
                --set SCRIPT_DIR $out/share/unifi-nix \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    [
                      jq
                      openssh
                      coreutils
                      nix
                      gnused
                      gnugrep
                    ]
                  )
                }

              # Fix script paths in the wrapper
              sed -i "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$out/share/unifi-nix\"|" $out/bin/unifi
              sed -i "s|source.*lib/common.sh|source \"$out/lib/common.sh\"|" $out/bin/unifi

              # Fix deploy.sh library paths
              substituteInPlace $out/share/unifi-nix/deploy.sh \
                --replace 'source "$SCRIPT_DIR/lib/deploy/' "source \"$out/lib/deploy/"
            '';

            inherit meta;
          };
        in
        {
          packages = {
            inherit
              deploy
              diff
              eval
              validate
              extract-schema
              restore
              schema-diff
              drift-detect
              multi-site
              generate-module
              generate-schema
              unifi
              ;
            default = deploy;
          };

          apps = {
            deploy = {
              type = "app";
              program = "${deploy}/bin/unifi-deploy";
              meta.description = "Deploy UniFi configuration to UDM";
            };
            diff = {
              type = "app";
              program = "${diff}/bin/unifi-diff";
              meta.description = "Show diff between local and remote UniFi config";
            };
            eval = {
              type = "app";
              program = "${eval}/bin/unifi-eval";
              meta.description = "Evaluate Nix UniFi configuration to JSON";
            };
            validate = {
              type = "app";
              program = "${validate}/bin/unifi-validate";
              meta.description = "Validate UniFi configuration against schema";
            };
            restore = {
              type = "app";
              program = "${restore}/bin/unifi-restore";
              meta.description = "Restore UniFi configuration from backup";
            };
            schema-diff = {
              type = "app";
              program = "${schema-diff}/bin/unifi-schema-diff";
              meta.description = "Show differences between schema versions";
            };
            drift-detect = {
              type = "app";
              program = "${drift-detect}/bin/unifi-drift-detect";
              meta.description = "Detect configuration drift on UDM";
            };
            multi-site = {
              type = "app";
              program = "${multi-site}/bin/unifi-multi-site";
              meta.description = "Manage multiple UniFi sites";
            };
            generate-module = {
              type = "app";
              program = "${generate-module}/bin/unifi-generate-module";
              meta.description = "Generate Nix module code from MongoDB schema";
            };
            generate-schema = {
              type = "app";
              program = "${generate-schema}/bin/unifi-generate-all";
              meta.description = "Generate enums, defaults, validation, and JSON schema from UniFi schema";
            };
            unifi = {
              type = "app";
              program = "${unifi}/bin/unifi";
              meta.description = "Unified CLI for unifi-nix";
            };
            default = {
              type = "app";
              program = "${deploy}/bin/unifi-deploy";
              meta.description = "Deploy UniFi configuration to UDM";
            };
          };

          # Development shells
          devShells = {
            default = pkgs.mkShell {
              packages = [
                deploy
                diff
                eval
                validate
                extract-schema
                restore
                schema-diff
                drift-detect
                multi-site
                generate-module
                generate-schema
                unifi
                pkgs.jq
                pkgs.openssh
              ];

              shellHook = ''
                echo "unifi-nix development shell"
                echo ""
                echo "Available commands:"
                echo "  unifi-deploy          - Deploy configuration to UDM"
                echo "  unifi-diff            - Show diff between local and remote config"
                echo "  unifi-eval            - Evaluate Nix configuration"
                echo "  unifi-validate        - Validate configuration"
                echo "  unifi-restore         - Restore from backup"
                echo "  unifi-schema-diff     - Compare schema versions"
                echo "  unifi-drift-detect    - Detect configuration drift"
                echo "  unifi-multi-site      - Manage multiple sites"
                echo "  unifi-generate-module - Generate code from MongoDB schema"
                echo "  unifi-generate-schema - Auto-generate enums, defaults, validation, JSON schema"
                echo ""
              '';
            };

            # CI shell with formatting and linting tools
            ci = pkgs.mkShell {
              packages = [
                pkgs.statix
                pkgs.deadnix
                treefmtEval.config.build.wrapper
              ];
            };
          };

          # Formatter
          formatter = treefmtEval.config.build.wrapper;

          # Checks
          checks = {
            formatting = treefmtEval.config.build.check self;

            statix = pkgs.runCommand "statix-check" { } ''
              ${pkgs.statix}/bin/statix check ${self} --ignore node_modules
              touch $out
            '';

            deadnix = pkgs.runCommand "deadnix-check" { } ''
              cd ${self}
              ${pkgs.deadnix}/bin/deadnix --fail . --exclude 'node_modules|schemas'
              touch $out
            '';

            # Test that example evaluates correctly
            example-eval =
              let
                module = import ./module.nix;
                example = import ./examples/home.nix;
                evaluated =
                  (pkgs.lib.evalModules {
                    modules = [
                      module
                      example
                    ];
                  }).config;
                # Force evaluation by checking host is a string
                result = builtins.isString evaluated.unifi.host;
              in
              pkgs.runCommand "example-eval" { } ''
                if ${if result then "true" else "false"}; then
                  echo "Example config evaluates correctly"
                  touch $out
                else
                  echo "Example evaluation failed"
                  exit 1
                fi
              '';

            # Test module structure
            module-structure =
              let
                module = import ./module.nix;
                evaluated =
                  (pkgs.lib.evalModules {
                    modules = [
                      module
                      {
                        unifi = {
                          host = "test";
                          networks = { };
                          wifi = { };
                        };
                      }
                    ];
                  }).config;
                # Force evaluation and check host value
                result = evaluated.unifi.host == "test";
              in
              pkgs.runCommand "module-structure" { } ''
                if ${if result then "true" else "false"}; then
                  echo "Module structure is valid"
                  touch $out
                else
                  echo "Module structure test failed"
                  exit 1
                fi
              '';

            # Test schema loading
            schema-loading =
              let
                schemaLib = import ./lib/schema.nix { inherit (pkgs) lib; };
                inherit (schemaLib) schema;

                # Test that all enum types are non-empty lists
                enumsValid = builtins.all (x: builtins.isList x && builtins.length x > 0) [
                  schema.zoneKeys
                  schema.networkPurposes
                  schema.wifiSecurity
                  schema.wifiWpaModes
                  schema.wifiPmfModes
                  schema.wifiMacFilterPolicies
                  schema.policyActions
                  schema.policyProtocols
                  schema.policyIpVersions
                  schema.connectionStateTypes
                  schema.matchingTargets
                  schema.portForwardProtocols
                  schema.networkGroups
                  schema.wifiBands
                  schema.routingTypes
                ];

                # Test that default schema works (no device data)
                inherit (schemaLib) defaultSchema;
                defaultsValid = builtins.all (x: builtins.isList x && builtins.length x > 0) [
                  defaultSchema.zoneKeys
                  defaultSchema.policyActions
                ];

                # Test that findLatestSchema returns something valid
                latestValid = schema.zoneKeys != [ ];

                allValid = enumsValid && defaultsValid && latestValid;
              in
              pkgs.runCommand "schema-loading" { } ''
                if ${if allValid then "true" else "false"}; then
                  echo "Schema loading tests passed"
                  echo "  - All enums are non-empty lists: ${if enumsValid then "OK" else "FAIL"}"
                  echo "  - Default schema works: ${if defaultsValid then "OK" else "FAIL"}"
                  echo "  - Latest schema found: ${if latestValid then "OK" else "FAIL"}"
                  touch $out
                else
                  echo "Schema loading tests failed"
                  exit 1
                fi
              '';

            # Test schema-driven module validation
            schema-validation =
              let
                module = import ./module.nix;

                # Test valid config
                validConfig =
                  (pkgs.lib.evalModules {
                    modules = [
                      module
                      {
                        unifi = {
                          host = "test";
                          networks.Default = {
                            subnet = "192.168.1.1/24";
                            purpose = "corporate";
                            networkGroup = "LAN";
                          };
                          wifi.main = {
                            ssid = "Test";
                            passphrase = "test1234";
                            network = "Default";
                            security = "wpapsk";
                            pmf = "optional";
                            bands = [
                              "2g"
                              "5g"
                            ];
                          };
                          firewall.policies.test = {
                            action = "block";
                            sourceZone = "internal";
                            destinationZone = "external";
                            protocol = "all";
                            ipVersion = "both";
                            connectionState = "ALL";
                          };
                          portForwards.http = {
                            srcPort = 80;
                            dstIP = "192.168.1.100";
                            protocol = "tcp";
                          };
                        };
                      }
                    ];
                  }).config;

                # Force evaluation
                result =
                  validConfig.unifi.host == "test"
                  && validConfig.unifi.networks.Default.purpose == "corporate"
                  && validConfig.unifi.wifi.main.security == "wpapsk"
                  && validConfig.unifi.firewall.policies.test.action == "block";
              in
              pkgs.runCommand "schema-validation" { } ''
                if ${if result then "true" else "false"}; then
                  echo "Schema validation tests passed"
                  echo "  - Valid config evaluates correctly"
                  echo "  - All schema-driven enums work"
                  touch $out
                else
                  echo "Schema validation tests failed"
                  exit 1
                fi
              '';

            # Test full config evaluation with test file
            full-config-eval =
              let
                module = import ./module.nix;
                testConfig = import ./tests/test-config.nix;
                evaluated =
                  (pkgs.lib.evalModules {
                    modules = [
                      module
                      testConfig
                    ];
                  }).config;

                # Force deep evaluation
                result =
                  evaluated.unifi.host == "192.168.1.1"
                  && builtins.length (builtins.attrNames evaluated.unifi.networks) == 3
                  && builtins.length (builtins.attrNames evaluated.unifi.wifi) == 2
                  && builtins.length (builtins.attrNames evaluated.unifi.firewall.policies) == 2
                  && builtins.length (builtins.attrNames evaluated.unifi.portForwards) == 2;
              in
              pkgs.runCommand "full-config-eval" { } ''
                if ${if result then "true" else "false"}; then
                  echo "Full config evaluation tests passed"
                  echo "  - Host: ${evaluated.unifi.host}"
                  echo "  - Networks: ${toString (builtins.attrNames evaluated.unifi.networks)}"
                  echo "  - WiFi: ${toString (builtins.attrNames evaluated.unifi.wifi)}"
                  echo "  - Policies: ${toString (builtins.attrNames evaluated.unifi.firewall.policies)}"
                  touch $out
                else
                  echo "Full config evaluation tests failed"
                  exit 1
                fi
              '';

            # Test to-mongo conversion
            to-mongo-conversion =
              let
                module = import ./module.nix;
                toMongo = import ./lib/to-mongo.nix { inherit (pkgs) lib; };
                testConfig = import ./tests/test-config.nix;
                evaluated =
                  (pkgs.lib.evalModules {
                    modules = [
                      module
                      testConfig
                    ];
                  }).config;
                mongoOutput = toMongo evaluated.unifi;

                # Verify conversion
                result =
                  builtins.isAttrs mongoOutput.networks
                  && builtins.isAttrs mongoOutput.wifi
                  && builtins.isAttrs mongoOutput.firewallPolicies
                  && mongoOutput.networks.Default.name == "Default"
                  && mongoOutput.wifi.main.name == "TestNetwork";
              in
              pkgs.runCommand "to-mongo-conversion" { } ''
                if ${if result then "true" else "false"}; then
                  echo "to-mongo conversion tests passed"
                  echo "  - Networks converted correctly"
                  echo "  - WiFi converted correctly"
                  echo "  - Firewall policies converted correctly"
                  touch $out
                else
                  echo "to-mongo conversion tests failed"
                  exit 1
                fi
              '';

            # Test schema-generated collections (optional - passes if no generated schema exists yet)
            schema-generated-collections =
              let
                fromSchema = import ./lib/from-schema.nix { inherit (pkgs) lib; };
                hasSchema = fromSchema.latestVersion != null;
                result =
                  hasSchema
                  && builtins.length fromSchema.availableCollections > 0
                  && builtins.length (fromSchema.getCollectionFields "dhcp_option") > 0;
                # Build message conditionally to avoid null interpolation
                successMsg =
                  if hasSchema then ''
                    echo "Schema-generated collections tests passed"
                    echo "  - Latest version: ${fromSchema.latestVersion}"
                    echo "  - Collections available: ${toString (builtins.length fromSchema.availableCollections)}"
                  '' else ''
                    echo "No generated schema found - skipping (this is OK, CI will populate it)"
                  '';
              in
              pkgs.runCommand "schema-generated-collections" { } ''
                ${
                  if result || !hasSchema then ''
                    ${successMsg}
                    touch $out
                  '' else ''
                    echo "Schema-generated collections tests failed"
                    echo "  Schema exists but collections are invalid"
                    exit 1
                  ''
                }
              '';
          };
        };
    };
}
