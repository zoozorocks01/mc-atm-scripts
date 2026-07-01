# Operator Mode

Goal: Zach plays Minecraft; Codex handles server-side observation, diagnosis,
repo work, tests, commits, and publish prep.

## Default Split

Codex owns:

- Watching ComputerCraft state files over SSH.
- Reading heartbeat, loop pace, craft state, queue, craft results, and bridge
  probe output.
- Implementing fixes in the repo.
- Running the full Lua test and smoke gate.
- Committing local changes.
- Preparing the exact update/startup steps for the in-game computer.

Zach is only needed for:

- In-game monitor taps and item/craft observations.
- ComputerCraft console commands on computer 6 when deployment or live-only
  verification is needed.
- Explicit approval before pushes, publishing, destructive actions, or server
  stops.

## Codex Diagnostic Command

From the repo root:

```bash
tools/atm10-diagnostics.sh doctor
```

Use `doctor` as the first readiness check. It is read-only and reports a simple
`OK` / `WARN` / `FAIL` verdict for server reachability, manager heartbeat,
craft/queue state, recent crash reports, and deployed-file drift.

For the full evidence dump:

```bash
tools/atm10-diagnostics.sh snapshot
```

For live monitoring while Zach plays:

```bash
tools/atm10-diagnostics.sh watch
```

For a timestamped evidence file:

```bash
tools/atm10-diagnostics.sh save
```

For a play-test log that keeps one snapshot every interval:

```bash
tools/atm10-diagnostics.sh watch-log
```

The command reads the live computer 6 directory on `zjn-home-two` and reports:

- script file versions
- `.atm10-heartbeat`
- `.atm10-loopstate`
- `.atm10-craftstate`
- `.atm10-planstate`
- `.atm10-craft-results`
- compact craft queue fields
- latest `.atm10-bridge-probe.txt`

Override host/path only if the server moves:

```bash
ATM10_HOST=zjn-home-two \
ATM10_COMPUTER_DIR="/path/to/computercraft/computer/6" \
tools/atm10-diagnostics.sh snapshot
```

## Live Work Loop

1. Codex starts `tools/atm10-diagnostics.sh watch-log`.
2. Zach plays normally.
3. Codex asks only for specific in-game actions when live evidence is needed.
4. Codex patches/tests/commits fixes locally.
5. Zach approves push.
6. Zach runs the short deploy command set on computer 6.

Preferred deploy command set:

```lua
update
safereboot
startup
```

Use `safereboot` before stopping/restarting the manager when autocrafting may have
recently fired.

Host-side console commands:

- `tools/atm10-diagnostics.sh cc-dump 6` is read-only and safe.
- `tools/atm10-diagnostics.sh cc-turn-on 6` is safe only when the computer is off.
- `tools/atm10-diagnostics.sh cc-restart 6` is intentionally disabled; never hard
  shutdown/restart the running RS-bridge manager from the server console.
