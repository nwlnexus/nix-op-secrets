# VM-Based Integration Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automated VM-based integration tests to `nix-op-secrets` that exercise the full Home Manager activation path — real `op` CLI, real 1Password items, real file writes — inside an ephemeral Parallels NixOS VM, plus a committed manual guide for macOS VM testing.

**Architecture:** Eight sequential tasks producing files in dependency order: environment → Nix configs → scripts → guide. No stored VM binaries — the base VM is reproducibly created by `setup-base.sh` from a custom NixOS installer ISO built on the host. Each test run clones the base VM from a snapshot, mounts the repo, runs `nixos-rebuild switch`, asserts file outputs, and tears down via a `trap cleanup EXIT` registered before any side effects.

**Tech Stack:** Bash 5+ (with `set -euo pipefail`), Nix flakes, Parallels CLI (`prlctl` ≥26), 1Password CLI (`op`), NixOS 25.05, Home Manager 25.05, `jq`, `ssh`, `sed`

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `.gitignore` | Add `.env`, `.cache/`, `tests/vm/keys/` |
| Create | `.env.sample` | Developer setup instructions; committed template |
| Create | `tests/vm/fixtures/test-doc.txt` | Fixture uploaded as 1Password Document item |
| Create | `tests/vm/fixtures/infra.env.tpl` | `op inject` template referencing field secret |
| Create | `tests/vm/nixos-base.nix` | NixOS config for base VM; `__VM_KEY_PUB__` placeholder |
| Create | `tests/vm/configuration.nix` | HM config: all 4 secret types, fixed vault name |
| Create | `tests/vm/configuration-macos.nix` | Placeholder for macOS manual guide |
| Create | `tests/vm/flake.nix` | Stub flake: `nixosConfigurations.test-vm` + `darwinConfigurations.test-macos` |
| Generate | `tests/vm/flake.lock` | Produced by `nix flake lock` in `tests/vm/` |
| Create | `scripts/vm/setup-base.sh` | Idempotent base VM creation (SSH-driven install) |
| Create | `scripts/vm/run-tests.sh` | Clone → mount → provision → assert → teardown |
| Create | `scripts/test-vm.sh` | Entry point: prereq checks + calls subscripts |
| Create | `docs/vm-testing-macos.md` | Full manual walkthrough for macOS VM testing |

---

### Task 1: Environment setup

**Files:**
- Modify: `.gitignore`
- Create: `.env.sample`

- [ ] **Step 1: Verify the current `.gitignore` content**

  ```bash
  cat /path/to/nix-op-secrets/.gitignore
  ```
  Expected output:
  ```
  result
  result-*
  .direnv/
  ```

- [ ] **Step 2: Add the three new gitignore entries**

  Append to `.gitignore`:
  ```
  .env
  .cache/
  tests/vm/keys/
  ```

- [ ] **Step 3: Verify `.gitignore` now contains all required lines**

  ```bash
  grep -c "\.env\|\.cache/\|tests/vm/keys/" .gitignore
  ```
  Expected: `3`

- [ ] **Step 4: Create `.env.sample`**

  ```bash
  # Copy this file to .env — NEVER commit .env
  #
  # 1. Generate a 1Password service account token:
  #    https://developer.1password.com/docs/service-accounts/
  #    The account needs read+write access to the test vault.
  #
  # 2. The test vault name is fixed at "nix-op-secrets-test".
  #    Create it if it doesn't exist:
  #      op vault create nix-op-secrets-test
  #
  # 3. Place this file at the repo root as .env before running:
  #      ./scripts/test-vm.sh

  OP_SERVICE_ACCOUNT_TOKEN=ops_your_token_here
  ```

- [ ] **Step 5: Verify `.env` would be gitignored**

  ```bash
  touch /tmp/test-env && cp /tmp/test-env .env
  git check-ignore -v .env
  ```
  Expected: `.gitignore:4:.env	.env`
  Clean up: `rm .env`

- [ ] **Step 6: Commit**

  ```bash
  git add .gitignore .env.sample
  git commit -m "chore: add gitignore entries and .env.sample for VM testing"
  ```

---

### Task 2: Test fixtures

**Files:**
- Create: `tests/vm/fixtures/test-doc.txt`
- Create: `tests/vm/fixtures/infra.env.tpl`

These committed files are used during test runs: `test-doc.txt` is uploaded to 1Password as a Document item; `infra.env.tpl` is the `op inject` template referencing the field secret.

