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
EOF
chmod +x "$TMP/bin/ssh"

run_diag() {
  PATH="$TMP/bin:$PATH" \
  FAKE_SSH_LOG="$TMP/ssh.log" \
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
FAKE_SCREEN_READY=0 run_diag chat "status check" >"$TMP/ready.out"
grep -q 'Injected private chat for Zoozorocks via atm10-test' "$TMP/ready.out"
grep -q -- 'screen -ls' "$TMP/ssh.log"
grep -q -- '-X stuff' "$TMP/ssh.log"
grep -q 'tell Zoozorocks \[Claude\] status check' "$TMP/ssh.log"

echo 'SMOKE-DIAGNOSTICS OK'
