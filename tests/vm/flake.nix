{
  description = "nix-op-secrets VM integration test flake";

  inputs = {
    nixpkgs.url    = "github:nixos/nixpkgs/nixos-25.05";
    hm.url         = "github:nix-community/home-manager/release-25.05";
    hm.inputs.nixpkgs.follows = "nixpkgs";
    # op-secrets pinned to GitHub; overridden at test time with:
    #   --override-input op-secrets path:/home/nixtest/nix-op-secrets
    #   --no-write-lock-file
    op-secrets.url = "github:nwlnexus/nix-op-secrets";
    op-secrets.inputs.nixpkgs.follows = "nixpkgs";
    darwin.url     = "github:nix-darwin/nix-darwin/nix-darwin-25.05";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, hm, op-secrets, darwin, ... }: {
    # Standalone Home Manager config — runs on Ubuntu in the test VM.
    # The VM has Nix installed (Determinate Systems) but is not NixOS.
    # Run with:
    #   nix run github:nix-community/home-manager/release-25.05 -- switch \
    #     --flake /home/nixtest/nix-op-secrets/tests/vm#nixtest \
    #     --override-input op-secrets path:/home/nixtest/nix-op-secrets \
    #     --no-write-lock-file
    homeConfigurations.nixtest = hm.lib.homeManagerConfiguration {
      # op-secrets depends on 1password-cli (unfree); use a configured pkgs.
      pkgs = import nixpkgs {
        system = "aarch64-linux";
        config.allowUnfree = true;
      };
      modules = [
        op-secrets.hmModules.default
        ./home.nix
      ];
    };

    # macOS manual test target — placeholder; see docs/vm-testing-macos.md
    darwinConfigurations.test-macos = darwin.lib.darwinSystem {
      system  = "aarch64-darwin";
      modules = [
        hm.darwinModules.home-manager
        op-secrets.darwinModules.default
        ./configuration-macos.nix
      ];
    };
  };
}