- [ ] **Step 1: Create the fixtures directory**

  ```bash
  mkdir -p tests/vm/fixtures
  ```

- [ ] **Step 2: Create `tests/vm/fixtures/test-doc.txt`**

  Content:
  ```
  nix-op-secrets test document fixture
  This file is uploaded to 1Password as a Document item during VM integration tests.
  ```

- [ ] **Step 3: Create `tests/vm/fixtures/infra.env.tpl`**

  Content:
  ```
  # op inject template — references the test field secret
  FIELD_VAL={{ op://nix-op-secrets-test/nix-op-secrets-test-field/password }}
  ```

  > The vault name `nix-op-secrets-test` and item title `nix-op-secrets-test-field` are hardcoded and match what `run-tests.sh` creates in step 3.

- [ ] **Step 4: Verify both files exist and have correct content**

  ```bash
  test -f tests/vm/fixtures/test-doc.txt && echo "test-doc.txt OK"
  grep -q "op://nix-op-secrets-test/nix-op-secrets-test-field/password" \
    tests/vm/fixtures/infra.env.tpl && echo "infra.env.tpl OK"
  ```
  Expected:
  ```
  test-doc.txt OK
  infra.env.tpl OK
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add tests/vm/fixtures/
  git commit -m "test: add VM integration test fixtures"
  ```

---

### Task 3: NixOS configs

**Files:**
- Create: `tests/vm/nixos-base.nix`
- Create: `tests/vm/configuration.nix`
- Create: `tests/vm/configuration-macos.nix`

- [ ] **Step 1: Create `tests/vm/nixos-base.nix`**

  This is the NixOS config template for the base VM. `setup-base.sh` substitutes the `__VM_KEY_PUB__` placeholder with the actual public key using `sed`.

  ```nix
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
  ```

- [ ] **Step 2: Verify `nixos-base.nix` contains the required fields**

  ```bash
  grep -c \
    "isNormalUser\|home.*nixtest\|__VM_KEY_PUB__\|hardware\.parallels\|wheelNeedsPassword" \
    tests/vm/nixos-base.nix
  ```
  Expected: `5`

- [ ] **Step 3: Create `tests/vm/configuration.nix`**

  This HM config is imported by the stub flake's `nixosConfigurations.test-vm`. All four secret types are declared; vault name is hardcoded to `nix-op-secrets-test`.

  ```nix
  # tests/vm/configuration.nix
  # Home Manager configuration for VM integration tests.
  # Declares all four op-secrets secret types against the fixed test vault.
  { ... }:
  {
    # Home Manager config for nixtest user (wired via flake.nix)
    home-manager.users.nixtest = {
      op-secrets = {
        enable  = true;
        serviceAccountTokenFile = "/etc/op-secrets-test-token";

        secrets = {
          # 1. Field — plain op:// reference
          test-field = {
            type   = "field";
            source = "op://nix-op-secrets-test/nix-op-secrets-test-field/password";
            dest   = "/home/nixtest/.local/secrets/field.txt";
          };

          # 2. SSH key — writes private + public key pair
          test-ssh = {
            type           = "sshKey";
            source         = "op://nix-op-secrets-test/nix-op-secrets-test-ssh";
            dest           = "/home/nixtest/.ssh/test-vm-key";
            writePublicKey = true;
          };

          # 3. Document — binary/text blob from 1Password
          test-doc = {
            type  = "document";
            vault = "nix-op-secrets-test";
            item  = "nix-op-secrets-test-doc";
            dest  = "/home/nixtest/.local/secrets/doc.txt";
          };

          # 4. Template — op inject using committed fixture
          test-template = {
            type     = "template";
            template = ./fixtures/infra.env.tpl;
            dest     = "/home/nixtest/.local/secrets/infra.env";
          };
        };
      };
    };
  }
  ```

- [ ] **Step 4: Create `tests/vm/configuration-macos.nix`**

  Placeholder referenced by `darwinConfigurations.test-macos` in `flake.nix`. Required so the flake evaluates cleanly; actual macOS testing is manual (see `docs/vm-testing-macos.md`).

  ```nix
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
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add tests/vm/nixos-base.nix tests/vm/configuration.nix tests/vm/configuration-macos.nix
  git commit -m "test: add NixOS base and HM test configurations for VM testing"
  ```

---

### Task 4: Stub flake

