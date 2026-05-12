#!/usr/bin/env bash
# Mock op CLI for testing. Records calls, returns predictable output.
CMD="$1"
shift

case "$CMD" in
  whoami)
    echo "test@example.com"
    exit 0
    ;;
  read)
    # Last argument is the URI
    URI="${!#}"
    case "$URI" in
      # sshKey fields — exact casing required by op CLI
      *"/private key")
        printf '-----BEGIN OPENSSH PRIVATE KEY-----\nmock-private-key\n-----END OPENSSH PRIVATE KEY-----\n'
        ;;
      *"/public key")
        echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 test@mock"
        ;;
      *)
        echo "mock-field-value-for-${URI}"
        ;;
    esac
    exit 0
    ;;
  document)
    # Parse: op document get <item> --vault <vault> --output <path>
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--output" ]]; then
        echo "mock-document-content" > "$2"
        exit 0
      fi
      shift
    done
    echo "mock-op: document get missing --output" >&2
    exit 1
    ;;
  inject)
    # Parse: op inject -i <template> -o <output>
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-o" ]]; then
        echo "MOCK_KEY=mock-injected-value" > "$2"
        exit 0
      fi
      shift
    done
    echo "mock-op: inject missing -o" >&2
    exit 1
    ;;
  signin)
    # Simulate successful signin
    exit 0
    ;;
  *)
    echo "mock-op: unknown command '$CMD'" >&2
    exit 1
    ;;
esac
