#!/usr/bin/env bash
# scripts/vm/setup-base.sh
# Idempotent: creates the nix-op-secrets-base Parallels VM and snapshots it.
# Safe to run multiple times — skips steps already completed.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
KEY_DIR="$REPO_ROOT/tests/vm/keys"
BASE_VM="nix-op-secrets-base"
SNAP_NAME="clean"

# ── SSH Key ────────────────────────────────────────────────────────────────
echo "==> Checking SSH key..."
mkdir -p "$KEY_DIR"
if [[ ! -f "$KEY_DIR/vm_key" ]]; then
  ssh-keygen -t ed25519 -C "nix-op-secrets-vm-test" -N "" -f "$KEY_DIR/vm_key"
  echo "    Generated SSH key at $KEY_DIR/vm_key"
else
  echo "    SSH key already exists — skipping"
fi
PUB_KEY="$(cat "$KEY_DIR/vm_key.pub")"

# ── Skip if base VM already has a clean snapshot ───────────────────────────
if prlctl snapshot-list "$BASE_VM" 2>/dev/null | grep -q "$SNAP_NAME"; then
  echo "==> Base VM '$BASE_VM' already has snapshot '$SNAP_NAME' — nothing to do."
  exit 0
fi

# ── Build custom installer ISO ─────────────────────────────────────────────
echo "==> Building custom NixOS installer ISO (this takes ~2 min on first run)..."
# Requires an aarch64-linux builder (nix.linux-builder.enable = true in nix-darwin)
# because some ISO derivations are not in the binary cache and must be built on Linux.
_ISO_DIR=$(nix build --no-link --print-out-paths \
  --impure \
  --expr "
    let
      pkgs = import <nixpkgs> { system = \"aarch64-linux\"; };
    in (pkgs.nixos {
      imports = [ \"\${<nixpkgs>}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix\" ];
      services.openssh.enable = true;
      services.openssh.settings.PermitRootLogin = \"yes\";
      users.users.root.openssh.authorizedKeys.keys = [ \"$PUB_KEY\" ];
    }).config.system.build.isoImage
  ")
# Glob must expand on a separate line — not inside $()
INSTALLER_ISO=$(echo "$_ISO_DIR"/iso/*.iso)
echo "    ISO ready: $INSTALLER_ISO"

# ── Create VM (if it doesn't exist) ───────────────────────────────────────
echo "==> Checking if base VM exists..."
if ! prlctl list --all | grep -q "$BASE_VM"; then
  echo "    Creating Parallels VM '$BASE_VM'..."
  prlctl create "$BASE_VM" --ostype linux --distribution nixos --no-hdd
  prlctl set "$BASE_VM" --cpus 2 --memsize 4096 --device-add hdd --size 20480
  echo "    VM created"
else
  echo "    VM already exists — skipping creation"
fi

# ── Boot from custom ISO ───────────────────────────────────────────────────
echo "==> Attaching installer ISO and starting VM..."
prlctl set "$BASE_VM" --device-set cdrom0 --image "$INSTALLER_ISO" --connect
prlctl start "$BASE_VM"

# ── Wait for DHCP IP ───────────────────────────────────────────────────────
echo "==> Waiting for VM to get a DHCP IP (up to 120s)..."
DEADLINE=$(( $(date +%s) + 120 ))
VM_IP=""
while [[ -z "$VM_IP" || "$VM_IP" == "-" ]]; do
  if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
    echo "ERROR: Timed out waiting for VM IP" >&2; exit 1
  fi
  sleep 3
  VM_IP=$(prlctl list "$BASE_VM" -o ip --no-header | tr -d ' ')
done
echo "    VM IP: $VM_IP"

SSH_INSTALL="ssh -i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$VM_IP"

# ── Wait for SSH on the live ISO ───────────────────────────────────────────
echo -n "==> Waiting for SSH on live ISO..."
DEADLINE=$(( $(date +%s) + 120 ))
until $SSH_INSTALL true 2>/dev/null; do
  [[ "$(date +%s)" -ge "$DEADLINE" ]] && { echo; echo "ERROR: SSH timeout" >&2; exit 1; }
  printf '.'; sleep 5
done
echo " ready"

# ── Partition and install NixOS ────────────────────────────────────────────
echo "==> Partitioning and installing NixOS..."
$SSH_INSTALL bash -s <<'INSTALL'
set -euo pipefail
parted /dev/sda -- mklabel gpt
parted /dev/sda -- mkpart primary 512MB 100%
parted /dev/sda -- mkpart ESP fat32 1MB 512MB
parted /dev/sda -- set 2 esp on
mkfs.ext4 -L nixos /dev/sda1
mkfs.fat -F 32 -n boot /dev/sda2
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
nixos-generate-config --root /mnt
INSTALL

# ── Copy base config with key substituted ─────────────────────────────────
echo "==> Uploading base NixOS configuration..."
sed "s|__VM_KEY_PUB__|$PUB_KEY|g" "$REPO_ROOT/tests/vm/nixos-base.nix" \
  | $SSH_INSTALL "cat > /mnt/etc/nixos/configuration.nix"

# ── Install and reboot ────────────────────────────────────────────────────
echo "==> Running nixos-install (this takes several minutes)..."
$SSH_INSTALL "nixos-install --no-root-passwd && reboot" || true

# ── Wait for installed system to come up ──────────────────────────────────
echo -n "==> Waiting for installed system SSH (nixtest user, up to 300s)..."
SSH_TEST="ssh -i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null nixtest@$VM_IP"
DEADLINE=$(( $(date +%s) + 300 ))
until $SSH_TEST true 2>/dev/null; do
  [[ "$(date +%s)" -ge "$DEADLINE" ]] && { echo; echo "ERROR: SSH timeout after reboot" >&2; exit 1; }
  printf '.'; sleep 5
done
echo " ready"

# ── Snapshot clean state ──────────────────────────────────────────────────
echo "==> Snapshotting clean state..."
prlctl stop "$BASE_VM"
prlctl snapshot create "$BASE_VM" --name "$SNAP_NAME"
echo "==> Base VM ready. Snapshot '$SNAP_NAME' created."