**Files:**
- Create: `tests/vm/flake.nix`
- Generate: `tests/vm/flake.lock`

The stub flake is evaluated inside the VM during `nixos-rebuild switch`. `op-secrets` is pinned to GitHub but overridden at test time via `--override-input`.

- [ ] **Step 1: Create `tests/vm/flake.nix`**

  ```nix
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
  ```

- [ ] **Step 2: Generate `tests/vm/flake.lock`**

  Run from the `tests/vm/` directory. This requires network access. The lock file pins all GitHub inputs for reproducible builds.

  ```bash
  cd tests/vm && nix flake lock
  ```

  Expected: `tests/vm/flake.lock` is created with entries for `nixpkgs`, `hm`, `op-secrets`, and `darwin`.

  Verify:
  ```bash
  nix flake metadata tests/vm 2>&1 | grep -E "nixpkgs|hm|op-secrets|darwin"
  ```

- [ ] **Step 3: Verify the flake evaluates**

  ```bash
  nix flake check tests/vm --no-build 2>&1 | tail -5
  ```

  Expected: exits 0 (or only warns about unfree packages which is fine since `nixpkgs.config.allowUnfree = true` is set in `nixos-base.nix` which is only evaluated for the NixOS system, not at the flake level).

  > If the check fails with an unfree error, it is expected — `hardware.parallels.enable` requires unfree and is only enabled when the NixOS system is actually built. The flake structure itself is sound.

- [ ] **Step 4: Commit**

  ```bash
  cd ../..  # return to repo root
  git add tests/vm/flake.nix tests/vm/flake.lock
  git commit -m "test: add stub flake for VM integration tests"
  ```

---

### Task 5: Base VM setup script

**Files:**
- Create: `scripts/vm/setup-base.sh`

`setup-base.sh` is idempotent — it skips each step if already done. On first run it: generates SSH keys, builds a custom NixOS installer ISO with the key baked in, creates a Parallels VM, boots the ISO, SSHes in as root to install NixOS, waits for the installed system to come up, and snapshots the clean state.

- [ ] **Step 1: Create the scripts directory**

  ```bash
  mkdir -p scripts/vm
  ```

- [ ] **Step 2: Write `scripts/vm/setup-base.sh`**

  ```bash
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
  _ISO_DIR=$(nix build --no-link --print-out-paths \
    --impure \
    --expr "
      let
        pkgs = import <nixpkgs> {};
      in (pkgs.nixos {
        imports = [ \"\${<nixpkgs>}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix\" ];
        services.openssh.enable = true;
        services.openssh.settings.PermitRootLogin = \"yes\";
        users.users.root.openssh.authorizedKeys.keys = [ \"$PUB_KEY\" ];
      }).config.system.build.isoImage
    " 2>/dev/null)
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
  ```

- [ ] **Step 3: Make the script executable**

  ```bash
  chmod +x scripts/vm/setup-base.sh
  ```

- [ ] **Step 4: Verify syntax**

  ```bash
  bash -n scripts/vm/setup-base.sh && echo "Syntax OK"
  ```
  Expected: `Syntax OK`

