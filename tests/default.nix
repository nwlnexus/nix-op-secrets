# tests/default.nix
{ pkgs, lib }:
let
  mkActivation = import ../lib/mk-activation.nix;

  # Build a fake _1password-cli package that wraps our mock script
  mockOpPkg = pkgs.runCommand "mock-1password-cli" {} ''
    mkdir -p $out/bin
    cp ${./mock-op.sh} $out/bin/op
    chmod +x $out/bin/op
  '';

  fakePkgs = pkgs // {
    _1password-cli = mockOpPkg;
    # jq is real — we need it for manifest operations
  };

  # All dest paths use /DEST_BASE sentinel that gets replaced at test runtime
  cfg = {
    account = null;
    serviceAccountTokenFile = null;
    secrets = {
      "test-field" = {
        type = "field"; source = "op://Test/Item/password";
        dest = "/DEST_BASE/field.txt"; mode = "0600";
        vault = null; item = null; template = null; writePublicKey = false;
      };
      "test-ssh" = {
        type = "sshKey"; source = "op://Test/SSH Key";
        dest = "/DEST_BASE/id_ed25519"; mode = "0600";
        vault = null; item = null; template = null; writePublicKey = true;
      };
      "test-doc" = {
        type = "document"; vault = "Test"; item = "My Doc";
        dest = "/DEST_BASE/doc.txt"; mode = "0600";
        source = null; template = null; writePublicKey = false;
      };
      "test-template" = {
        type = "field"; source = null; template = ./infra.env.tpl;
        dest = "/DEST_BASE/infra.env"; mode = "0600";
        vault = null; item = null; writePublicKey = false;
      };
    };
  };

  # Build the activation script — string-interpolating it yields its executable store path
  activationScript = mkActivation { pkgs = fakePkgs; inherit lib cfg; };

in {
  integration = pkgs.runCommand "op-secrets-integration-test" {
    buildInputs = [ pkgs.jq pkgs.gnugrep ];
  } ''
    set -euo pipefail

    # Set up a writable HOME and dest directory within the sandbox temp space
    export HOME="$(mktemp -d)"
    export DEST_BASE="$(mktemp -d)"

    # The activation script has /DEST_BASE/ in its generated dest paths.
    # We patch those references to the actual temp path.
    SCRIPT_SRC="${activationScript}"
    SCRIPT="$(mktemp)"
    sed "s|/DEST_BASE|$DEST_BASE|g" "$SCRIPT_SRC" > "$SCRIPT"
    chmod +x "$SCRIPT"

    # Run the activation script
    bash "$SCRIPT" 2>&1

    # ── Assertions ──────────────────────────────────────────────────────────

    check() {
      local label="$1" path="$2" expected_mode="$3"
      [[ -f "$path" ]] || { echo "FAIL: $label — file missing: $path"; exit 1; }
      MODE=$(stat -f '%OLp' "$path" 2>/dev/null || stat -c '%a' "$path")
      [[ "$MODE" == "$expected_mode" ]] \
        || { echo "FAIL: $label — mode is $MODE, expected $expected_mode"; exit 1; }
      echo "PASS: $label"
    }

    check "field secret"     "$DEST_BASE/field.txt"  "600"
    check "ssh private key"  "$DEST_BASE/id_ed25519" "600"
    check "ssh public key"   "$DEST_BASE/id_ed25519.pub" "644"
    check "document secret"  "$DEST_BASE/doc.txt"    "600"
    check "template secret"  "$DEST_BASE/infra.env"  "600"

    # Verify SSH key content
    grep -q "BEGIN OPENSSH PRIVATE KEY" "$DEST_BASE/id_ed25519" \
      || { echo "FAIL: ssh private key content wrong"; exit 1; }
    grep -q "ssh-ed25519" "$DEST_BASE/id_ed25519.pub" \
      || { echo "FAIL: ssh public key content wrong"; exit 1; }

    # Verify manifest written
    MANIFEST="$HOME/.local/state/op-secrets/manifest.json"
    [[ -f "$MANIFEST" ]] || { echo "FAIL: manifest missing"; exit 1; }
    jq -e '.["test-field"]' "$MANIFEST" >/dev/null \
      || { echo "FAIL: test-field not in manifest"; exit 1; }
    jq -e '.["test-ssh"]' "$MANIFEST" >/dev/null \
      || { echo "FAIL: test-ssh not in manifest"; exit 1; }

    echo "All integration tests passed"
    touch $out
  '';
}
