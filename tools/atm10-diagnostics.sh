#!/usr/bin/env bash
set -euo pipefail

HOST="${ATM10_HOST:-zjn-home-two}"
SERVER_DIR="${ATM10_SERVER_DIR:-/Users/zacharynielsen/LocalServers/ATM10-server-7.0-intel-test}"
COMPUTER_DIR="${ATM10_COMPUTER_DIR:-$SERVER_DIR/Chem E boys Server - 7.0 test/computercraft/computer/6}"
SCREEN_SESSION="${ATM10_SCREEN_SESSION:-atm10-intel-main-25566}"
CC_RESTART_DRAIN_MS="${ATM10_CC_RESTART_DRAIN_MS:-120000}"
CC_RESTART_MAX_STALE_MS="${ATM10_CC_RESTART_MAX_STALE_MS:-90000}"
CC_RESTART_ALLOW_STALE="${ATM10_CC_RESTART_ALLOW_STALE:-false}"
INTERVAL="${ATM10_DIAG_INTERVAL:-5}"
OUT_DIR="${ATM10_DIAG_OUT_DIR:-/tmp/atm10-diagnostics}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
if [ -n "${ATM10_SSH_OPTS:-}" ]; then
  read -r -a SSH_OPTS <<< "$ATM10_SSH_OPTS"
fi

usage() {
  cat <<'USAGE'
Usage:
  tools/atm10-diagnostics.sh snapshot
  tools/atm10-diagnostics.sh save
  tools/atm10-diagnostics.sh watch
  tools/atm10-diagnostics.sh watch-log
  tools/atm10-diagnostics.sh files
  tools/atm10-diagnostics.sh screen-status
  tools/atm10-diagnostics.sh cc-safety
  tools/atm10-diagnostics.sh cc-dump [computer_id]
  tools/atm10-diagnostics.sh cc-restart [computer_id]

Environment overrides:
  ATM10_HOST              SSH host alias (default: zjn-home-two)
  ATM10_SERVER_DIR        ATM10 server root on the host
  ATM10_COMPUTER_DIR      ComputerCraft computer directory on the host
  ATM10_SCREEN_SESSION    screen session name for the running server console
  ATM10_CC_RESTART_DRAIN_MS  recent-craft drain window before cc-restart (default: 120000)
  ATM10_CC_RESTART_MAX_STALE_MS  max trusted heartbeat/craftstate age (default: 90000)
  ATM10_CC_RESTART_ALLOW_STALE=true  bypass freshness refusal for explicit emergency use
  ATM10_DIAG_INTERVAL     watch interval seconds (default: 5)
  ATM10_DIAG_OUT_DIR      save/watch-log output dir (default: /tmp/atm10-diagnostics)
  ATM10_SSH_OPTS          extra ssh options (default: batch mode, 8s connect timeout)
USAGE
}

quote_remote() {
  printf "%q" "$1"
}

remote_dir="$(quote_remote "$COMPUTER_DIR")"
server_dir="$(quote_remote "$SERVER_DIR")"
screen_session="$(quote_remote "$SCREEN_SESSION")"

remote_snapshot='
show_file() {
  name="$1"
  lines="${2:-160}"
  echo
  echo "## $name"
  if [ -f "$name" ]; then
    sed -n "1,${lines}p" "$name"
  else
    echo "missing"
  fi
}

field_from() {
  file="$1"
  key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -1 | sed "s/,$//"
}

queue_count() {
  state="$1"
  if [ -f .atm10-craft-queue ]; then
    grep -c "state = \"${state}\"" .atm10-craft-queue 2>/dev/null || true
  else
    echo 0
  fi
}

echo "# ATM10 diagnostics snapshot"
date "+time: %Y-%m-%d %H:%M:%S %Z"
printf "host: "; hostname
printf "dir: "; pwd

