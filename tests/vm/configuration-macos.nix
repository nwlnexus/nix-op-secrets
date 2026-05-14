# tests/vm/configuration-macos.nix
# Placeholder macOS configuration for the manual testing guide.
# See docs/vm-testing-macos.md for the full setup walkthrough.
#
# NOTE: A real macOS test configuration (nix-darwin + HM) would add an
# op-secrets block here with dest paths using macOS home conventions:
#   home-manager.users.nixtest.op-secrets = { ... dest = "/Users/nixtest/..."; };
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
