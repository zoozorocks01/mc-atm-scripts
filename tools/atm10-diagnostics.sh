#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/atm10-env.sh
. "$SCRIPT_DIR/atm10-env.sh"

CC_RESTART_DRAIN_MS="${ATM10_CC_RESTART_DRAIN_MS:-120000}"
CC_RESTART_MAX_STALE_MS="${ATM10_CC_RESTART_MAX_STALE_MS:-90000}"
CC_RESTART_ALLOW_STALE="${ATM10_CC_RESTART_ALLOW_STALE:-false}"
INTERVAL="${ATM10_DIAG_INTERVAL:-5}"
OUT_DIR="${ATM10_DIAG_OUT_DIR:-/tmp/atm10-diagnostics}"

usage() {
  cat <<'USAGE'
Usage:
  tools/atm10-diagnostics.sh doctor
  tools/atm10-diagnostics.sh snapshot
  tools/atm10-diagnostics.sh save
  tools/atm10-diagnostics.sh watch
  tools/atm10-diagnostics.sh watch-log
  tools/atm10-diagnostics.sh files
  tools/atm10-diagnostics.sh screen-status
  tools/atm10-diagnostics.sh cc-safety
  tools/atm10-diagnostics.sh cc-dump [computer_id]
  tools/atm10-diagnostics.sh cc-turn-on [computer_id]
  tools/atm10-diagnostics.sh cc-restart [computer_id]  # disabled: unsafe with Advanced Peripherals RS bridge
  tools/atm10-diagnostics.sh chat <message>       # whisper the operator in-game (one line)
  tools/atm10-diagnostics.sh chat-log [lines]     # read recent player chat from the server log
  tools/atm10-diagnostics.sh highlight <x> <y> <z> [seconds]  # glowing in-world ping on a block (default 30s, max 300)
  tools/atm10-diagnostics.sh highlight-clear      # remove all highlight displays now

Environment overrides:
  ATM10_SERVER_OPS_DIR    MC server registry dir (default: ~/Projects/personal/mc-server-ops)
  ATM10_SERVER_REGISTRY   active-server.json path inside the registry dir
  ATM10_HOST_ID           registry host id to select (default: active host)
  ATM10_HOST              SSH host override (default: active host Tailscale IP)
  ATM10_SERVER_DIR        ATM10 server root on the host
  ATM10_MINECRAFT_PORT    Minecraft listen port (default: registry value or 25566)
  ATM10_COMPUTER_ID       ComputerCraft computer id (default: 6)
  ATM10_COMPUTER_DIR      ComputerCraft computer directory on the host
  ATM10_SCREEN_SESSION    screen session name for the running server console
  ATM10_CC_RESTART_DRAIN_MS  recent-craft drain window for cc-safety diagnostics (default: 120000)
  ATM10_CC_RESTART_MAX_STALE_MS  max trusted heartbeat/craftstate age (default: 90000)
  ATM10_CC_RESTART_ALLOW_STALE=true  emergency only: bypass stale cc-safety refusal after independently confirming no crafts
  ATM10_CHAT_PLAYER       in-game player the chat command whispers (default: Zoozorocks)
  ATM10_CHAT_FROM         sender tag shown in chat whispers (default: Claude; Codex sets Codex)
  ATM10_DIAG_INTERVAL     watch interval seconds (default: 5)
  ATM10_DIAG_OUT_DIR      save/watch-log output dir (default: /tmp/atm10-diagnostics)
  ATM10_SSH_OPTS          extra ssh options (default: batch mode, 8s connect timeout)
  ATM10_TRANSPORT         auto (default), local, or ssh; useful for diagnostics/testing
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

if [ -f .atm10-status ]; then
  status_summary=$(field_from .atm10-status summary | tr -d "\"")
  status_mode=$(field_from .atm10-status mode | tr -d "\"")
  status_page=$(field_from .atm10-status page | tr -d "\"")
  echo "statusFile: summary=${status_summary:-?} mode=${status_mode:-?} page=${status_page:-?}"
else
  echo "statusFile: missing .atm10-status (manager has not run the status-summary build yet)"
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
show_file .atm10-status 160
show_file .atm10-loopstate 120
show_file .atm10-craftstate 180
show_file .atm10-touchstate 120
show_file .atm10-approve-request 80
show_file .atm10-approve-result 80
show_file .atm10-planstate 220
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
show_file .atm10-target-probe.txt 220
'

run_remote() {
  atm10_run_in "$COMPUTER_DIR" "$1"
}

run_server_remote() {
  atm10_run_in "$SERVER_DIR" "$1"
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
  # Leading \r flushes any half-typed line stuck in the console input (observed
  # 2026-07-09: a stuck partial line silently ate every subsequent command for
  # 10 minutes). A flushed partial becomes a harmless "Unknown command" error;
  # a silently-eaten command is a lost whisper or a lost cc-dump.
  payload="$(quote_remote "$(printf '\r%s\r' "$command")")"
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
  echo "cc-safety: REFUSE missing .atm10-craftstate"
  exit 10
fi
if [ ! -f .atm10-heartbeat ]; then
  echo "cc-safety: REFUSE missing .atm10-heartbeat"
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
  echo "cc-safety: REFUSE$reasons"
  exit 10
fi
echo "cc-safety: no visible RS tasks activeCraftCount=$active queueCrafting=$queue_crafting crafting=$crafting"
echo "cc-safety: NOTE this does not prove a ComputerCraft detach restart is safe; Advanced Peripherals can retain hidden RS jobs"
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

doctor_failures=0
doctor_warnings=0

doctor_ok() {
  printf 'OK   %s\n' "$*"
}

doctor_warn() {
  doctor_warnings=$((doctor_warnings + 1))
  printf 'WARN %s\n' "$*"
}

doctor_fail() {
  doctor_failures=$((doctor_failures + 1))
  printf 'FAIL %s\n' "$*"
}

doctor_info() {
  printf 'INFO %s\n' "$*"
}

doctor_relay() {
  local line
  while IFS= read -r line; do
    case "$line" in
      OK\ *) doctor_ok "${line#OK }" ;;
      WARN\ *) doctor_warn "${line#WARN }" ;;
      FAIL\ *) doctor_fail "${line#FAIL }" ;;
      INFO\ *) doctor_info "${line#INFO }" ;;
      "") ;;
      *) doctor_info "$line" ;;
    esac
  done
}

