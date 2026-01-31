{
  description = "Nyx server packages for OpenClaw infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # Home Manager configuration for fx user
      homeConfigurations."fx" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./packages.nix ];
      };

      # Allow running `nix flake check` for validation
      checks.${system} = {
        homeConfiguration = self.homeConfigurations."fx".activationPackage;
      };
    };
}
