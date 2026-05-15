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
# Patched ISO has 'autoinstall' added to the GRUB kernel cmdline so Ubuntu
# proceeds without the interactive "Continue with autoinstall? (yes/no)" prompt
# that Ubuntu 24.04 shows when the kernel parameter is absent.
UBUNTU_ISO_PATCHED="$CACHE_DIR/ubuntu-24.04.2-server-arm64-autoinstall.iso"

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
# `prlctl snapshot-list` only shows UUIDs by default; use JSON to read names.
if prlctl snapshot-list "$BASE_VM" -j 2>/dev/null | grep -q "\"name\": \"$SNAP_NAME\""; then
  echo "==> Base VM '$BASE_VM' already has snapshot '$SNAP_NAME' — nothing to do."
  exit 0
fi

# ── Download Ubuntu ISO ────────────────────────────────────────────────────
# 1.5 GB download — interruption-prone on flaky links.  We use a `.partial`
# file so a partial download isn't confused with a complete one; `curl -C -`
# resumes from the byte offset, and we retry up to 5 times with backoff.
mkdir -p "$CACHE_DIR"
if [[ ! -f "$UBUNTU_ISO_CACHE" ]]; then
  echo "==> Downloading Ubuntu Server 24.04 LTS arm64 ISO (~1.5 GB)..."
  curl -L --fail --progress-bar \
       --retry 5 --retry-delay 5 --retry-all-errors \
       -C - \
       -o "$UBUNTU_ISO_CACHE.partial" "$UBUNTU_ISO_URL"
  mv "$UBUNTU_ISO_CACHE.partial" "$UBUNTU_ISO_CACHE"
  echo "    Downloaded to $UBUNTU_ISO_CACHE"
else
  echo "==> Ubuntu ISO already cached at $UBUNTU_ISO_CACHE"
fi

# ── Patch Ubuntu ISO with autoinstall kernel parameter ────────────────────
# Ubuntu 24.04 subiquity requires 'autoinstall' on the kernel command line
# to proceed without an interactive confirmation prompt.  We patch the GRUB
# config in the ISO to add the parameter and rebuild the ISO using xorriso
# (obtained via nix-shell — no permanent install required).
if [[ ! -f "$UBUNTU_ISO_PATCHED" ]]; then
  echo "==> Patching Ubuntu ISO to add 'autoinstall' kernel parameter..."
  TMPDIR_GRUB=$(mktemp -d)
  bsdtar -xf "$UBUNTU_ISO_CACHE" -C "$TMPDIR_GRUB" boot/grub/grub.cfg
  # Insert 'autoinstall' before the '---' separator on linux kernel lines
  sed 's|\(^\tlinux.*\)  ---|\1 autoinstall ---|g' \
    "$TMPDIR_GRUB/boot/grub/grub.cfg" > "$TMPDIR_GRUB/grub-patched.cfg"
  nix-shell -p xorriso --run "
    xorriso -indev '$UBUNTU_ISO_CACHE' \
      -outdev '$UBUNTU_ISO_PATCHED' \
      -boot_image any replay \
      -map '$TMPDIR_GRUB/grub-patched.cfg' /boot/grub/grub.cfg \
      -commit 2>&1 | grep -E '(completed|ERROR|FAILURE)'
  "
  rm -rf "$TMPDIR_GRUB"
  echo "    Patched ISO created at $UBUNTU_ISO_PATCHED"
else
  echo "==> Patched Ubuntu ISO already cached at $UBUNTU_ISO_PATCHED"
fi

# ── Create autoinstall seed ISO ────────────────────────────────────────────
# Ubuntu's cloud-init NoCloud datasource reads from a disk labelled "cidata".
# The user-data file drives an unattended install (Ubuntu 24.04 subiquity).
echo "==> Creating autoinstall seed ISO..."
SEED_DIR=$(mktemp -d)
SEED_ISO="$CACHE_DIR/autoinstall-seed.iso"
HASHED_PASS=$(openssl passwd -6 'nix-test-vm')

# Write user-data with placeholders, then substitute (avoids $ escaping issues).
# SSH key injection uses subiquity's ssh.authorized-keys field — the official
# Ubuntu 24.04 autoinstall mechanism. This works once 'autoinstall' is in the
# kernel cmdline (we patch the ISO to add it). Earlier late-command attempts
# with curtin in-target failed during install.
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
    authorized-keys:
      - "PUB_KEY_PLACEHOLDER"
  storage:
    layout:
      name: direct
  packages:
    - curl
    - jq
    - git
  late-commands:
    # SSH keys are handled by ssh.authorized-keys above (subiquity's official
    # mechanism). Here we just add passwordless sudo for the test user.
    - echo 'nixtest ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/nixtest
    - chmod 440 /target/etc/sudoers.d/nixtest
YAML