doctor_server() {
  if run_server_remote 'pwd >/dev/null' >/dev/null 2>&1; then
    doctor_ok "server directory reachable: $SERVER_DIR"
  else
    doctor_fail "server directory unreachable on $HOST: $SERVER_DIR"
    return
  fi

  local port_q
  port_q="$(quote_remote "$MINECRAFT_PORT")"
  if run_server_remote "lsof -nP -iTCP:$port_q -sTCP:LISTEN >/dev/null 2>&1"; then
    doctor_ok "Minecraft port $MINECRAFT_PORT is listening"
  else
    doctor_fail "Minecraft port $MINECRAFT_PORT is not listening"
  fi

  local procs
  procs="$(run_server_remote 'ps -axo pid,etime,command | grep -E "[j]ava @user_jvm_args|[s]tartserver" || true')"
  if printf '%s\n' "$procs" | grep -q 'java @user_jvm_args'; then
    doctor_ok "Java server process is running"
  else
    doctor_fail "Java server process was not found"
  fi
  if printf '%s\n' "$procs" | grep -q 'startserver'; then
    doctor_ok "server wrapper process is running"
  else
    doctor_warn "server wrapper process was not found"
  fi

  local latest_crash age
  latest_crash="$(run_server_remote 'latest=$(ls -t crash-reports/crash-*-server.txt 2>/dev/null | head -1 || true); if [ -n "$latest" ]; then m=$(stat -f "%m" "$latest" 2>/dev/null || echo 0); now=$(date +%s); printf "%s ageSec=%s\n" "$(basename "$latest")" "$((now - m))"; fi')"
  if [ -z "$latest_crash" ]; then
    doctor_ok "no crash reports found"
  else
    age="${latest_crash##*ageSec=}"
    case "$age" in
      ""|*[!0-9]*) doctor_info "latest crash report: $latest_crash" ;;
      *)
        if [ "$age" -lt 3600 ]; then
          doctor_warn "latest crash report is recent: $latest_crash"
        else
          doctor_info "latest crash report: $latest_crash"
        fi
        ;;
    esac
  fi
}