- [ ] **Step 5: Verify safety properties**

  ```bash
  grep -c \
    "set -euo pipefail\|DEADLINE.*date +%s\|prlctl snapshot-list.*clean\|sed.*__VM_KEY_PUB__" \
    scripts/vm/setup-base.sh
  ```
  Expected: `4`

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/vm/setup-base.sh
  git commit -m "feat: add idempotent base VM setup script"
  ```

---

### Task 6: Test runner script

**Files:**
- Create: `scripts/vm/run-tests.sh`

`run-tests.sh` clones the base VM, mounts the repo, creates 1Password test items, injects the service account token, runs `nixos-rebuild switch`, asserts all expected files exist with correct modes and content, and tears down. `trap cleanup EXIT` is registered as the very first statement.

- [ ] **Step 1: Write `scripts/vm/run-tests.sh`**

  ```bash
  #!/usr/bin/env bash
  # scripts/vm/run-tests.sh
  # Runs one full test cycle: clone base VM → provision → assert → teardown.
  # Called by scripts/test-vm.sh after prereq checks and OP_SERVICE_ACCOUNT_TOKEN is set.
  set -euo pipefail

  # ── Cleanup trap — registered FIRST, before any side effects ──────────────
  # Variables used in cleanup are initialised empty here so cleanup() is safe
  # to call at any point, even if the script exits before they are assigned.
  TEST_VM="" FIELD_ID="" SSH_ID="" DOC_ID=""
  VAULT="nix-op-secrets-test"

  cleanup() {
    echo "==> Cleanup..."
    [[ -n "$TEST_VM"   ]] && prlctl stop   "$TEST_VM" --kill 2>/dev/null || true
    [[ -n "$TEST_VM"   ]] && prlctl delete "$TEST_VM"        2>/dev/null || true
    for ID in ${FIELD_ID:-} ${SSH_ID:-} ${DOC_ID:-}; do
      [[ -n "$ID" ]] && op item delete "$ID" --vault "$VAULT" 2>/dev/null || true
    done
    echo "    Cleanup done"
  }
  trap cleanup EXIT

  # ── Variables (after trap registration) ───────────────────────────────────
  REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
  KEY_DIR="$REPO_ROOT/tests/vm/keys"
  BASE_VM="nix-op-secrets-base"
  TEST_VM="nix-op-secrets-test-$(date +%s)"
  SSH_OPTS="-i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

  # ── 1. Clone base VM ──────────────────────────────────────────────────────
  echo "==> Cloning '$BASE_VM' → '$TEST_VM'..."
  prlctl clone "$BASE_VM" --name "$TEST_VM" --snapshot "clean"
  prlctl start "$TEST_VM"

  # ── 2. Mount repo + get IP ────────────────────────────────────────────────
  echo "==> Mounting repo as shared folder..."
  prlctl set "$TEST_VM" \
    --shf-host-add nix-op-secrets \
    --shf-host-path "$REPO_ROOT" \
    --shf-host-ro off

  echo -n "==> Waiting for VM IP (up to 60s)..."
  DEADLINE=$(( $(date +%s) + 60 ))
  VM_IP=""
  while [[ -z "$VM_IP" || "$VM_IP" == "-" ]]; do
    [[ "$(date +%s)" -ge "$DEADLINE" ]] && { echo; echo "ERROR: Timed out waiting for VM IP" >&2; exit 1; }
    sleep 3
    VM_IP=$(prlctl list "$TEST_VM" -o ip --no-header | tr -d ' ')
  done
  echo " $VM_IP"

  echo -n "==> Waiting for SSH..."
  until ssh $SSH_OPTS nixtest@"$VM_IP" true 2>/dev/null; do
    printf '.'; sleep 3
  done
  echo " ready"

  SSH="ssh $SSH_OPTS nixtest@$VM_IP"

  # ── 3. Create test 1Password items ────────────────────────────────────────
  echo "==> Creating test 1Password items in vault '$VAULT'..."
  FIELD_ID=$(op item create \
    --vault "$VAULT" \
    --category Login \
    --title "nix-op-secrets-test-field" \
    "password=test-field-value" \
    --format json | jq -r '.id')
  echo "    Field item: $FIELD_ID"

  SSH_ID=$(op item create \
    --vault "$VAULT" \
    --category "SSH Key" \
    --title "nix-op-secrets-test-ssh" \
    --format json | jq -r '.id')
  echo "    SSH Key item: $SSH_ID"

  DOC_ID=$(op document create "$REPO_ROOT/tests/vm/fixtures/test-doc.txt" \
    --vault "$VAULT" \
    --title "nix-op-secrets-test-doc" \
    --format json | jq -r '.id')
  echo "    Document item: $DOC_ID"
  # Template uses fixtures/infra.env.tpl which references the field item — no extra item needed

  # ── 4. Inject service account token into VM ───────────────────────────────
  echo "==> Injecting service account token into VM..."
  $SSH "printf '%s' '$OP_SERVICE_ACCOUNT_TOKEN' | sudo tee /etc/op-secrets-test-token > /dev/null"

  # ── 5. Build and switch ───────────────────────────────────────────────────
  echo "==> Running nixos-rebuild switch (this takes several minutes)..."
  $SSH "sudo nixos-rebuild switch \
    --flake /media/psf/nix-op-secrets/tests/vm#test-vm \
    --override-input op-secrets path:/media/psf/nix-op-secrets \
    --no-write-lock-file 2>&1"
  echo "    Switch complete"

  # ── 6. Assertions ─────────────────────────────────────────────────────────
  echo "==> Running assertions..."

  fail()          { echo "FAIL: $1" >&2; exit 1; }
  check_file()    { $SSH "test -f '$1'" || fail "missing file: $1"; }
  check_mode()    { MODE=$($SSH "stat -c '%a' '$1'"); [[ "$MODE" == "$2" ]] || fail "mode $MODE != $2 on $1"; }
  check_content() { $SSH "grep -qF '$2' '$1'" || fail "expected '$2' in $1"; }

  # Field
  check_file "/home/nixtest/.local/secrets/field.txt"
  check_mode "/home/nixtest/.local/secrets/field.txt" "600"

  # SSH key pair
  check_file "/home/nixtest/.ssh/test-vm-key"
  check_mode "/home/nixtest/.ssh/test-vm-key" "600"
  check_file "/home/nixtest/.ssh/test-vm-key.pub"
  check_mode "/home/nixtest/.ssh/test-vm-key.pub" "644"

  # Document
  check_file "/home/nixtest/.local/secrets/doc.txt"
  check_mode "/home/nixtest/.local/secrets/doc.txt" "600"

  # Template output — must contain the resolved field value
  check_file    "/home/nixtest/.local/secrets/infra.env"
  check_content "/home/nixtest/.local/secrets/infra.env" "test-field-value"

  # Manifest — all five entries (including __pub synthetic key for sshKey)
  for KEY in test-field test-ssh "test-ssh__pub" test-doc test-template; do
    $SSH "jq -e '.\"$KEY\"' /home/nixtest/.local/state/op-secrets/manifest.json" > /dev/null \
      || fail "manifest missing key: $KEY"
  done

  echo ""
  echo "✓ All VM integration tests passed"
  ```

- [ ] **Step 2: Make executable**

  ```bash
  chmod +x scripts/vm/run-tests.sh
  ```

- [ ] **Step 3: Verify syntax**

  ```bash
  bash -n scripts/vm/run-tests.sh && echo "Syntax OK"
  ```
  Expected: `Syntax OK`

- [ ] **Step 4: Verify trap is registered before any `op item create`**

  ```bash
  # trap cleanup EXIT must appear before any "op item create" line
  TRAP_LINE=$(grep -n "trap cleanup EXIT" scripts/vm/run-tests.sh | head -1 | cut -d: -f1)
  FIRST_OP_LINE=$(grep -n "op item create" scripts/vm/run-tests.sh | head -1 | cut -d: -f1)
  [[ "$TRAP_LINE" -lt "$FIRST_OP_LINE" ]] && echo "Trap order OK" || echo "FAIL: trap after op item create"
  ```
  Expected: `Trap order OK`

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/vm/run-tests.sh
  git commit -m "feat: add VM test runner with cleanup trap and assertions"
  ```