echo
echo "## summary"
now_ms=$(($(date +%s) * 1000))
if [ -f .atm10-heartbeat ]; then
  hb=$(grep -Eo -- "-?[0-9]+" .atm10-heartbeat 2>/dev/null | head -1 || true)
  if [ -n "$hb" ]; then
    hb_age=$(((now_ms - hb) / 1000))
    echo "heartbeatAgeSec: $hb_age"
    if [ "$hb_age" -gt 90 ]; then echo "status: MANAGER HEARTBEAT STALE"; fi
  else
    echo "heartbeatAgeSec: unreadable"
  fi
else
  echo "heartbeatAgeSec: missing"
fi

if [ -f .atm10-loopstate ]; then
  loop_ms=$(field_from .atm10-loopstate loopMs)
  load_pct=$(field_from .atm10-loopstate loadPct)
  data_age=$(field_from .atm10-loopstate dataAgeMs)
  last_error=$(field_from .atm10-loopstate lastError)
  echo "loop: loopMs=${loop_ms:-?} loadPct=${load_pct:-?} dataAgeMs=${data_age:-?} lastError=${last_error:-none}"
  phase_lines=$(grep -E "scanCallMs|craftPhaseMs|broadcastMs|renderMs|configMs|peripheralMs|bridgeStatusMs|getItemsMs|indexItemsMs|planningMs|smartMs|queueMs|statsMs|totalMs" .atm10-loopstate 2>/dev/null | sed "s/^[[:space:]]*//; s/,$//" || true)
  if [ -n "$phase_lines" ]; then
    echo "loopPhases:"
    echo "$phase_lines" | sed "s/^/  /"
  fi
else
  echo "loop: missing .atm10-loopstate (manager has not run the loop-metrics build yet)"
fi

q_approved=$(queue_count APPROVED)
q_crafting=$(queue_count CRAFTING)
q_failed=$(grep -c "error =" .atm10-craft-queue 2>/dev/null || true)
active_count=$(field_from .atm10-craftstate activeCraftCount)
queue_stale=$(field_from .atm10-craftstate queueStale)
echo "queue: approved=$q_approved crafting=$q_crafting errors=$q_failed activeCraftCount=${active_count:-?} stale=${queue_stale:-?}"
if [ "$q_crafting" -gt 0 ] && [ "${active_count:-0}" = "0" ]; then
  echo "status: LOCAL CRAFTING ROWS BUT NO ACTIVE RS TASKS"
fi

echo
echo "## script files"
stat -f "%Sm %8z %N" \
  startup inventory-info atm10-queue.lua atm10-control.lua atm10-monitor.lua \
  .atm10-role inventory-config 2>/dev/null || true

show_file .atm10-heartbeat 20
show_file .atm10-loopstate 120
show_file .atm10-craftstate 180
show_file .atm10-craft-results 180
show_file .atm10-craft-audit 220

echo
echo "## queue compact"
if [ -f .atm10-craft-queue ]; then
  grep -E "state =|name =|label =|request =|requested =|made =|approvedAt =|craftingAt =|triedAt =|error =" .atm10-craft-queue || true
else
  echo "missing"
fi

show_file .atm10-bridge-probe.txt 220
'

run_remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "cd $remote_dir && $1"
}

run_server_remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "cd $server_dir && $1"
}

validate_computer_id() {
  case "${1:-}" in
    ""|*[!0-9]*)
      printf 'Computer id must be numeric, got: %s\n' "${1:-<empty>}" >&2
      exit 2
      ;;
  esac
}

screen_stuff() {
  local command payload
  command="$1"
  payload="$(quote_remote "$(printf '%s\r' "$command")")"
  run_server_remote "export SCREENDIR=$server_dir/.screen; screen -S $screen_session -p 0 -X stuff $payload"
}

