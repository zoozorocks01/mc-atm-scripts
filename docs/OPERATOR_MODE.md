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

The live host is not hard-coded. The scripts read the active MC server registry
at `~/Projects/personal/mc-server-ops/active-server.json`, then use that host's
Tailscale address, server directory, and Minecraft port unless explicitly
overridden.

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

## Stable Live Pass Wrapper

For the normal stability loop, Codex should start with:

```bash
tools/atm10-live-pass.sh preflight
```

This wraps `doctor`, a snapshot, and a server-log `NullPointerException`
baseline into one timestamped folder under `/tmp/atm10-live-pass`. It is
read-only and does not start crafts, clear queues, flip auto mode, reboot
ComputerCraft, or write to the server.

When the only missing piece is a human in-game action, Codex pings Zach through
K2 feedback instead of burying the request in terminal output:

```bash
tools/atm10-live-pass.sh ask-action \
  "ATM10 action needed: approve one small craft" \
  "Please approve exactly one known simple craft on computer 6, then stop. Codex will observe the live files and server log."
```

Then Codex observes the result:

```bash
tools/atm10-live-pass.sh observe 120
```

The wrapper is deliberately narrower than a control system. Direct command
mailboxes and broader automation should wait until this stability loop is
boring and repeatable.

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

The command reads the resolved live computer 6 directory and reports:

- script file versions
- `.atm10-heartbeat`
- `.atm10-status`
- `.atm10-loopstate`
- `.atm10-craftstate`
- `.atm10-planstate`
- `.atm10-craft-results`
- compact craft queue fields
- latest `.atm10-bridge-probe.txt`

Override host/path only if the registry needs to be bypassed. To select a
registered host, prefer the host id:

```bash
ATM10_HOST_ID=zjn-home-two tools/atm10-diagnostics.sh snapshot
```

For an unregistered target, override host and paths together:

```bash
ATM10_HOST=example-host \
ATM10_SERVER_DIR="/path/to/ATM10-server" \
ATM10_COMPUTER_DIR="/path/to/computercraft/computer/6" \
tools/atm10-diagnostics.sh doctor
```

## Live Work Loop

1. Codex runs `tools/atm10-live-pass.sh preflight`.
2. If preflight is not green, stop and fix that specific evidence first.
3. Codex uses `tools/atm10-live-pass.sh ask-action ...` only for specific
   in-game actions.
4. Codex runs `tools/atm10-live-pass.sh observe 120` while Zach performs that
   one action.
5. Codex patches/tests/commits fixes locally only when the evidence points to a
   repo bug.
6. Zach approves push.
7. Zach runs the short deploy command set on computer 6.

Preferred deploy command set:

```lua
update
atm10-reload
```

Use `atm10-reload` for normal manager deploys. It asks the running manager to
drain, clears cached `atm10-*` modules, and restarts through the watchdog wrapper
without detaching the bridge. Use `safereboot` only when the computer itself must
restart.

Bootstrap caveat: the first live deploy onto a manager that predates
`atm10-reload` may need the old safe stop path once. After the reload-capable
manager is running, use `update` -> `atm10-reload`.

Aborting `safereboot`/`atm10-reload` mid-drain (Ctrl+T) is safe: the drain flag
stops being renewed and the manager resumes crafting within about a minute (the
dashboard shows a `[DRAINING]` chip while a drain is live). A stale reload flag
is ignored and deleted by the startup wrapper, so an aborted reload can never
make the wrapper exit on a later, unrelated program stop.

Host-side console commands:

- `tools/atm10-diagnostics.sh cc-dump 6` is read-only and safe.
- `tools/atm10-diagnostics.sh cc-turn-on 6` is safe only when the computer is off.
- `tools/atm10-diagnostics.sh cc-restart 6` is intentionally disabled; never hard
  shutdown/restart the running RS-bridge manager from the server console.
