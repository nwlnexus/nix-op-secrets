#!/usr/bin/env bash
# scripts/vm/setup-base.sh
# Idempotent: creates the nix-op-secrets-base Parallels VM and snapshots it.
# Safe to run multiple times — skips steps already completed.
#
# What this does:
#   1. Downloads Ubuntu Server 24.04 LTS arm64 ISO (cached in .cache/)
#   2. Creates a cloud-init autoinstall seed ISO with our SSH key baked in
#   3. Boots a Parallels VM and lets Ubuntu install itself unattended (~10 min)
#   4. Installs Nix via the Determinate Systems installer (~3 min)
#   5. Snapshots the ready state
#
# No Linux builder required — we download a pre-built ISO.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
KEY_DIR="$REPO_ROOT/tests/vm/keys"
CACHE_DIR="$REPO_ROOT/.cache"
BASE_VM="nix-op-secrets-base"
SNAP_NAME="clean"

UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-arm64.iso"
UBUNTU_ISO_CACHE="$CACHE_DIR/ubuntu-24.04.2-server-arm64.iso"

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

# ── Download Ubuntu ISO ────────────────────────────────────────────────────
mkdir -p "$CACHE_DIR"
if [[ ! -f "$UBUNTU_ISO_CACHE" ]]; then
  echo "==> Downloading Ubuntu Server 24.04 LTS arm64 ISO (~1.5 GB)..."
  curl -L --progress-bar -o "$UBUNTU_ISO_CACHE" "$UBUNTU_ISO_URL"
  echo "    Downloaded to $UBUNTU_ISO_CACHE"
else
  echo "==> Ubuntu ISO already cached at $UBUNTU_ISO_CACHE"
fi

# ── Create autoinstall seed ISO ────────────────────────────────────────────
# Ubuntu's cloud-init NoCloud datasource reads from a disk labelled "cidata".
# The user-data file drives an unattended install (Ubuntu 24.04 subiquity).
echo "==> Creating autoinstall seed ISO..."
SEED_DIR=$(mktemp -d)
SEED_ISO="$CACHE_DIR/autoinstall-seed.iso"
HASHED_PASS=$(openssl passwd -6 'nix-test-vm')

# Write user-data with placeholders, then substitute (avoids $ escaping issues)
cat > "$SEED_DIR/user-data" << 'YAML'
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: nix-op-secrets-test
    username: nixtest
    password: "HASHED_PASS_PLACEHOLDER"
  ssh:
    install-server: true
    allow-pw: false
  storage:
    layout:
      name: direct
  packages:
    - curl
    - jq
    - git
  late-commands:
    # Explicitly set up SSH authorized_keys via late-commands — more reliable
    # than autoinstall's ssh.authorized-keys field.
    - mkdir -p /target/home/nixtest/.ssh
    - echo 'PUB_KEY_PLACEHOLDER' >> /target/home/nixtest/.ssh/authorized_keys
    - chmod 700 /target/home/nixtest/.ssh
    - chmod 600 /target/home/nixtest/.ssh/authorized_keys
    - chown -R 1000:1000 /target/home/nixtest/.ssh
    - echo 'nixtest ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/nixtest
    - chmod 440 /target/etc/sudoers.d/nixtest
YAML

# Substitute placeholders (using | delimiter to avoid / conflicts in hash/key)
sed -i '' "s|HASHED_PASS_PLACEHOLDER|${HASHED_PASS}|g" "$SEED_DIR/user-data"
sed -i '' "s|PUB_KEY_PLACEHOLDER|${PUB_KEY}|g" "$SEED_DIR/user-data"

# meta-data is required by cloud-init but can be empty
touch "$SEED_DIR/meta-data"

# Create ISO with volume label "cidata" (required for Ubuntu NoCloud detection).
hdiutil makehybrid -o "$SEED_ISO" -joliet -iso \
  -default-volume-name cidata "$SEED_DIR" 2>/dev/null
rm -rf "$SEED_DIR"
echo "    Seed ISO created at $SEED_ISO"

# ── Create VM ─────────────────────────────────────────────────────────────
# If the VM exists but has no clean snapshot it's a partial/failed previous
# run — stop and delete it so we start fresh.
echo "==> Checking if base VM exists..."
if prlctl list --all | grep -q "$BASE_VM"; then
  echo "    VM exists but has no clean snapshot — removing for fresh start..."
  prlctl stop "$BASE_VM" --kill 2>/dev/null || true
  prlctl delete "$BASE_VM"
fi
echo "    Creating Parallels VM '$BASE_VM'..."
prlctl create "$BASE_VM" --ostype linux --distribution ubuntu --no-hdd
prlctl set "$BASE_VM" --cpus 2 --memsize 4096 --device-add hdd --size 30720
echo "    VM created"

# ── Attach ISOs and boot ───────────────────────────────────────────────────
echo "==> Attaching Ubuntu ISO and seed ISO, starting VM..."
prlctl set "$BASE_VM" --device-set cdrom0 --image "$UBUNTU_ISO_CACHE" --connect
# Add a second CD-ROM for the autoinstall seed
if ! prlctl list --all -i "$BASE_VM" | grep -q "cdrom1"; then
  prlctl set "$BASE_VM" --device-add cdrom --image "$SEED_ISO" --connect
else
  prlctl set "$BASE_VM" --device-set cdrom1 --image "$SEED_ISO" --connect
fi
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

SSH_BASE="ssh -i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o PasswordAuthentication=no"

# ── Wait for Ubuntu autoinstall to complete and SSH to come up ────────────
# Ubuntu autoinstall takes ~10 minutes. We poll until SSH is available
# on the installed system (it reboots after install completes).
echo -n "==> Waiting for Ubuntu autoinstall + reboot + SSH (up to 20 min)..."
DEADLINE=$(( $(date +%s) + 1200 ))
until $SSH_BASE nixtest@"$VM_IP" true 2>/dev/null; do
  if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
    echo
    echo "ERROR: Timed out waiting for SSH after Ubuntu autoinstall" >&2
    exit 1
  fi
  printf '.'; sleep 10
done
echo " ready"

# ── Install Nix (Determinate Systems) ─────────────────────────────────────
echo "==> Installing Nix via Determinate Systems installer (~3 min)..."
$SSH_BASE nixtest@"$VM_IP" \
  "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
   | sudo sh -s -- install linux --no-confirm"
echo "    Nix installed"

# ── Verify Nix works ───────────────────────────────────────────────────────
echo "==> Verifying Nix..."
$SSH_BASE nixtest@"$VM_IP" \
  "source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && nix --version"

# ── Detach seed ISO and snapshot ──────────────────────────────────────────
echo "==> Detaching seed ISO and snapshotting clean state..."
prlctl stop "$BASE_VM"
prlctl set "$BASE_VM" --device-del cdrom1 2>/dev/null || true
prlctl snapshot create "$BASE_VM" --name "$SNAP_NAME"
echo "==> Base VM ready. Snapshot '$SNAP_NAME' created."