doctor_cc_state() {
  local cc_lines
  if ! run_remote 'pwd >/dev/null' >/dev/null 2>&1; then
    doctor_fail "ComputerCraft directory unreachable on $HOST: $COMPUTER_DIR"
    return
  fi
  doctor_ok "ComputerCraft directory reachable: $COMPUTER_DIR"

  cc_lines="$(run_remote '
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
now_ms=$(($(date +%s) * 1000))

if [ -f .atm10-heartbeat ]; then
  hb=$(grep -Eo -- "-?[0-9]+" .atm10-heartbeat 2>/dev/null | head -1 || true)
  if [ -n "$hb" ]; then
    age=$(((now_ms - hb) / 1000))
    if [ "$age" -lt 0 ]; then age=0; fi
    if [ "$age" -le 30 ]; then
      echo "OK manager heartbeat fresh ageSec=$age"
    elif [ "$age" -le 90 ]; then
      echo "WARN manager heartbeat aging ageSec=$age"
    else
      echo "FAIL manager heartbeat stale ageSec=$age"
    fi
  else
    echo "FAIL manager heartbeat unreadable"
  fi
else
  echo "FAIL missing .atm10-heartbeat"
fi

if [ -f .atm10-loopstate ]; then
  loop_ms=$(as_int "$(field_from .atm10-loopstate loopMs)")
  load_pct=$(as_int "$(field_from .atm10-loopstate loadPct)")
  errors=$(as_int "$(field_from .atm10-loopstate errors)")
  last_error=$(field_from .atm10-loopstate lastError)
  echo "OK loopstate present loopMs=$loop_ms loadPct=$load_pct errors=$errors"
  if [ "$load_pct" -gt 80 ]; then echo "WARN manager loop load high loadPct=$load_pct"; fi
  if [ "$errors" -gt 0 ]; then echo "WARN manager loop has recorded errors=$errors"; fi
  if [ -n "$last_error" ] && [ "$last_error" != "nil" ] && [ "$last_error" != "none" ]; then
    echo "WARN manager loop lastError=$last_error"
  fi
else
  echo "WARN missing .atm10-loopstate"
fi

if [ -f .atm10-status ]; then
  status_at=$(field_from .atm10-status at)
  status_summary=$(field_from .atm10-status summary | tr -d "\"")
  status_mode=$(field_from .atm10-status mode | tr -d "\"")
  status_version=$(field_from .atm10-status version)
  approval_matcher=$(sed -n "s/^[[:space:]]*approvalMatcher[[:space:]]*=[[:space:]]*//p" .atm10-status | head -1 | sed "s/,$//")
  if [ -n "$status_at" ]; then
    age=$(((now_ms - $(as_int "$status_at")) / 1000))
    if [ "$age" -lt 0 ]; then age=0; fi
  else
    age=999999
  fi
  if [ "$age" -le 90 ]; then
    echo "OK status summary fresh ageSec=$age summary=${status_summary:-?} mode=${status_mode:-?} version=${status_version:-?} approvalMatcher=${approval_matcher:-?}"
  else
    echo "WARN status summary stale ageSec=$age summary=${status_summary:-?} mode=${status_mode:-?} version=${status_version:-?} approvalMatcher=${approval_matcher:-?}"
  fi
  if [ -n "$status_summary" ] && [ "$status_summary" != "OK" ]; then
    echo "WARN status summary reports $status_summary"
  fi
else
  echo "WARN missing .atm10-status; live manager may not have loaded the status-summary build yet"
fi

if [ -f .atm10-craftstate ]; then
  at=$(field_from .atm10-craftstate at)
  active=$(as_int "$(field_from .atm10-craftstate activeCraftCount)")
  q_crafting=$(as_int "$(field_from .atm10-craftstate queueCrafting)")
  q_failed=$(as_int "$(field_from .atm10-craftstate queueFailed)")
  q_stale=$(as_int "$(field_from .atm10-craftstate queueStale)")
  q_depth=$(as_int "$(field_from .atm10-craftstate queueDepth)")
  if [ -n "$at" ]; then
    age=$(((now_ms - $(as_int "$at")) / 1000))
    if [ "$age" -lt 0 ]; then age=0; fi
  else
    age=999999
  fi
  if [ "$age" -le 90 ]; then
    echo "OK craftstate fresh ageSec=$age activeCraftCount=$active queueDepth=$q_depth"
  else
    echo "FAIL craftstate stale ageSec=$age"
  fi
  if [ "$active" -gt 0 ] || [ "$q_crafting" -gt 0 ]; then
    echo "INFO crafts currently active activeCraftCount=$active queueCrafting=$q_crafting"
  fi
  if [ "$q_failed" -gt 0 ]; then echo "WARN queue has failed entries=$q_failed"; fi
  if [ "$q_stale" -gt 0 ]; then echo "WARN queue has stale local crafting entries=$q_stale"; fi
else
  echo "FAIL missing .atm10-craftstate"
fi

if [ -f .atm10-planstate ]; then
  echo "OK planstate present"
else
  echo "WARN missing .atm10-planstate; live manager may not have loaded the planstate diagnostics build yet"
fi
')"
  doctor_relay <<< "$cc_lines"
}

