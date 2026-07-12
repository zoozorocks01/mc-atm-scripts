#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ATM10_SERVER_OPS_DIR="$TMP/missing-registry"
export ATM10_HOST="100.64.0.42"
export ATM10_LOCAL_IPS="100.64.0.42 192.168.1.20"
export ATM10_SERVER_DIR="$TMP/server"
export ATM10_COMPUTER_DIR="$TMP/computer"
mkdir -p "$ATM10_SERVER_DIR" "$ATM10_COMPUTER_DIR"

# shellcheck source=../tools/atm10-env.sh
. "$ROOT/tools/atm10-env.sh"

atm10_host_is_local
result="$(atm10_run_in "$ATM10_SERVER_DIR" 'pwd; printf local-ok')"
[ "$result" = "$ATM10_SERVER_DIR
local-ok" ]

HOST="100.64.0.99"
if atm10_host_is_local; then
  printf 'non-local address was incorrectly classified as local\n' >&2
  exit 1
fi

ssh() {
  printf '%s\n' "$*"
}
result="$(atm10_run_in "$ATM10_SERVER_DIR" 'printf remote-ok')"
case "$result" in
  *"100.64.0.99"*"cd $ATM10_SERVER_DIR && printf remote-ok"*) ;;
  *) printf 'remote address did not dispatch through ssh: %s\n' "$result" >&2; exit 1 ;;
esac

ATM10_TRANSPORT=local
result="$(atm10_run_in "$ATM10_COMPUTER_DIR" 'printf forced-local')"
[ "$result" = "forced-local" ]

ATM10_TRANSPORT=invalid
if atm10_run_in "$ATM10_COMPUTER_DIR" 'printf must-not-run' >/dev/null 2>&1; then
  printf 'invalid transport was not rejected\n' >&2
  exit 1
fi

printf 'host tools smoke OK: local execution, SSH dispatch, and override validation\n'