cc_restart_safety() {
  local drain max_stale allow_stale
  drain="$(quote_remote "$CC_RESTART_DRAIN_MS")"
  max_stale="$(quote_remote "$CC_RESTART_MAX_STALE_MS")"
  allow_stale="$(quote_remote "$CC_RESTART_ALLOW_STALE")"
  run_remote "DRAIN_MS=$drain MAX_STALE_MS=$max_stale ALLOW_STALE=$allow_stale"'
field_from() {
  file="$1"
  key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -1 | sed "s/,$//"
}
as_int() {
  v="${1:-0}"
  case "$v" in ""|*[!0-9-]*) echo 0 ;; *) echo "$v" ;; esac
}
fresh_or_refuse() {
  label="$1"
  value="$2"
  if [ -z "$value" ]; then
    reasons="$reasons missing${label}"
    return
  fi
  value="$(as_int "$value")"
  age=$((now_ms - value))
  if [ "$age" -lt 0 ]; then age=0; fi
  if [ "$age" -gt "$MAX_STALE_MS" ]; then
    reasons="$reasons ${label}AgeMs=$age"
  fi
}
if [ ! -f .atm10-craftstate ]; then
  echo "cc-restart safety: REFUSE missing .atm10-craftstate"
  exit 10
fi
if [ ! -f .atm10-heartbeat ]; then
  echo "cc-restart safety: REFUSE missing .atm10-heartbeat"
  exit 10
fi
active="$(as_int "$(field_from .atm10-craftstate activeCraftCount)")"
queue_crafting="$(as_int "$(field_from .atm10-craftstate queueCrafting)")"
crafting="$(as_int "$(field_from .atm10-craftstate crafting)")"
last_craft="$(field_from .atm10-craftstate lastCraftAt)"
craftstate_at="$(field_from .atm10-craftstate at)"
heartbeat_at="$(grep -Eo -- "-?[0-9]+" .atm10-heartbeat 2>/dev/null | head -1 || true)"
now_ms=$(($(date +%s) * 1000))
reasons=""
if [ "$ALLOW_STALE" != "true" ]; then
  fresh_or_refuse heartbeat "$heartbeat_at"
  fresh_or_refuse craftstate "$craftstate_at"
fi
if [ "$active" -gt 0 ]; then reasons="$reasons activeCraftCount=$active"; fi
if [ "$queue_crafting" -gt 0 ]; then reasons="$reasons queueCrafting=$queue_crafting"; fi
if [ "$crafting" -gt 0 ]; then reasons="$reasons crafting=$crafting"; fi
if [ -n "$last_craft" ]; then
  last_craft="$(as_int "$last_craft")"
  age=$((now_ms - last_craft))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$DRAIN_MS" ]; then
    reasons="$reasons recentCraftAgeMs=$age"
  fi
fi
if [ -n "$reasons" ]; then
  echo "cc-restart safety: REFUSE$reasons"
  exit 10
fi
echo "cc-restart safety: ok activeCraftCount=$active queueCrafting=$queue_crafting crafting=$crafting"
'
}

save_snapshot() {
  mkdir -p "$OUT_DIR"
  local stamp out
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="$OUT_DIR/atm10-$stamp.txt"
  run_remote "$remote_snapshot" | tee "$out"
  printf "\nSaved snapshot: %s\n" "$out"
}

case "${1:-snapshot}" in
  snapshot)
    run_remote "$remote_snapshot"
    ;;
  save)
    save_snapshot
    ;;
  watch)
    while true; do
      clear 2>/dev/null || true
      run_remote "$remote_snapshot"
      sleep "$INTERVAL"
    done
    ;;
  watch-log)
    while true; do
      save_snapshot
      sleep "$INTERVAL"
    done
    ;;
  files)
    run_remote 'find . -maxdepth 1 -type f | sort'
    ;;
  screen-status)
    run_server_remote "export SCREENDIR=$server_dir/.screen; screen -ls || true"
    ;;
  cc-safety)
    cc_restart_safety
    ;;
  cc-dump)
    computer_id="${2:-6}"
    validate_computer_id "$computer_id"
    screen_stuff "computercraft dump $computer_id"
    printf 'Sent computercraft dump %s to %s\n' "$computer_id" "$SCREEN_SESSION"
    ;;
  cc-restart)
    computer_id="${2:-6}"
    validate_computer_id "$computer_id"
    cc_restart_safety
    screen_stuff "computercraft shutdown $computer_id"
    screen_stuff "computercraft turn-on $computer_id"
    screen_stuff "computercraft dump $computer_id"
    printf 'Sent safe restart for ComputerCraft computer %s to %s\n' "$computer_id" "$SCREEN_SESSION"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
