#!/usr/bin/env bash
set -euo pipefail

HOST="${ATM10_HOST:-zjn-home-two}"
COMPUTER_DIR="${ATM10_COMPUTER_DIR:-/Users/zacharynielsen/LocalServers/ATM10-server-7.0-intel-test/Chem E boys Server - 7.0 test/computercraft/computer/6}"
INTERVAL="${ATM10_DIAG_INTERVAL:-5}"

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

echo "# ATM10 diagnostics snapshot"
date "+time: %Y-%m-%d %H:%M:%S %Z"
printf "host: "; hostname
printf "dir: "; pwd

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
  ssh "$HOST" "cd $remote_dir && $1"
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