doctor_file_hashes() {
  local local_file remote_file local_hash remote_line remote_hash remote_q

  compare_cc_file() {
    local_file="$1"
    remote_file="$2"
    if [ ! -f "$local_file" ]; then
      doctor_warn "missing local file for hash check: $local_file"
      return
    fi
    local_hash="$(shasum "$local_file" | awk "{print \$1}")"
    remote_q="$(quote_remote "$remote_file")"
    if ! remote_line="$(run_remote "shasum $remote_q 2>/dev/null" 2>/dev/null)"; then
      doctor_fail "missing remote CC file: $remote_file"
      return
    fi
    remote_hash="${remote_line%% *}"
    if [ "$remote_hash" = "$local_hash" ]; then
      doctor_ok "CC file matches repo: $remote_file"
    else
      doctor_warn "CC file differs from repo: $remote_file (local $local_hash remote $remote_hash)"
    fi
  }

  compare_cc_file inventory-info.lua inventory-info
  compare_cc_file inventory-startup.lua startup
  compare_cc_file inventory-config-example.lua inventory-config-example
  compare_cc_file atm10-status.lua atm10-status.lua
  compare_cc_file atm10-palette.lua atm10-palette.lua
  compare_cc_file atm10-draw.lua atm10-draw.lua
  compare_cc_file atm10-control.lua atm10-control.lua
  compare_cc_file atm10-stockplan.lua atm10-stockplan.lua
  compare_cc_file atm10-queue.lua atm10-queue.lua
  compare_cc_file atm10-craftrunner.lua atm10-craftrunner.lua
  compare_cc_file atm10-managed.lua atm10-managed.lua
  compare_cc_file atm10-balance.lua atm10-balance.lua
  compare_cc_file atm10-suggest.lua atm10-suggest.lua
  compare_cc_file atm10-presets.lua atm10-presets.lua
  compare_cc_file atm10-console.lua atm10-console.lua
  compare_cc_file atm10-health.lua atm10-health.lua
  compare_cc_file atm10-monitor.lua atm10-monitor.lua
  compare_cc_file atm10-pattern-give.lua atm10-pattern-give.lua
  compare_cc_file atm10-bridge-probe.lua atm10-bridge-probe
  compare_cc_file atm10-target-probe.lua atm10-target-probe
  compare_cc_file atm10-approve.lua atm10-approve
  compare_cc_file atm10-patterns.lua atm10-patterns
  compare_cc_file safereboot.lua safereboot
  compare_cc_file reboot-guard.lua reboot
  compare_cc_file atm10-update.lua update
}

run_doctor() {
  doctor_failures=0
  doctor_warnings=0
  echo "# ATM10 readiness doctor"
  date "+time: %Y-%m-%d %H:%M:%S %Z"
  doctor_info "registry=$ATM10_SERVER_REGISTRY loaded=$ATM10_REGISTRY_LOADED role=$ATM10_REGISTRY_ROLE"
  doctor_info "hostId=$ATM10_HOST_ID"
  doctor_info "host=$HOST"
  doctor_info "minecraftPort=$MINECRAFT_PORT"
  doctor_info "serverDir=$SERVER_DIR"
  doctor_info "computerDir=$COMPUTER_DIR"
  echo
  echo "## server"
  doctor_server
  echo
  echo "## manager"
  doctor_cc_state
  echo
  echo "## deployed files"
  doctor_file_hashes
  echo
  if [ "$doctor_failures" -gt 0 ]; then
    printf 'RESULT: FAIL (%s failure(s), %s warning(s))\n' "$doctor_failures" "$doctor_warnings"
    return 1
  fi
  if [ "$doctor_warnings" -gt 0 ]; then
    printf 'RESULT: WARN (0 failures, %s warning(s))\n' "$doctor_warnings"
    return 0
  fi
  echo "RESULT: OK"
}

