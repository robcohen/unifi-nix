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
        nixosModules.default = unifiModule;
        nixosModules.unifi = unifiModule;

        # Library functions
        lib = {
          inherit evalSite;

          # Convenience function to build a deployable site
          mkSite = { pkgs, config }: evalSite { inherit pkgs config; };
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

          # Deploy script
          deploy = pkgs.writeShellApplication {
            name = "unifi-deploy";
            runtimeInputs = with pkgs; [
              jq
              openssh
              coreutils
              diffutils
            ];
            text = builtins.readFile ./scripts/deploy.sh;
            excludeShellChecks = [
              "SC2029" # Variables intentionally expanded client-side for SSH
              "SC2154" # $oid is a MongoDB field name, not a shell variable
            ];
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
                pkgs.jq
                pkgs.openssh
              ];

              shellHook = ''
                echo "unifi-nix development shell"
                echo ""
                echo "Available commands:"
                echo "  unifi-deploy  - Deploy configuration to UDM"
                echo "  unifi-diff    - Show diff between local and remote config"
                echo "  unifi-eval    - Evaluate Nix configuration"
                echo "  unifi-validate - Validate configuration"
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
          };
        };
    };
}
