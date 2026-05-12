{
  description = "Nix modules for writing 1Password secrets at activation time";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
  let
    lib     = nixpkgs.lib;
    systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
    forAllSystems = lib.genAttrs systems;
  in {
    darwinModules.default = import ./modules/darwin.nix;
    hmModules.default     = import ./modules/hm.nix;

    checks = forAllSystems (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in import ./tests/default.nix { inherit pkgs lib; }
    );

    devShells = forAllSystems (system:
      let pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      in {
        default = pkgs.mkShell {
          packages = [ pkgs._1password-cli ];
        };
      }
    );
  };
}
