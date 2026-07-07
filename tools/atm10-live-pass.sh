#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/atm10-env.sh
. "$SCRIPT_DIR/atm10-env.sh"

DIAG="${ATM10_DIAG_CMD:-$SCRIPT_DIR/atm10-diagnostics.sh}"
OUT_ROOT="${ATM10_LIVE_PASS_OUT_DIR:-/tmp/atm10-live-pass}"
OBSERVE_SECONDS="${ATM10_LIVE_PASS_SECONDS:-120}"
OBSERVE_INTERVAL="${ATM10_LIVE_PASS_INTERVAL:-20}"
PING_PRIORITY="${ATM10_PING_PRIORITY:-2}"
PING_OPTIONS="${ATM10_PING_OPTIONS:-Done,Not now,Need details}"

usage() {
  cat <<'USAGE'
Usage:
  tools/atm10-live-pass.sh preflight
  tools/atm10-live-pass.sh observe [seconds]
  tools/atm10-live-pass.sh auto-soak-request [seconds]
  tools/atm10-live-pass.sh auto-soak-observe [seconds]
  tools/atm10-live-pass.sh ask-action <title> <body>
  tools/atm10-live-pass.sh npe-count

Stable-first live test wrapper. It is read-only except ask-action, which only
creates a K2 feedback item for Zach.

Commands:
  preflight   Run doctor, snapshot, and a server-log NPE baseline.
  observe     Capture snapshots for an observation window, then run doctor.
  auto-soak-request
              Run preflight, then ask Zach to start a bounded auto-mode soak.
  auto-soak-observe
              Observe a bounded auto-mode soak, then ask Zach to return manual.
  ask-action  Ping Zach through K2 feedback with a specific in-game request.
  npe-count   Count current NullPointerException lines in latest.log.

Environment:
  ATM10_SERVER_OPS_DIR, ATM10_SERVER_REGISTRY, ATM10_HOST_ID
  ATM10_HOST, ATM10_SERVER_DIR, ATM10_MINECRAFT_PORT, ATM10_SSH_OPTS
  ATM10_AUTO_SOAK_SECONDS    Default auto soak duration (default: 300)
  ATM10_LIVE_PASS_OUT_DIR    Output root (default: /tmp/atm10-live-pass)
  ATM10_LIVE_PASS_SECONDS    Default observe duration (default: 120)
  ATM10_LIVE_PASS_INTERVAL   Observe snapshot interval (default: 20)
  ATM10_PING_PRIORITY        K2 feedback priority 1-5 (default: 2)
  ATM10_PING_OPTIONS         K2 feedback options (default: Done,Not now,Need details)
USAGE
}

quote_remote() {
  printf "%q" "$1"
}

server_dir="$(quote_remote "$SERVER_DIR")"

new_run_dir() {
  local stamp dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$OUT_ROOT/$stamp"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

need_diag() {
  if [ ! -x "$DIAG" ]; then
    printf 'Missing diagnostics command: %s\n' "$DIAG" >&2
    exit 2
  fi
}

run_server_remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "cd $server_dir && $1"
}

npe_count() {
  run_server_remote 'grep -c "NullPointerException" logs/latest.log 2>/dev/null || true'
}

write_meta() {
  local dir="$1"
  {
    printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'host=%s\n' "$HOST"
    printf 'hostId=%s\n' "$ATM10_HOST_ID"
    printf 'registry=%s\n' "$ATM10_SERVER_REGISTRY"
    printf 'serverDir=%s\n' "$SERVER_DIR"
    printf 'diag=%s\n' "$DIAG"
  } > "$dir/meta.txt"
}

preflight() {
  need_diag
  local dir status
  dir="$(new_run_dir)"
  write_meta "$dir"
  printf 'Live-pass output: %s\n\n' "$dir"

  set +e
  "$DIAG" doctor | tee "$dir/01-doctor.txt"
  status=${PIPESTATUS[0]}
  set -e
  printf '\n' | tee -a "$dir/01-doctor.txt" >/dev/null
  printf 'npeCount=%s\n' "$(npe_count)" | tee "$dir/02-npe-before.txt"

  if [ "$status" -ne 0 ]; then
    printf '\nPreflight stopped: doctor failed. No live action requested.\n' | tee "$dir/summary.txt"
    exit "$status"
  fi

  "$DIAG" snapshot | tee "$dir/03-snapshot-before.txt" >/dev/null
  {
    printf 'result=ready\n'
    printf 'next=run observe while Zach performs exactly one requested in-game action\n'
    printf 'ask=tools/atm10-live-pass.sh ask-action "ATM10 action needed: <specific step>" "<exact action and stop condition>"\n'
  } | tee "$dir/summary.txt"
}

