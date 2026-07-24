#!/usr/bin/env bash
set -euo pipefail

# Chat-driven live test sessions: the agent whispers each step to the operator
# in-game, the operator answers in normal chat (!ok / !no <note> / !skip /
# !abort), and evidence snapshots land in a timestamped session directory with
# a hypothesis -> result report. Scenarios live in tests/live/*.scenario.
#
# Scenario format (line-based, order matters):
#   TITLE: one line
#   HYPOTHESIS: one line
#   STEP zach: instruction whispered in-game; waits for !ok/!no/!skip/!abort
#   CAPTURE: space-separated tokens: queue craftstate audit status
#   CHECK: assertion for the driving agent to verify from the evidence
#   HIGHLIGHT: x y z [seconds] - glowing in-world ping on the block (diagnostics
#     highlight verb), so the operator never navigates by raw coords
# Blank lines and #-comments are ignored.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tools/atm10-env.sh
. "$SCRIPT_DIR/atm10-env.sh"

SCENARIO_DIR="$REPO_DIR/tests/live"
SESSION_ROOT="${ATM10_TEST_SESSION_DIR:-/tmp/atm10-test-sessions}"
POLL_SECS="${ATM10_TEST_POLL:-5}"
TIMEOUT_SECS="${ATM10_TEST_TIMEOUT:-600}"
CHAT_PLAYER="${ATM10_CHAT_PLAYER:-Zoozorocks}"

usage() {
  cat <<'USAGE'
Usage:
  tools/atm10-test-session.sh list
  tools/atm10-test-session.sh show <scenario>
  tools/atm10-test-session.sh run <scenario> [--dry-run]
  tools/atm10-test-session.sh selftest

Operator chat grammar (typed in normal in-game chat during `run`):
  !ok [note]    step done (optional note recorded)
  !no <note>    step done but observed something off (note recorded)
  !skip         skip this step
  !abort        end the session now

Environment overrides:
  ATM10_TEST_POLL         chat poll interval seconds (default 5)
  ATM10_TEST_TIMEOUT      per-step reply timeout seconds (default 600)
  ATM10_TEST_SESSION_DIR  session output root (default /tmp/atm10-test-sessions)
  plus everything tools/atm10-env.sh honours (host, player, sender tag, ...)
USAGE
}

scenario_path() {
  local name="${1%.scenario}"
  local path="$SCENARIO_DIR/$name.scenario"
  [ -f "$path" ] || { printf 'no such scenario: %s\n' "$name" >&2; exit 2; }
  printf '%s' "$path"
}

whisper() {
  "$SCRIPT_DIR/atm10-diagnostics.sh" chat "$1" >/dev/null
}

chat_tail() {
  atm10_run_in "$SERVER_DIR" \
    "grep -E '] \[Server thread/INFO] \[net.minecraft.server.MinecraftServer/]: <' logs/latest.log | tail -40" \
    2>/dev/null || true
}

# Extract operator commands (lines like `<Zoozorocks> !ok note`) from a chat
# tail. Prints `!cmd note` per line.
parse_commands() {
  sed -n "s/.*: <$CHAT_PLAYER> \(![a-z]*.*\)/\1/p"
}

# Wait for the first operator command whose full timestamped chat line was not
# already seen. Store raw lines rather than just `!ok`: a later, legitimate
# `!ok` must not be mistaken for an earlier reply with the same text.
# Prints the command; returns 1 on timeout.
wait_for_reply() {
  local seen_file="$1" deadline=$((SECONDS + TIMEOUT_SECS)) line command
  while [ "$SECONDS" -lt "$deadline" ]; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! grep -qxF "$line" "$seen_file"; then
        printf '%s\n' "$line" >>"$seen_file"
        command="$(printf '%s\n' "$line" | parse_commands)"
        if [ -n "$command" ]; then
          printf '%s' "$command"
          return 0
        fi
      fi
    done < <(chat_tail)
    sleep "$POLL_SECS"
  done
  return 1
}

capture() {
  local token="$1" dest="$2"
  case "$token" in
    queue)      atm10_run_in "$COMPUTER_DIR" "cat .atm10-craft-queue" >"$dest" 2>/dev/null || true ;;
    craftstate) atm10_run_in "$COMPUTER_DIR" "cat .atm10-craftstate" >"$dest" 2>/dev/null || true ;;
    status)     atm10_run_in "$COMPUTER_DIR" "cat .atm10-status" >"$dest" 2>/dev/null || true ;;
    audit)      atm10_run_in "$COMPUTER_DIR" "tail -200 .atm10-craft-audit" >"$dest" 2>/dev/null || true ;;
    *)          printf 'unknown capture token: %s\n' "$token" >&2 ;;
  esac
}

