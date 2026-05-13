# tests/vm/nixos-base.nix
# Base NixOS configuration for the nix-op-secrets test VM.
# The __VM_KEY_PUB__ placeholder is substituted by setup-base.sh at install time.
{ pkgs, lib, ... }:
{
  # Boot
  boot.loader.grub.enable  = true;
  boot.loader.grub.device  = "/dev/sda";

  # Networking
  networking.useDHCP = true;

  # SSH — key-only, no passwords
  services.openssh.enable                            = true;
  services.openssh.settings.PasswordAuthentication  = false;
  services.openssh.settings.PermitRootLogin          = "no";

  # Test user — isNormalUser required for SSH login as non-root
  users.users.nixtest = {
    isNormalUser = true;
    home         = "/home/nixtest";
    extraGroups  = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "__VM_KEY_PUB__" ];
  };

  # Allow wheel members to sudo without password (needed for nixos-rebuild)
  security.sudo.wheelNeedsPassword = false;

  # Nix flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Packages available in the base system
  environment.systemPackages = [ pkgs.git pkgs.jq ];

  # Parallels Tools — required for shared folders (repo mount) and guest agent
  hardware.parallels.enable = true;
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.05";
}
