#!/usr/bin/env bash
set -euo pipefail

HOST="${ATM10_HOST:-zjn-home-two}"
SERVER_DIR="${ATM10_SERVER_DIR:-/Users/zacharynielsen/LocalServers/ATM10-server-7.0-intel-test}"
COMPUTER_DIR="${ATM10_COMPUTER_DIR:-$SERVER_DIR/Chem E boys Server - 7.0 test/computercraft/computer/6}"
DIAG="${ATM10_DIAG_CMD:-tools/atm10-diagnostics.sh}"
SIM="${ATM10_SIM_CMD:-lua tools/atm10-sim.lua}"
APPROVE_TIMEOUT="${ATM10_APPROVE_TIMEOUT:-120}"
APPROVE_INTERVAL="${ATM10_APPROVE_INTERVAL:-5}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
if [ -n "${ATM10_SSH_OPTS:-}" ]; then
  read -r -a SSH_OPTS <<< "$ATM10_SSH_OPTS"
fi

usage() {
  cat <<'USAGE'
Usage:
  tools/atm10-iterate.sh test
  tools/atm10-iterate.sh sim [scenario] [args...]
  tools/atm10-iterate.sh status
  tools/atm10-iterate.sh approve <target> [timeoutSec]
  tools/atm10-iterate.sh deploy-inventory

Commands:
  test              Run the local unit, smoke, simulator, and shell syntax checks.
  sim               Run a local manager simulator scenario (default: approval-aluminum).
  status            Print live doctor plus the compact approval/queue files.
  approve           Write a manager-owned live approval request and poll its result.
  deploy-inventory  Copy inventory-source files to the configured CC computer dir.

Environment:
  ATM10_HOST, ATM10_SERVER_DIR, ATM10_COMPUTER_DIR, ATM10_SSH_OPTS
  ATM10_DIAG_CMD, ATM10_SIM_CMD, ATM10_APPROVE_TIMEOUT, ATM10_APPROVE_INTERVAL
USAGE
}

quote_remote() {
  printf "%q" "$1"
}

remote_dir="$(quote_remote "$COMPUTER_DIR")"
server_dir="$(quote_remote "$SERVER_DIR")"

run_remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "cd $remote_dir && $1"
}

run_server_remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "cd $server_dir && $1"
}

now_ms() {
  printf '%s000\n' "$(date +%s)"
}

remote_now_ms() {
  run_remote 'printf "%s000\n" "$(date +%s)"'
}

lua_string_escape() {
  local value="$1"
  case "$value" in
    *$'\n'*|*$'\r'*)
      printf 'targets may not contain newlines\n' >&2
      exit 2
      ;;
  esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

npe_count() {
  run_server_remote 'grep -c "NullPointerException" logs/latest.log 2>/dev/null || true'
}

run_step() {
  local label="$1"
  shift
  printf '\n## %s\n' "$label"
  "$@"
}

run_tests() {
  run_step "lua tests/run.lua" lua tests/run.lua
  run_step "lua tests/smoke.lua" lua tests/smoke.lua
  run_step "lua tests/smoke_auto.lua" lua tests/smoke_auto.lua
  run_step "lua tests/smoke_sim.lua" lua tests/smoke_sim.lua
  run_step "lua tools/atm10-sim.lua all" lua tools/atm10-sim.lua all
  run_step "bash syntax" bash -n \
    tools/atm10-diagnostics.sh \
    tools/atm10-live-pass.sh \
    tools/atm10-iterate.sh
}

run_sim() {
  local scenario="${1:-approval-aluminum}"
  if [ "$#" -gt 0 ]; then shift; fi
  # shellcheck disable=SC2086
  $SIM "$scenario" "$@"
}

compact_live_files() {
  run_remote '
show_file() {
  name="$1"
  lines="${2:-80}"
  echo
  echo "## $name"
  if [ -f "$name" ]; then
    sed -n "1,${lines}p" "$name"
  else
    echo "missing"
  fi
}
show_file .atm10-approve-request 60
show_file .atm10-approve-result 80
echo
echo "## queue compact"
if [ -f .atm10-craft-queue ]; then
  grep -E "key =|state =|name =|label =|request =|approvedAt =|craftingAt =|jobId =|error =" .atm10-craft-queue || true
else
  echo "missing"
fi
echo
echo "## craft audit tail"
if [ -f .atm10-craft-audit ]; then
  tail -80 .atm10-craft-audit
else
  echo "missing"
fi
'
}