case "${1:-snapshot}" in
  doctor)
    run_doctor
    ;;
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
  cc-turn-on)
    computer_id="${2:-6}"
    validate_computer_id "$computer_id"
    screen_stuff "computercraft turn-on $computer_id"
    screen_stuff "computercraft dump $computer_id"
    printf 'Sent computercraft turn-on %s and dump to %s\n' "$computer_id" "$SCREEN_SESSION"
    ;;
  chat)
    # In-game relay, outbound half (docs/OPERATOR_MODE.md "In-game chat relay").
    # Whispers the OPERATOR (ATM10_CHAT_PLAYER) via the server console. Console
    # use here is CHAT ONLY -- tell/list; any other server command still needs
    # explicit human approval.
    shift
    chat_msg="$*"
    if [ -z "$chat_msg" ]; then
      printf 'chat requires a message, e.g. tools/atm10-diagnostics.sh chat "GO - watch the smelter"\n' >&2
      exit 2
    fi
    case "$chat_msg" in
      *$'\n'*|*$'\r'*) printf 'chat messages must be a single line\n' >&2; exit 2 ;;
    esac
    chat_player="${ATM10_CHAT_PLAYER:-Zoozorocks}"
    screen_stuff "tell $chat_player [$( echo "${ATM10_CHAT_FROM:-Claude}" )] $chat_msg"
    printf 'Whispered %s via %s\n' "$chat_player" "$SCREEN_SESSION"
    ;;
  chat-log)
    chat_lines="${2:-15}"
    case "$chat_lines" in ""|*[!0-9]*) chat_lines=15 ;; esac
    run_server_remote "grep -E '] \[Server thread/INFO] \[net.minecraft.server.MinecraftServer/]: <' logs/latest.log | tail -$chat_lines"
    ;;
  highlight)
    # Operator-requested visual ping (Zach, 2026-07-10): outline a block in-world
    # so test-session steps don't require navigating by raw coords. Summons a
    # glowing glass block_display over the target block plus a particle burst,
    # then kills ONLY its own uniquely-tagged entity after the timeout. This is
    # the one non-chat console verb with standing approval; the kill selector is
    # tag-scoped so it can never touch other entities.
    hl_x="${2:-}"; hl_y="${3:-}"; hl_z="${4:-}"; hl_secs="${5:-30}"
    for coord in "$hl_x" "$hl_y" "$hl_z"; do
      case "$coord" in ''|*[!0-9-]*|-|*?-*) printf 'highlight requires integer x y z, e.g. highlight 1149 75 2642 [seconds]\n' >&2; exit 2 ;; esac
    done
    case "$hl_secs" in ''|*[!0-9]*) hl_secs=30 ;; esac
    [ "$hl_secs" -gt 300 ] && hl_secs=300
    hl_tag="atm10-hl-$(date +%s)-$$"
    # Live-tested with Seth 2026-07-10. Lessons baked in: glass renders no
    # pixels so the glow shader outlines nothing; a display embedded flush in a
    # solid block can be occlusion-culled client-side. So each highlight places
    # an oversized opaque red skin on the block AND a floating marker two
    # blocks above it (open air, can't be culled), plus a particle burst.
    hl_marker_y=$((hl_y + 2))
    screen_stuff "summon minecraft:block_display $hl_x $hl_y $hl_z {Tags:[\"atm10-highlight\",\"$hl_tag\"],Glowing:1b,glow_color_override:16711680,brightness:{sky:15,block:15},block_state:{Name:\"minecraft:red_concrete\"},transformation:{translation:[-0.05f,-0.05f,-0.05f],scale:[1.10f,1.10f,1.10f],left_rotation:[0f,0f,0f,1f],right_rotation:[0f,0f,0f,1f]}}"
    screen_stuff "summon minecraft:block_display $hl_x $hl_marker_y $hl_z {Tags:[\"atm10-highlight\",\"$hl_tag\"],Glowing:1b,glow_color_override:16711680,brightness:{sky:15,block:15},block_state:{Name:\"minecraft:red_concrete\"},transformation:{translation:[0.25f,0.25f,0.25f],scale:[0.5f,0.5f,0.5f],left_rotation:[0f,0f,0f,1f],right_rotation:[0f,0f,0f,1f]}}"
    screen_stuff "particle minecraft:end_rod $hl_x.5 $hl_y.5 $hl_z.5 0.4 0.9 0.4 0.02 120 force"
    ( sleep "$hl_secs"; screen_stuff "kill @e[type=minecraft:block_display,tag=$hl_tag]" ) >/dev/null 2>&1 &
    printf 'Highlighted %s %s %s for %ss (tag %s) via %s\n' "$hl_x" "$hl_y" "$hl_z" "$hl_secs" "$hl_tag" "$SCREEN_SESSION"
    ;;
  highlight-clear)
    screen_stuff "kill @e[type=minecraft:block_display,tag=atm10-highlight]"
    printf 'Cleared all atm10-highlight block displays\n'
    ;;
  cc-restart)
    computer_id="${2:-6}"
    validate_computer_id "$computer_id"
    printf 'Refusing cc-restart for ComputerCraft computer %s.\n' "$computer_id" >&2
    printf 'Reason: computercraft shutdown detaches the computer; Advanced Peripherals RS bridge can still hold hidden craft jobs and crash with NotAttachedException.\n' >&2
    printf 'Use cc-dump for a non-detaching console refresh, or do a full server restart if the computer itself must be reset.\n' >&2
    exit 12
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
