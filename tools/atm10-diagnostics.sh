#!/usr/bin/env bash
set -euo pipefail

HOST="${ATM10_HOST:-zjn-home-two}"
COMPUTER_DIR="${ATM10_COMPUTER_DIR:-/Users/zacharynielsen/LocalServers/ATM10-server-7.0-intel-test/Chem E boys Server - 7.0 test/computercraft/computer/6}"
INTERVAL="${ATM10_DIAG_INTERVAL:-5}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
if [ -n "${ATM10_SSH_OPTS:-}" ]; then
  read -r -a SSH_OPTS <<< "$ATM10_SSH_OPTS"
fi

usage() {
  cat <<'USAGE'
Usage:
  tools/atm10-diagnostics.sh snapshot
  tools/atm10-diagnostics.sh watch
  tools/atm10-diagnostics.sh files

Environment overrides:
  ATM10_HOST              SSH host alias (default: zjn-home-two)
  ATM10_COMPUTER_DIR      ComputerCraft computer directory on the host
  ATM10_DIAG_INTERVAL     watch interval seconds (default: 5)
  ATM10_SSH_OPTS          extra ssh options (default: batch mode, 8s connect timeout)
USAGE
}

quote_remote() {
  printf "%q" "$1"
}

remote_dir="$(quote_remote "$COMPUTER_DIR")"

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

case "${1:-snapshot}" in
  snapshot)
    run_remote "$remote_snapshot"
    ;;
  watch)
    while true; do
      clear 2>/dev/null || true
      run_remote "$remote_snapshot"
      sleep "$INTERVAL"
    done
    ;;
  files)
    run_remote 'find . -maxdepth 1 -type f | sort'
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
