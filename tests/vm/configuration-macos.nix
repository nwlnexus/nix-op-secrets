# tests/vm/configuration-macos.nix
# Placeholder macOS configuration for the manual testing guide.
# See docs/vm-testing-macos.md for the full setup walkthrough.
{ pkgs, ... }:
{
  # Networking
  networking.hostName = "nix-op-secrets-macos-test";

  # Nix settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Packages
  environment.systemPackages = [ pkgs.git pkgs.jq ];

  system.stateVersion = 5;
}
