{
  description = "nix-op-secrets VM integration test flake";

  inputs = {
    nixpkgs.url    = "github:nixos/nixpkgs/nixos-25.05";
    hm.url         = "github:nix-community/home-manager/release-25.05";
    hm.inputs.nixpkgs.follows = "nixpkgs";
    # op-secrets pinned to GitHub; overridden at test time with:
    #   --override-input op-secrets path:/media/psf/nix-op-secrets
    #   --no-write-lock-file
    op-secrets.url = "github:nwlnexus/nix-op-secrets";
    op-secrets.inputs.nixpkgs.follows = "nixpkgs";
    darwin.url     = "github:nix-darwin/nix-darwin/nix-darwin-25.05";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, hm, op-secrets, darwin, ... }: {
    # Linux automated test target
    nixosConfigurations.test-vm = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./nixos-base.nix
        hm.nixosModules.home-manager
        {
          # HM NixOS integration options (NixOS-level, not HM-level)
          home-manager.useGlobalPkgs   = true;
          home-manager.useUserPackages = true;
          # Wire op-secrets HM module and stateVersion into the nixtest user
          home-manager.users.nixtest = {
            imports = [ op-secrets.hmModules.default ];
            home.stateVersion = "25.05";
          };
        }
        ./configuration.nix
      ];
    };

    # macOS manual test target — placeholder; see docs/vm-testing-macos.md
    darwinConfigurations.test-macos = darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        hm.darwinModules.home-manager
        op-secrets.darwinModules.default
        ./configuration-macos.nix
      ];
    };
  };
}