status() {
  "$DIAG" doctor
  compact_live_files
}

write_approve_request() {
  local target="$1"
  local requested_at="$2"
  local escaped payload
  escaped="$(lua_string_escape "$target")"
  payload="$(printf '{\n  target = "%s",\n  requestedAt = %s,\n}\n' "$escaped" "$requested_at")"
  printf '%s' "$payload" | ssh "${SSH_OPTS[@]}" "$HOST" \
    "cd $remote_dir && cat > .atm10-approve-request.tmp && mv .atm10-approve-request.tmp .atm10-approve-request"
}

poll_approve_result() {
  local requested_at="$1"
  run_remote "REQUESTED_AT=$(quote_remote "$requested_at")"'
fresh_result=false
if [ -f .atm10-approve-result ]; then
  at=$(sed -n "s/^[[:space:]]*at[[:space:]]*=[[:space:]]*//p" .atm10-approve-result | head -1 | sed "s/,$//")
  case "$at" in ""|*[!0-9]*) at=0 ;; esac
  if [ "$at" -ge "$REQUESTED_AT" ]; then fresh_result=true; fi
fi
if [ "$fresh_result" = true ]; then
  cat .atm10-approve-result
else
  echo "pending"
fi
'
}

approve() {
  local target="${1:-}"
  local timeout="${2:-$APPROVE_TIMEOUT}"
  if [ -z "$target" ]; then
    printf 'approve requires a target, e.g. alltheores:aluminum_ingot\n' >&2
    exit 2
  fi
  case "$timeout" in
    ""|*[!0-9]*) printf 'timeout must be numeric, got: %s\n' "$timeout" >&2; exit 2 ;;
  esac

  printf 'Preflight doctor before live approval...\n'
  "$DIAG" doctor

  local before request_at start output after
  before="$(npe_count)"
  request_at="$(remote_now_ms)"
  printf '\nWriting live approval request target=%s requestedAt=%s\n' "$target" "$request_at"
  write_approve_request "$target" "$request_at"

  start="$(date +%s)"
  while true; do
    output="$(poll_approve_result "$request_at")"
    if [ "$output" != "pending" ]; then
      printf '\n## approve result\n%s\n' "$output"
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      printf '\nTimed out waiting for .atm10-approve-result newer than %s\n' "$request_at" >&2
      compact_live_files
      exit 1
    fi
    printf '.'
    sleep "$APPROVE_INTERVAL"
  done

  printf '\nWaiting one poll for queue/craft audit to settle...\n'
  sleep "$APPROVE_INTERVAL"
  compact_live_files
  after="$(npe_count)"
  printf '\nnpeBefore=%s\nnpeAfter=%s\n' "$before" "$after"
}

deploy_inventory() {
  sftp "$HOST" <<SFTP
cd "$COMPUTER_DIR"
put inventory/manager.lua inventory-info
put inventory/manager-startup.lua startup
put atm10-approve.lua atm10-approve
put atm10-reload.lua atm10-reload
put atm10-update.lua update
put lib/atm10-status.lua atm10-status.lua
put lib/atm10-palette.lua atm10-palette.lua
put lib/atm10-draw.lua atm10-draw.lua
put lib/atm10-control.lua atm10-control.lua
put lib/atm10-stockplan.lua atm10-stockplan.lua
put lib/atm10-queue.lua atm10-queue.lua
put lib/atm10-craftrunner.lua atm10-craftrunner.lua
put lib/atm10-managed.lua atm10-managed.lua
put lib/atm10-balance.lua atm10-balance.lua
put lib/atm10-suggest.lua atm10-suggest.lua
put lib/atm10-presets.lua atm10-presets.lua
put lib/atm10-console.lua atm10-console.lua
put lib/atm10-health.lua atm10-health.lua
put lib/atm10-monitor.lua atm10-monitor.lua
put lib/atm10-pattern-give.lua atm10-pattern-give.lua
put atm10-bridge-probe.lua atm10-bridge-probe
put atm10-target-probe.lua atm10-target-probe
put atm10-patterns.lua atm10-patterns
put safereboot.lua safereboot
put reboot-guard.lua reboot
SFTP
}

case "${1:-test}" in
  test)
    run_tests
    ;;
  sim)
    shift
    run_sim "$@"
    ;;
  status)
    status
    ;;
  approve)
    shift
    approve "${1:-}" "${2:-$APPROVE_TIMEOUT}"
    ;;
  deploy-inventory)
    deploy_inventory
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
