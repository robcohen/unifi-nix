# Treefmt configuration for consistent formatting
{ pkgs, ... }:
{
  # Project root
  projectRootFile = "flake.nix";

  programs = {
    # Nix formatting with nixfmt (RFC 166 style)
    nixfmt = {
      enable = true;
      package = pkgs.nixfmt-rfc-style;
    };

    # Shell script formatting
    shfmt = {
      enable = true;
      indent_size = 2;
    };

    # YAML formatting
    yamlfmt.enable = true;

    # Markdown formatting
    mdformat.enable = true;

    # JSON formatting (disabled for schemas which have specific format)
    prettier = {
      enable = true;
      includes = [
        "*.json"
        "*.md"
        "*.yml"
        "*.yaml"
      ];
      excludes = [
        "schemas/**"
        "flake.lock"
      ];
    };
  };

  settings.formatter = {
    # Exclude generated and external files
    nixfmt.excludes = [
      "node_modules/**"
      "result/**"
    ];

    shfmt.excludes = [
      "node_modules/**"
      "result/**"
    ];
  };
}