observe() {
  need_diag
  local seconds dir start end i
  seconds="${1:-$OBSERVE_SECONDS}"
  case "$seconds" in
    ""|*[!0-9]*) printf 'observe seconds must be numeric, got: %s\n' "$seconds" >&2; exit 2 ;;
  esac

  dir="$(new_run_dir)"
  write_meta "$dir"
  printf 'Live-pass observation output: %s\n' "$dir"
  printf 'seconds=%s interval=%s\n' "$seconds" "$OBSERVE_INTERVAL" | tee "$dir/observe.txt"
  printf 'npeBefore=%s\n' "$(npe_count)" | tee -a "$dir/observe.txt"

  start="$(date +%s)"
  end=$((start + seconds))
  i=1
  while [ "$(date +%s)" -lt "$end" ]; do
    printf '\n## snapshot %s %s\n' "$i" "$(date '+%H:%M:%S %Z')" | tee -a "$dir/observe.txt"
    "$DIAG" snapshot | tee "$dir/snapshot-$i.txt" >/dev/null
    sleep "$OBSERVE_INTERVAL"
    i=$((i + 1))
  done

  printf 'npeAfter=%s\n' "$(npe_count)" | tee -a "$dir/observe.txt"
  "$DIAG" doctor | tee "$dir/doctor-after.txt"
  printf '\nObservation complete: %s\n' "$dir"
}

ask_action() {
  local title body
  title="${1:-}"
  body="${2:-}"
  if [ -z "$title" ] || [ -z "$body" ]; then
    printf 'ask-action requires a title and body.\n\n' >&2
    usage >&2
    exit 2
  fi
  k2 feedback ask "$title" \
    --kind question \
    --priority "$PING_PRIORITY" \
    --options "$PING_OPTIONS" \
    --body "$body"
}

auto_soak_seconds() {
  local seconds="${1:-${ATM10_AUTO_SOAK_SECONDS:-300}}"
  case "$seconds" in
    ""|*[!0-9]*) printf 'auto soak seconds must be numeric, got: %s\n' "$seconds" >&2; exit 2 ;;
  esac
  printf '%s\n' "$seconds"
}

auto_soak_request() {
  local seconds
  seconds="$(auto_soak_seconds "${1:-}")"
  preflight
  ask_action \
    "ATM10 action needed: start bounded auto soak" \
    "Preflight passed. On computer 6, tap the mode chip once to arm AUTO, then tap the same chip again to enter auto. Do not approve, clear, or edit anything else. Leave it in auto for ${seconds}s while Codex observes. If anything looks wrong, tap the mode chip until it shows manual and reply Need details. Codex next runs: tools/atm10-live-pass.sh auto-soak-observe ${seconds}"
  printf '\nPING: Auto-soak request sent. After Zach confirms auto is on, run:\n'
  printf 'tools/atm10-live-pass.sh auto-soak-observe %s\n' "$seconds"
}

auto_soak_observe() {
  local seconds
  seconds="$(auto_soak_seconds "${1:-}")"
  observe "$seconds"
  ask_action \
    "ATM10 action needed: return manager to manual" \
    "The bounded auto observation window is complete. On computer 6, tap the mode chip until it shows manual, then reply Done. Codex will run one final status check."
  printf '\nPING: Auto-soak observation complete. Asked Zach to return the manager to manual.\n'
  printf 'After Zach confirms manual mode, run:\n'
  printf 'tools/atm10-iterate.sh status\n'
}

case "${1:-preflight}" in
  preflight)
    preflight
    ;;
  observe)
    shift
    observe "${1:-$OBSERVE_SECONDS}"
    ;;
  auto-soak-request)
    shift
    auto_soak_request "${1:-}"
    ;;
  auto-soak-observe)
    shift
    auto_soak_observe "${1:-}"
    ;;
  ask-action)
    shift
    ask_action "${1:-}" "${2:-}"
    ;;
  npe-count)
    npe_count
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
