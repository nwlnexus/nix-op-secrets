# Fast integration test design

**Status:** Existing test (`tests/default.nix`) extended in this branch; VM
test (`scripts/test-vm.sh`) repositioned as opt-in smoke.

## Background

The repository already had two test layers, one of which was undocumented:

| Layer | Where | Tooling | Time | What it asserts |
|---|---|---|---|---|
| **Fast hermetic** | `tests/default.nix` + `tests/mock-op.sh` | `pkgs.runCommand` + mock `op` | ~5 s | activation script, modes, manifest |
| **Real-API VM** | `scripts/test-vm.sh` + `scripts/vm/*` | Parallels + Ubuntu + real `op` | ~5 min | full home-manager switch with real 1Password |

The fast layer was already wired to `checks.<system>.integration` (so `nix flake check`
runs it on every supported system) but unmentioned in README/docs. A devil's-advocate
review of the VM test recommended building a hermetic test exactly like this. We don't
need to build it — it exists. We need to **document, strengthen, and reposition**.

## Goals

1. **Make the fast test discoverable.** Add to README + CONTRIBUTING. Mention in
   `docs/vm-testing-macos.md` so contributors reach for the right tool first.
2. **Close the assertion gap** between the fast test and the VM test, so the VM test
   adds value only where the real `op` CLI / real cloud / real activation system
   actually differs from the mock + script.
3. **Reposition the VM test** as an opt-in real-API smoke. Most regressions should be
   caught by `nix flake check` in seconds on any platform with Nix.

## What the fast test currently misses (gaps closed in this branch)

| Gap | Status before | Fix |
|---|---|---|
| Exact value of field secret | only checked file mode | assert `field.txt` content matches mock's deterministic output for the URI |
| Document content | only checked mode | assert exact content `mock-document-content` |
| Template substitution | only checked mode | assert `infra.env` contains `MOCK_KEY=mock-injected-value` (verifies `op inject` was actually invoked) |
| `__pub` manifest entry | not checked | assert `manifest["test-ssh__pub"]` exists when `writePublicKey = true` |
| Idempotency / re-switch | not exercised | re-run activation with the same cfg; assert manifest entries unchanged, files unchanged |
| Orphan removal | not exercised | re-run activation with `test-doc` removed from cfg; assert `doc.txt` is gone and `manifest["test-doc"]` removed |

These all use the existing mock — no new fixtures, no new infra, no test framework changes.

## What stays in the VM test (and only there)

These assertions can only be made against the real environment and are kept in the
opt-in VM suite:

- Real `op` CLI output format (the mock is necessarily a guess).
- Real Determinate Nix daemon + standalone Home-Manager `switch` lifecycle.
- Real systemd / activation ordering on Linux.
- Real service-account token plumbing (file ownership inherited through `sudo tee`).
- Real 1Password vault round-trip (would catch a vault rename, an `op` CLI breaking
  change, a service-account permissions regression).

Everything else — module evaluation, the activation script's logic, manifest correctness,
template substitution shape, file modes — is now covered hermetically and runs on Linux
and macOS via `nix flake check`.

## Compared with `pkgs.nixosTest`

The original task brief asked for a `pkgs.nixosTest`. After reading the existing test,
I argue against it:

- **`pkgs.nixosTest`** boots a full NixOS VM in QEMU. Pros: real systemd, real
  activation environment, real PAM. Cons: ~30–90 s per run, NixOS-only (the tests don't
  exercise standalone Home-Manager on Ubuntu, which is the most common real-world
  configuration), requires KVM in CI.
- **Existing `pkgs.runCommand` test** runs the same shell script the module emits, in
  the Nix sandbox, in ~5 s, on every supported system. The only thing it loses is
  systemd-mediated activation order — and home-manager's user activation isn't
  systemd-mediated anyway. It runs in the same shell context as a real switch.

Building a `nixosTest` on top would be additive but redundant: the assertions would be
identical and the upstream-breakage class it catches (NixOS-init changes) is too rare
to justify the added complexity.

**Decision:** strengthen `tests/default.nix`, don't add a `nixosTest`. Revisit if a
specific NixOS-only failure mode surfaces in the wild.

## Files changed

- `tests/default.nix` — extended assertions (exact content, idempotency, orphan removal).
- `tests/mock-op.sh` — `__pub` URI mapping clarified, no functional change.
- `README.md` — new "Testing" section surfaces the fast test as the default loop.
- `docs/vm-testing-macos.md` — reframed VM test as opt-in real-API smoke at the top.

## Non-goals

- Replacing `scripts/test-vm.sh`. It still catches the real-cloud regression class.
- Building negative-path tests in the fast suite (separate follow-up task is captured).
- Cross-version 1Password CLI matrix testing.
