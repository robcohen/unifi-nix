{
  description = "UniFi declarative configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    unifi-nix.url = "github:robcohen/unifi-nix";
  };

  outputs =
    {
      nixpkgs,
      unifi-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      site = unifi-nix.lib.mkSite {
        inherit pkgs;
        config = import ./site.nix;
      };
    in
    {
      packages.${system} = {
        default = site.configJson;
        config = site.configJson;
      };

      # Deploy with: nix run .#deploy
      apps.${system}.deploy = {
        type = "app";
        program = toString (
          pkgs.writeShellScript "deploy" ''
            ${unifi-nix.packages.${system}.deploy}/bin/unifi-deploy ${site.configJson} "$@"
          ''
        );
      };

      # Diff with: nix run .#diff
      apps.${system}.diff = {
        type = "app";
        program = toString (
          pkgs.writeShellScript "diff" ''
            ${unifi-nix.packages.${system}.diff}/bin/unifi-diff ${site.configJson} "$@"
          ''
        );
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          unifi-nix.packages.${system}.deploy
          unifi-nix.packages.${system}.diff
          unifi-nix.packages.${system}.eval
          pkgs.jq
        ];
      };
    };
}
