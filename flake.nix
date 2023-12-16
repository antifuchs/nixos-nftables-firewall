{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    dependencyDagOfSubmodule = {
      url = "github:thelegy/nix-dependencyDagOfSubmodule";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = flakes @ {nixpkgs, ...}: {
    nixosModules = let
      module = file: {
        _file = file;
        imports = [(import file flakes)];
      };
    in rec {
      nftables = module ./nftables.nix;
      nftables-chains = module ./nftables-chains.nix;
      nftables-zoned = module ./nftables-zoned.nix;
      nftables-snippets = module ./nftables-snippets.nix;

      default = nftables-snippets;

      full = with nixpkgs.lib; let
        msg = concatStringsSep " " [
          "The nixos-nftables-firewall 'full' module has been deprecated,"
          "please use the 'default' module instead."
        ];
      in
        {...}: warn msg {imports = [default];};
    };

    checks.x86_64-linux = import ./checks "x86_64-linux" flakes;

    formatter = nixpkgs.lib.mapAttrs (_: x: x.alejandra) nixpkgs.legacyPackages;

    packages = with nixpkgs.lib;
      genAttrs systems.flakeExposed (system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [(import ./docs flakes)];
        };
      in {
        docs = pkgs.nixos-nftables-firewall-docs;
      });
  };
}