# Substitute placeholders (using | delimiter to avoid / conflicts in hash/key)
sed -i '' "s|HASHED_PASS_PLACEHOLDER|${HASHED_PASS}|g" "$SEED_DIR/user-data"
sed -i '' "s|PUB_KEY_PLACEHOLDER|${PUB_KEY}|g" "$SEED_DIR/user-data"

# meta-data is required by cloud-init but can be empty
touch "$SEED_DIR/meta-data"

# Create ISO with volume label "cidata" (required for Ubuntu NoCloud detection).
# hdiutil makehybrid refuses to overwrite an existing file — remove it first.
rm -f "$SEED_ISO"
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
prlctl set "$BASE_VM" --device-set cdrom0 --image "$UBUNTU_ISO_PATCHED" --connect
# Add a second CD-ROM for the autoinstall seed
if ! prlctl list --all -i "$BASE_VM" | grep -q "cdrom1"; then
  prlctl set "$BASE_VM" --device-add cdrom --image "$SEED_ISO" --connect
else
  prlctl set "$BASE_VM" --device-set cdrom1 --image "$SEED_ISO" --connect
fi
prlctl start "$BASE_VM"

# ── Wait for DHCP IP ───────────────────────────────────────────────────────
echo "==> Waiting for VM to get a DHCP IP (up to 1800s)..."
# Parallels takes a while to surface the guest IP via prlctl on the first boot.
# Bumped from 600s → 1200s → 1800s based on observed behaviour (~10-15 min).
DEADLINE=$(( $(date +%s) + 1800 ))
VM_IP=""
while [[ -z "$VM_IP" || "$VM_IP" == "-" ]]; do
  if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
    echo "ERROR: Timed out waiting for VM IP" >&2; exit 1
  fi
  sleep 3
  # Disable pipefail temporarily — grep returns 1 when no IP yet, which would
  # otherwise abort the script under `set -o pipefail`.
  set +o pipefail
  VM_IP=$(prlctl list "$BASE_VM" -o ip --no-header 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  set -o pipefail
done
echo "    VM IP: $VM_IP"

# ── SSH options ────────────────────────────────────────────────────────────
# We use two SSH option sets:
#   *_INSECURE — only for the initial "is sshd alive" reachability poll. The
#                command we run is `true` (no payload), so an MITM gains
#                nothing.  This call exists solely to detect that the VM has
#                finished booting.
#   $SSH_BASE  — pinned to the captured host key.  Used for every call that
#                carries data: the Determinate Nix installer pipe and the
#                Nix verification.  Refuses to connect if the host key
#                changes (which would indicate a MITM or a re-imaged VM).
KNOWN_HOSTS_DIR="$REPO_ROOT/.cache/known_hosts"
KNOWN_HOSTS_FILE="$KNOWN_HOSTS_DIR/$BASE_VM"
mkdir -p "$KNOWN_HOSTS_DIR"

SSH_BASE_INSECURE="ssh -i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o PasswordAuthentication=no"

# ── Wait for Ubuntu autoinstall to complete and SSH to come up ────────────
# Ubuntu autoinstall takes ~10 minutes. We poll until SSH is available
# on the installed system (it reboots after install completes).
echo -n "==> Waiting for Ubuntu autoinstall + reboot + SSH (up to 20 min)..."
DEADLINE=$(( $(date +%s) + 1200 ))
until $SSH_BASE_INSECURE nixtest@"$VM_IP" true 2>/dev/null; do
  if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
    echo
    echo "ERROR: Timed out waiting for SSH after Ubuntu autoinstall" >&2
    exit 1
  fi
  printf '.'; sleep 10
done
echo " ready"

# ── Capture and pin the VM's host keys ─────────────────────────────────────
# Once sshd is responding, capture all offered host keys with ssh-keyscan
# and store them in a per-VM known_hosts file under .cache/ (gitignored).
# Every subsequent SSH call uses StrictHostKeyChecking=yes against that
# file, eliminating the MITM window on the security-sensitive
# Nix-installer pipe below.  Residual risk: the keyscan itself is TOFU on a
# local NAT'd Parallels network — adequate for dev use; for stronger
# guarantees pre-seed host keys via cloud-init.
echo "==> Capturing VM host keys → $KNOWN_HOSTS_FILE"
rm -f "$KNOWN_HOSTS_FILE"
ssh-keyscan -H -T 30 "$VM_IP" > "$KNOWN_HOSTS_FILE" 2>/dev/null
if [[ ! -s "$KNOWN_HOSTS_FILE" ]]; then
  echo "ERROR: ssh-keyscan returned no keys for $VM_IP" >&2
  exit 1
fi

SSH_BASE="ssh -i $KEY_DIR/vm_key -o UserKnownHostsFile=$KNOWN_HOSTS_FILE -o StrictHostKeyChecking=yes -o BatchMode=yes -o PasswordAuthentication=no"

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
prlctl snapshot "$BASE_VM" --name "$SNAP_NAME"
echo "==> Base VM ready. Snapshot '$SNAP_NAME' created."