run_scenario() {
  local path="$1" dry="$2"
  local name; name="$(basename "${path%.scenario}")"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local session="$SESSION_ROOT/$stamp-$name"
  local report="$session/report.md" seen="$session/.chat-seen"
  local step=0 aborted=false

  if [ "$dry" = true ]; then
    printf '== dry run: %s ==\n' "$name"
  else
    mkdir -p "$session"
    : >"$seen"
    # Pre-seed with current timestamped chat lines so stale replies are never
    # consumed, while a later identical command is still accepted.
    chat_tail >>"$seen" || true
    {
      printf '# Test session: %s\n\n' "$name"
      printf -- '- started: %s\n- host: %s\n- operator: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$HOST" "$CHAT_PLAYER"
    } >"$report"
    capture craftstate "$session/00-baseline-craftstate"
    capture status "$session/00-baseline-status"
  fi

  while IFS= read -r raw || [ -n "$raw" ]; do
    local line="${raw%%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
      TITLE:*)
        local title="${line#TITLE:}"
        if [ "$dry" = true ]; then printf 'TITLE:%s\n' "$title"; else printf '## %s\n\n' "${title# }" >>"$report"; fi
        ;;
      HYPOTHESIS:*)
        local hyp="${line#HYPOTHESIS:}"
        if [ "$dry" = true ]; then printf 'HYPOTHESIS:%s\n' "$hyp"; else printf '**Hypothesis:** %s\n\n' "${hyp# }" >>"$report"; fi
        ;;
      STEP\ zach:*)
        step=$((step + 1))
        local instr="${line#STEP zach:}"; instr="${instr# }"
        if [ "$dry" = true ]; then
          printf 'STEP %d (zach): %s\n' "$step" "$instr"
          continue
        fi
        whisper "[$step] $instr"
        printf -- '- **Step %d (Zach):** %s\n' "$step" "$instr" >>"$report"
        local reply
        if reply="$(wait_for_reply "$seen")"; then
          printf -- '  - reply: `%s`\n' "$reply" >>"$report"
          case "$reply" in
            '!abort'*) aborted=true; break ;;
            '!skip'*) ;;
          esac
        else
          printf -- '  - reply: TIMEOUT after %ss\n' "$TIMEOUT_SECS" >>"$report"
          whisper "[$step] timed out after ${TIMEOUT_SECS}s - ending session"
          aborted=true
          break
        fi
        ;;
      CAPTURE:*)
        local tokens="${line#CAPTURE:}"
        if [ "$dry" = true ]; then printf 'CAPTURE:%s\n' "$tokens"; continue; fi
        local t
        for t in $tokens; do
          capture "$t" "$session/$(printf '%02d' "$step")-$t"
          printf -- '  - evidence: `%02d-%s`\n' "$step" "$t" >>"$report"
        done
        ;;
      CHECK:*)
        local check="${line#CHECK:}"
        if [ "$dry" = true ]; then printf 'CHECK:%s\n' "$check"; else printf -- '- **Check:** %s\n' "${check# }" >>"$report"; fi
        ;;
      HIGHLIGHT:*)
        local hl="${line#HIGHLIGHT:}"; hl="${hl# }"
        if [ "$dry" = true ]; then printf 'HIGHLIGHT: %s\n' "$hl"; continue; fi
        # shellcheck disable=SC2086
        "$SCRIPT_DIR/atm10-diagnostics.sh" highlight $hl >/dev/null || true
        printf -- '  - highlighted in-world: `%s`\n' "$hl" >>"$report"
        ;;
      *)
        printf 'unrecognized scenario line: %s\n' "$line" >&2
        ;;
    esac
  done <"$path"

  if [ "$dry" = true ]; then return 0; fi
  if [ "$aborted" = true ]; then
    printf '\n**Session ended early (abort/timeout).**\n' >>"$report"
    whisper "session $name ended early - evidence at $session"
  else
    printf '\n**All steps completed.** Verdict: _fill in from the checks above._\n' >>"$report"
    whisper "session $name complete - thanks! Report: $session"
  fi
  printf 'session dir: %s\nreport: %s\n' "$session" "$report"
}

selftest() {
  local fixture; fixture="$(mktemp)"
  cat >"$fixture" <<EOF
[10Jul2026 13:01:02.123] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: <$CHAT_PLAYER> hello there
[10Jul2026 13:01:05.456] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: <SomeoneElse> !ok not me
[10Jul2026 13:01:09.789] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: <$CHAT_PLAYER> !ok smelter facing fixed
[10Jul2026 13:01:12.000] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: <$CHAT_PLAYER> !no second task frozen at 0%
EOF
  local got expected
  got="$(parse_commands <"$fixture")"
  expected=$'!ok smelter facing fixed\n!no second task frozen at 0%'
  rm -f "$fixture"
  if [ "$got" = "$expected" ]; then
    printf 'selftest OK: parser extracts operator commands only\n'
  else
    printf 'selftest FAIL\n-- got --\n%s\n-- expected --\n%s\n' "$got" "$expected" >&2
    exit 1
  fi

  local seen old_reply fresh_reply
  seen="$(mktemp)"
  old_reply='[10Jul2026 13:01:09.789] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: <Zoozorocks> !ok'
  fresh_reply='[10Jul2026 13:02:09.789] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: <Zoozorocks> !ok'
  printf '%s\n' "$old_reply" >"$seen"
  if grep -qxF "$fresh_reply" "$seen"; then
    printf 'selftest FAIL: a later identical command was treated as stale\n' >&2
    rm -f "$seen"
    exit 1
  fi
  printf '%s\n' "$fresh_reply" >>"$seen"
  got="$(printf '%s\n' "$fresh_reply" | parse_commands)"
  rm -f "$seen"
  if [ "$got" = '!ok' ]; then
    printf 'selftest OK: later identical commands remain distinct chat events\n'
  else
    printf 'selftest FAIL: later command parsing failed\n' >&2
    exit 1
  fi
}

cmd="${1:-}"
case "$cmd" in
  list)
    ls "$SCENARIO_DIR"/*.scenario 2>/dev/null | while IFS= read -r f; do
      printf '%-28s %s\n' "$(basename "${f%.scenario}")" "$(sed -n 's/^TITLE: *//p' "$f" | head -1)"
    done
    ;;
  show) cat "$(scenario_path "${2:?scenario name required}")" ;;
  run)
    dry=false
    [ "${3:-}" = "--dry-run" ] && dry=true
    run_scenario "$(scenario_path "${2:?scenario name required}")" "$dry"
    ;;
  selftest) selftest ;;
  ''|help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
