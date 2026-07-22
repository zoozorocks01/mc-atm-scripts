#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote="${!#}"
printf '%s\n' "$remote" >> "$FAKE_SSH_LOG"
if [[ "$remote" == *"screen -ls"* ]]; then
  exit "${FAKE_SCREEN_READY:-0}"
fi
if [[ "$remote" == *"wc -c < logs/latest.log"* ]]; then
  echo 0
  exit 0
fi
if [[ "$remote" == *"-X stuff"* ]]; then
  : > "$FAKE_CHAT_LOG"
  if [[ "${FAKE_CHAT_ACCEPTED:-0}" == 1 ]]; then
    printf '%s\n' "$remote" > "$FAKE_CHAT_LOG"
  fi
  exit 0
fi
if [[ "$remote" == *"tail -c +1 logs/latest.log"* ]]; then
  grep -Fq -- "[Claude] status check" "$FAKE_CHAT_LOG"
  exit
fi
EOF
chmod +x "$TMP/bin/ssh"

run_diag() {
  PATH="$TMP/bin:$PATH" \
  FAKE_SSH_LOG="$TMP/ssh.log" \
  FAKE_CHAT_LOG="$TMP/chat.log" \
  ATM10_SERVER_OPS_DIR="$TMP/no-server-ops" \
  ATM10_SERVER_REGISTRY="$TMP/no-registry.json" \
  ATM10_HOST="fake-host" \
  ATM10_SERVER_DIR="/fake/server" \
  ATM10_SCREEN_SESSION="atm10-test" \
  "$ROOT/tools/atm10-diagnostics.sh" "$@"
}

if FAKE_SCREEN_READY=1 run_diag chat "status check" >"$TMP/refused.out" 2>&1; then
  echo "expected chat to refuse an unreachable screen control socket" >&2
  exit 1
fi
grep -q 'No reachable screen control socket' "$TMP/refused.out"
if grep -q -- '-X stuff' "$TMP/ssh.log"; then
  echo "chat injected despite an unreachable control socket" >&2
  exit 1
fi

: > "$TMP/ssh.log"
FAKE_SCREEN_READY=0 FAKE_CHAT_ACCEPTED=1 run_diag chat "status check" >"$TMP/ready.out"
grep -q 'Whispered private chat for Zoozorocks via atm10-test; accepted in current server log' "$TMP/ready.out"
grep -q -- 'screen -ls' "$TMP/ssh.log"
grep -q -- '-X stuff' "$TMP/ssh.log"
grep -q 'tell Zoozorocks \[Claude\] status check' "$TMP/ssh.log"

: > "$TMP/ssh.log"
if FAKE_SCREEN_READY=0 FAKE_CHAT_ACCEPTED=0 run_diag chat "status check" >"$TMP/unconfirmed.out" 2>&1; then
  echo "expected chat to fail closed without a current-log acceptance" >&2
  exit 1
fi
grep -q 'refusing Whispered status' "$TMP/unconfirmed.out"
if grep -q 'Whispered private chat' "$TMP/unconfirmed.out"; then
  echo "chat claimed a whisper without current-log acceptance" >&2
  exit 1
fi

: > "$TMP/ssh.log"
long_message="$(head -c 248 /dev/zero | tr '\0' x)"
if FAKE_SCREEN_READY=0 FAKE_CHAT_ACCEPTED=1 run_diag chat "$long_message" >"$TMP/too-long.out" 2>&1; then
  echo "expected over-limit chat to be rejected" >&2
  exit 1
fi
grep -q 'chat message is 257 characters; Minecraft accepts at most 256' "$TMP/too-long.out"
if grep -q -- '-X stuff' "$TMP/ssh.log"; then
  echo "over-limit chat reached the console" >&2
  exit 1
fi

echo 'SMOKE-DIAGNOSTICS OK'