---

### Task 7: Entry point script

**Files:**
- Create: `scripts/test-vm.sh`

`test-vm.sh` is the single command a developer runs. It sources `.env`, checks all prerequisites with actionable error messages, and then calls `setup-base.sh` and `run-tests.sh`.

- [ ] **Step 1: Write `scripts/test-vm.sh`**

  ```bash
  #!/usr/bin/env bash
  # scripts/test-vm.sh
  # Entry point for VM-based integration tests.
  # Usage: ./scripts/test-vm.sh
  #
  # Prerequisites:
  #   - Parallels Desktop ≥26 with prlctl on PATH
  #   - 1Password CLI (op) on PATH
  #   - .env at repo root containing OP_SERVICE_ACCOUNT_TOKEN
  #   - The "nix-op-secrets-test" vault must exist in your 1Password account
  set -euo pipefail

  REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
  ENV_FILE="$REPO_ROOT/.env"

  # ── Prereq: prlctl ────────────────────────────────────────────────────────
  if ! command -v prlctl &>/dev/null; then
    echo "ERROR: prlctl not found." >&2
    echo "  Install Parallels Desktop ≥26 and ensure prlctl is on your PATH." >&2
    echo "  Typically: /usr/local/bin/prlctl" >&2
    exit 1
  fi
  if ! prlctl list &>/dev/null; then
    echo "ERROR: prlctl is available but 'prlctl list' failed." >&2
    echo "  This usually means Parallels Desktop is not licensed or not running." >&2
    exit 1
  fi

  # ── Prereq: op CLI ────────────────────────────────────────────────────────
  if ! command -v op &>/dev/null; then
    echo "ERROR: 1Password CLI (op) not found." >&2
    echo "  Install it: brew install 1password-cli" >&2
    echo "  Or: https://developer.1password.com/docs/cli/get-started/" >&2
    exit 1
  fi

  # ── Prereq: .env ──────────────────────────────────────────────────────────
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found at $ENV_FILE" >&2
    echo "  Copy .env.sample to .env and fill in your service account token:" >&2
    echo "    cp .env.sample .env && \$EDITOR .env" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  # ── Prereq: OP_SERVICE_ACCOUNT_TOKEN ─────────────────────────────────────
  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    echo "ERROR: OP_SERVICE_ACCOUNT_TOKEN is not set in .env" >&2
    echo "  Generate a service account token at:" >&2
    echo "    https://developer.1password.com/docs/service-accounts/" >&2
    exit 1
  fi
  export OP_SERVICE_ACCOUNT_TOKEN

  # ── Prereq: op auth ───────────────────────────────────────────────────────
  if ! op vault list &>/dev/null; then
    echo "ERROR: 'op vault list' failed — service account token may be invalid or expired." >&2
    echo "  Check your token at: https://1password.com/sign-in" >&2
    exit 1
  fi

  # ── Prereq: test vault ────────────────────────────────────────────────────
  if ! op vault get nix-op-secrets-test &>/dev/null; then
    echo "The vault 'nix-op-secrets-test' does not exist in your 1Password account."
    printf "Create it now? [y/N] "
    read -r REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      op vault create nix-op-secrets-test
      echo "Vault created."
    else
      echo "ERROR: Please create the vault manually: op vault create nix-op-secrets-test" >&2
      exit 1
    fi
  fi

  # ── Run ───────────────────────────────────────────────────────────────────
  echo "==> All prerequisites satisfied"
  echo ""
  echo "==> Step 1: Ensure base VM exists (idempotent)"
  bash "$REPO_ROOT/scripts/vm/setup-base.sh"

  echo ""
  echo "==> Step 2: Run integration tests"
  bash "$REPO_ROOT/scripts/vm/run-tests.sh"
  ```

