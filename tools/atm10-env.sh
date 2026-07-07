#!/usr/bin/env bash

# Shared live-server resolver for ATM10 host tools. Source this from bash scripts.

ATM10_SERVER_OPS_DIR="${ATM10_SERVER_OPS_DIR:-$HOME/Projects/personal/mc-server-ops}"
ATM10_SERVER_REGISTRY="${ATM10_SERVER_REGISTRY:-$ATM10_SERVER_OPS_DIR/active-server.json}"
ATM10_DEFAULT_HOST="zjn-home-two"
ATM10_DEFAULT_SERVER_DIR="/Users/zacharynielsen/LocalServers/ATM10-server-7.0-intel-test"
ATM10_WORLD_NAME="${ATM10_WORLD_NAME:-Chem E boys Server - 7.0 test}"
ATM10_COMPUTER_ID="${ATM10_COMPUTER_ID:-6}"

atm10_registry_value() {
  local path="$1"
  [ -f "$ATM10_SERVER_REGISTRY" ] || return 1
  ATM10_JSON_PATH="$path" /usr/bin/python3 - "$ATM10_SERVER_REGISTRY" <<'PY'
import json
import os
import sys

registry_path = sys.argv[1]
field_path = os.environ["ATM10_JSON_PATH"].split(".")

with open(registry_path, "r", encoding="utf-8") as handle:
    value = json.load(handle)

for part in field_path:
    if not isinstance(value, dict) or part not in value:
        sys.exit(1)
    value = value[part]

if value is None:
    sys.exit(1)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

atm10_registry_value_or_empty() {
  atm10_registry_value "$1" 2>/dev/null || true
}

ATM10_REGISTRY_LOADED=false
ATM10_REGISTRY_ROLE="fallback"
atm10_registry_prefix="active"
if [ -f "$ATM10_SERVER_REGISTRY" ]; then
  ATM10_REGISTRY_LOADED=true
  if [ -n "${ATM10_HOST_ID:-}" ]; then
    if [ "$(atm10_registry_value_or_empty active.host_id)" = "$ATM10_HOST_ID" ]; then
      atm10_registry_prefix="active"
    elif [ "$(atm10_registry_value_or_empty standby.host_id)" = "$ATM10_HOST_ID" ]; then
      atm10_registry_prefix="standby"
    fi
  fi
  ATM10_REGISTRY_ROLE="$atm10_registry_prefix"
fi

atm10_registry_host_id="$(atm10_registry_value_or_empty "$atm10_registry_prefix.host_id")"
atm10_registry_hostname="$(atm10_registry_value_or_empty "$atm10_registry_prefix.hostname")"
atm10_registry_tailscale_ip="$(atm10_registry_value_or_empty "$atm10_registry_prefix.tailscale_ip")"
atm10_registry_server_dir="$(atm10_registry_value_or_empty "$atm10_registry_prefix.server_dir")"
atm10_registry_minecraft_port="$(atm10_registry_value_or_empty "$atm10_registry_prefix.minecraft_port")"

ATM10_HOST_ID="${atm10_registry_host_id:-${ATM10_HOST_ID:-unknown}}"
HOST="${ATM10_HOST:-${atm10_registry_tailscale_ip:-${atm10_registry_hostname:-$ATM10_DEFAULT_HOST}}}"
SERVER_DIR="${ATM10_SERVER_DIR:-${atm10_registry_server_dir:-$ATM10_DEFAULT_SERVER_DIR}}"
MINECRAFT_PORT="${ATM10_MINECRAFT_PORT:-${atm10_registry_minecraft_port:-25566}}"
COMPUTER_DIR="${ATM10_COMPUTER_DIR:-$SERVER_DIR/$ATM10_WORLD_NAME/computercraft/computer/$ATM10_COMPUTER_ID}"
SCREEN_SESSION="${ATM10_SCREEN_SESSION:-atm10-intel-main-25566}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
if [ -n "${ATM10_SSH_OPTS:-}" ]; then
  read -r -a SSH_OPTS <<< "$ATM10_SSH_OPTS"
elif [ -f "$ATM10_SERVER_OPS_DIR/known_hosts" ]; then
  SSH_OPTS+=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$ATM10_SERVER_OPS_DIR/known_hosts"
  )
fi
