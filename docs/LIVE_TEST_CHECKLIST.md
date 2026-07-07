# Live Test Checklist

Use this for the next computer 6 in-game pass after GitHub `main` is updated.
This checklist is intentionally short and ordered so the first failure tells us
where to stop.

## Baseline Before Touching Computer 6

From this repo:

```bash
tools/atm10-live-pass.sh preflight
```

Expected before deploy:

- Server is reachable and port `25566` is listening.
- Doctor reports the resolved registry host, usually from
  `~/Projects/personal/mc-server-ops/active-server.json`.
- Manager heartbeat is fresh.
- Doctor may warn that deployed ComputerCraft files differ from repo.
- `.atm10-status` may be missing until the status-summary build is deployed.
- The wrapper writes a timestamped evidence folder under `/tmp/atm10-live-pass`.

## Start Capture

For one bounded in-game action, ask Zach through K2 feedback:

```bash
tools/atm10-live-pass.sh ask-action \
  "ATM10 action needed: <specific step>" \
  "<exact in-game action, stop condition, and what Codex will observe>"
```

Then observe for a short, bounded window:

```bash
tools/atm10-live-pass.sh observe 120
```

For the first bounded auto-mode proof, keep the same safety boundary but use the
named wrapper:

```bash
tools/atm10-live-pass.sh auto-soak-request 300
```

After Zach confirms auto is on at computer 6:

```bash
tools/atm10-live-pass.sh auto-soak-observe 300
```

After Zach confirms the mode is back to manual, run:

```bash
tools/atm10-iterate.sh status
```

If the post-soak status reports `QUEUE_WARN`, keep the manager in manual. Failed
rows should be inspected, retried one at a time, or cleared by an operator; auto
should not keep adding new approvals while failures are present.

For longer play-test capture, `tools/atm10-diagnostics.sh watch-log` is still
available and writes timestamped snapshots under `/tmp/atm10-diagnostics`.

Also keep a log baseline for ComputerCraft Java task errors:

```bash
tools/atm10-live-pass.sh npe-count
```

The live-pass wrapper also stores a before/after count, which is the normal
first check. Use the raw grep only when the count changes or a line number is
needed, and use the `host` and `serverDir` printed by `doctor` for that command.

## Deploy On Computer 6

Run these in the ComputerCraft terminal for computer 6:

```lua
update
atm10-reload
```

Do not use plain `reboot` or `computercraft shutdown` for the RS bridge manager.

## Immediate Post-Reload Checks

From this repo:

```bash
tools/atm10-diagnostics.sh doctor
tools/atm10-diagnostics.sh snapshot
```

Expected after deploy:

- Doctor reports matching repo hashes for the files just deployed.
- `.atm10-status` exists and is fresh.
- Manager heartbeat stays fresh after reload.
- Queue has no local `CRAFTING` row unless `activeCraftCount` is also nonzero.
- `atm10-patterns` is deployed and current.

## Pattern Worklist

On computer 6, run:

```lua
atm10-patterns
```

Then from this repo run another snapshot and inspect:

- `.atm10-patterns-needed.txt`
- `.atm10-pattern-ids.txt`
- `.atm10-pattern-unknown-ids.txt` if present

Expected:

- Unknown IDs are separated from missing-pattern IDs.
- Machine/manual routes are visible but excluded from RS pattern targets.

## Queue Decision

Current pre-deploy state has failed queue entries plus a local stale crafting row.
Do not clear the queue before reload; reload first and let the newer queue/task
reconciliation run.

After reload:

1. If stale local `CRAFTING` rows disappear, leave the queue alone for one scan.
2. Do not retry rows with `MISSING_ITEMS`.
3. Do not retry rows blocked by compression-pair or machine-route reasons.
4. Only retry a single failed row after the snapshot proves `activeCraftCount=0`
   and the item is a known simple craft path.
5. If the same row fails again, stop and inspect that item instead of pressing
   retry repeatedly.

Known recent successful craft evidence before deploy:

- `alltheores:osmium_ingot` succeeded recently.
- `alltheores:uranium_ingot` succeeded recently.

Tin has mixed recent evidence, so do not use it as the first proof path. Use one
of the successful rows above only after the reload checks are clean.

## Pass Criteria

The live pass is good enough when:

- `doctor` is `OK` or only has non-deploy warnings.
- `.atm10-status` is present and fresh.
- No new ComputerCraft `NullPointerException` lines appear during the post-reload
  observation window.
- Pattern output separates unknown IDs from missing patterns.
- Queue state does not show stale local crafting without an RS active task.
- One known small craft path starts and resolves without server log errors.