- [ ] **Step 2: Make executable**

  ```bash
  chmod +x scripts/test-vm.sh
  ```

- [ ] **Step 3: Verify syntax**

  ```bash
  bash -n scripts/test-vm.sh && echo "Syntax OK"
  ```
  Expected: `Syntax OK`

- [ ] **Step 4: Verify all six prereq checks are present**

  ```bash
  grep -c "ERROR:" scripts/test-vm.sh
  ```
  Expected: `7` (prlctl missing, prlctl license, op missing, .env missing, token missing, auth fail, and the else-branch vault message)

- [ ] **Step 5: Verify `.env` is sourced before token check**

  ```bash
  SRC_LINE=$(grep -n 'source.*ENV_FILE' scripts/test-vm.sh | head -1 | cut -d: -f1)
  TOK_LINE=$(grep -n 'OP_SERVICE_ACCOUNT_TOKEN.*:-' scripts/test-vm.sh | head -1 | cut -d: -f1)
  [[ "$SRC_LINE" -lt "$TOK_LINE" ]] && echo "Source order OK" || echo "FAIL"
  ```
  Expected: `Source order OK`

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/test-vm.sh
  git commit -m "feat: add test-vm.sh entry point with prereq checks"
  ```

---

### Task 8: macOS VM guide

**Files:**
- Create: `docs/vm-testing-macos.md`

This is a committed markdown guide covering the full manual macOS VM testing workflow. It cannot be automated (macOS VMs in Parallels require manual setup assistant interaction).

- [ ] **Step 1: Create `docs/vm-testing-macos.md`**

  ```markdown
  # macOS VM Testing Guide

  This guide covers the manual steps for testing the `nix-op-secrets` nix-darwin module
  inside a Parallels macOS VM. The Linux (NixOS) path is fully automated via
  `./scripts/test-vm.sh`; macOS requires manual VM setup due to Apple's setup assistant.

  ## Prerequisites

  | Requirement | Notes |
  |-------------|-------|
  | Parallels Desktop ≥26 | With `prlctl` on PATH |
  | macOS IPSW | Download via `softwareupdate --fetch-full-installer --full-installer-version <ver>` |
  | `op` CLI | `brew install 1password-cli` |
  | `.env` at repo root | See `.env.sample` — token must have access to `nix-op-secrets-test` vault |
  | `tests/vm/keys/` | Generated by `setup-base.sh` on the Linux path, or by running the keygen block below |

  ### Generate SSH keys (if not already present)

  If you haven't run the Linux test path first, generate keys manually:

  ```bash
  KEY_DIR="$(git rev-parse --show-toplevel)/tests/vm/keys"
  mkdir -p "$KEY_DIR"
  ssh-keygen -t ed25519 -C "nix-op-secrets-vm-test" -N "" -f "$KEY_DIR/vm_key"
  ```

  ## Steps

  ### 1. Download macOS IPSW

  ```bash
  softwareupdate --fetch-full-installer --full-installer-version 15.0
  # IPSW saved to ~/Library/Application Support/com.apple.SFSymbols/ or similar
  # Locate it: find ~/Library -name "*.ipsw" 2>/dev/null
  ```

  ### 2. Create the VM in Parallels

  Open Parallels Desktop → **File → New** → **Install macOS from IPSW** → select the IPSW.

  Settings:
  - Name: `nix-op-secrets-macos-base`
  - CPUs: 4
  - Memory: 8 GB
  - Disk: 60 GB

  ### 3. Complete setup assistant

  Boot the VM, complete the macOS setup assistant, create user **`nixtest`** with admin privileges.

  Enable Remote Login (required for SSH):

  ```bash
  # In the VM's Terminal:
  sudo systemsetup -setremotelogin on
  ```

  ### 4. Install tooling in the VM

  ```bash
  # In the VM's Terminal:

  # Nix (Determinate Systems installer — sets up flakes by default)
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install

  # nix-darwin
  nix run nix-darwin -- switch --flake ~/.config/darwin

  # 1Password CLI
  brew install 1password-cli
  ```

  ### 5. Authorise SSH from host

  From the **host machine** (after SSH keys have been generated):

  ```bash
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  VM_IP=<check Parallels UI or prlctl list -o ip>

  ssh-copy-id -i tests/vm/keys/vm_key.pub nixtest@"$VM_IP"
  # Alternatively, append tests/vm/keys/vm_key.pub to ~/.ssh/authorized_keys in the VM
  ```

  Test connectivity:

  ```bash
  ssh -i tests/vm/keys/vm_key $SSH_OPTS nixtest@"$VM_IP" echo "SSH OK"
  ```

  ### 6. Snapshot the base state

  ```bash
  prlctl snapshot create nix-op-secrets-macos-base --name "clean"
  ```

  ### 7. Create test 1Password items

  From the **host machine** (with `.env` sourced):

  ```bash
  source .env

  VAULT="nix-op-secrets-test"

  FIELD_ID=$(op item create \
    --vault "$VAULT" --category Login \
    --title "nix-op-secrets-test-field" \
    "password=test-field-value" \
    --format json | jq -r '.id')

  SSH_ID=$(op item create \
    --vault "$VAULT" --category "SSH Key" \
    --title "nix-op-secrets-test-ssh" \
    --format json | jq -r '.id')

  DOC_ID=$(op document create tests/vm/fixtures/test-doc.txt \
    --vault "$VAULT" \
    --title "nix-op-secrets-test-doc" \
    --format json | jq -r '.id')

  echo "FIELD_ID=$FIELD_ID  SSH_ID=$SSH_ID  DOC_ID=$DOC_ID"
  # Save these — needed for cleanup in step 11
  ```

  ### 8. Inject service account token into VM

  ```bash
  SSH_OPTS="-i tests/vm/keys/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  source .env

  ssh $SSH_OPTS nixtest@"$VM_IP" \
    "printf '%s' '$OP_SERVICE_ACCOUNT_TOKEN' | sudo tee /etc/op-secrets-test-token > /dev/null"
  ```

  ### 9. Mount repo and run darwin-rebuild

  ```bash
  # Mount the repo as a Parallels shared folder
  prlctl set nix-op-secrets-macos-base \
    --shf-host-add nix-op-secrets \
    --shf-host-path "$(pwd)"
  # The repo is now available at /Volumes/nix-op-secrets inside the VM

  # Run darwin-rebuild switch from the host over SSH
  # --override-input redirects op-secrets to the mounted checkout
  # --no-write-lock-file prevents modifying the committed flake.lock
  ssh $SSH_OPTS nixtest@"$VM_IP" \
    "sudo darwin-rebuild switch \
      --flake /Volumes/nix-op-secrets/tests/vm#test-macos \
      --override-input op-secrets path:/Volumes/nix-op-secrets \
      --no-write-lock-file"
  ```

  ### 10. Run assertions

  Same checks as the Linux automated path, executed over SSH:

  ```bash
  SSH="ssh $SSH_OPTS nixtest@$VM_IP"
  fail()          { echo "FAIL: $1" >&2; exit 1; }
  check_file()    { $SSH "test -f '$1'" || fail "missing: $1"; }
  check_mode()    { MODE=$($SSH "stat -f '%OLp' '$1'"); [[ "$MODE" == "$2" ]] || fail "mode $MODE != $2 on $1"; }
  check_content() { $SSH "grep -qF '$2' '$1'" || fail "expected '$2' in $1"; }

  check_file    "/Users/nixtest/.local/secrets/field.txt"
  check_mode    "/Users/nixtest/.local/secrets/field.txt" "600"
  check_file    "/Users/nixtest/.ssh/test-vm-key"
  check_mode    "/Users/nixtest/.ssh/test-vm-key" "600"
  check_file    "/Users/nixtest/.ssh/test-vm-key.pub"
  check_mode    "/Users/nixtest/.ssh/test-vm-key.pub" "644"
  check_file    "/Users/nixtest/.local/secrets/doc.txt"
  check_mode    "/Users/nixtest/.local/secrets/doc.txt" "600"
  check_file    "/Users/nixtest/.local/secrets/infra.env"
  check_content "/Users/nixtest/.local/secrets/infra.env" "test-field-value"

  for KEY in test-field test-ssh "test-ssh__pub" test-doc test-template; do
    $SSH "jq -e '.\"$KEY\"' /Users/nixtest/.local/state/op-secrets/manifest.json" > /dev/null \
      || fail "manifest missing: $KEY"
  done

  echo "All macOS VM integration tests passed"
  ```

  > **Note:** macOS uses `stat -f '%OLp'` (BSD stat) rather than `stat -c '%a'` (GNU stat used in the Linux scripts).

  ### 11. Cleanup

  ```bash
  # Revert VM to clean snapshot (ready for next test run)
  prlctl snapshot revert nix-op-secrets-macos-base "clean"

  # Delete test 1Password items
  source .env
  op item delete "$FIELD_ID" --vault nix-op-secrets-test
  op item delete "$SSH_ID"   --vault nix-op-secrets-test
  op item delete "$DOC_ID"   --vault nix-op-secrets-test
  ```
  ```

- [ ] **Step 2: Verify the guide exists and has all 11 sections**

  ```bash
  grep -cE "^### [0-9]+\." docs/vm-testing-macos.md
  ```
  Expected: `11`

- [ ] **Step 3: Commit**

  ```bash
  git add docs/vm-testing-macos.md
  git commit -m "docs: add macOS VM testing manual guide"
  ```

---

## Final verification

After all 8 tasks are complete:

- [ ] **Verify all expected files are in place**

  ```bash
  for F in \
    .env.sample \
    scripts/test-vm.sh \
    scripts/vm/setup-base.sh \
    scripts/vm/run-tests.sh \
    tests/vm/flake.nix \
    tests/vm/flake.lock \
    tests/vm/nixos-base.nix \
    tests/vm/configuration.nix \
    tests/vm/configuration-macos.nix \
    tests/vm/fixtures/test-doc.txt \
    tests/vm/fixtures/infra.env.tpl \
    docs/vm-testing-macos.md
  do
    test -f "$F" && echo "✓ $F" || echo "✗ MISSING: $F"
  done
  ```
  Expected: all lines show `✓`.

- [ ] **Verify scripts are all executable**

  ```bash
  for S in scripts/test-vm.sh scripts/vm/setup-base.sh scripts/vm/run-tests.sh; do
    test -x "$S" && echo "✓ $S" || echo "✗ NOT EXECUTABLE: $S"
  done
  ```

- [ ] **Verify gitignore covers all sensitive paths**

  ```bash
  for P in .env .cache/ tests/vm/keys/; do
    git check-ignore -q "$P" && echo "✓ $P is gitignored" || echo "✗ NOT IGNORED: $P"
  done
  ```

- [ ] **Syntax check all scripts**

  ```bash
  for S in scripts/test-vm.sh scripts/vm/setup-base.sh scripts/vm/run-tests.sh; do
    bash -n "$S" && echo "✓ $S syntax OK"
  done
  ```
