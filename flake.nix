{
  description = "Declarative UniFi network configuration via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # The module that defines UniFi configuration options
      unifiModule = import ./module.nix;

      # Helper to evaluate a site configuration
      evalSite = { pkgs, config }:
        let
          evaluated = (pkgs.lib.evalModules {
            modules = [ unifiModule config ];
          }).config;

          toMongo = import ./lib/to-mongo.nix { inherit (pkgs) lib; };
        in {
          inherit (evaluated.unifi) host;
          config = evaluated.unifi;
          mongoDocuments = toMongo evaluated.unifi;

          # JSON export for deploy scripts
          configJson = pkgs.writeText "unifi-config.json"
            (builtins.toJSON (toMongo evaluated.unifi));
        };

    in {
      # Export the module for use in other flakes
      nixosModules.default = unifiModule;

      # Library functions
      lib = {
        inherit evalSite;

        # Convenience function to build a deployable site
        mkSite = { pkgs, config }: evalSite { inherit pkgs config; };
      };

    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Deploy script
        deploy = pkgs.writeShellApplication {
          name = "unifi-deploy";
          runtimeInputs = with pkgs; [ jq openssh coreutils diffutils ];
          text = builtins.readFile ./scripts/deploy.sh;
        };

        # Diff script
        diff = pkgs.writeShellApplication {
          name = "unifi-diff";
          runtimeInputs = with pkgs; [ jq openssh coreutils diffutils ];
          text = builtins.readFile ./scripts/diff.sh;
        };

        # Eval helper
        eval = pkgs.writeShellApplication {
          name = "unifi-eval";
          runtimeInputs = with pkgs; [ nix jq ];
          text = builtins.readFile ./scripts/eval.sh;
        };

      in {
        packages = {
          inherit deploy diff eval;
          default = deploy;
        };

        apps = {
          deploy = { type = "program"; program = "${deploy}/bin/unifi-deploy"; };
          diff = { type = "program"; program = "${diff}/bin/unifi-diff"; };
          eval = { type = "program"; program = "${eval}/bin/unifi-eval"; };
          default = self.apps.${system}.deploy;
        };

        devShells.default = pkgs.mkShell {
          packages = [ deploy diff eval pkgs.jq ];
        };
      }
    );
}
