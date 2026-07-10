# Design decisions (queue / craft-gate / mode policy)

Why this file exists: on 2026-07-07 the auto failure policy was revised five times
in one afternoon (`70e737d..4cdf3eb`), each commit a bare subject line. The end
state was right, but the *reasoning* lived nowhere — the next session (either
agent) could not tell settled policy from leftover scar tissue, and the stale
mid-series wording survived in comments and docs. This file is where policy
rationale lands so it stops being rediscovered.

**The rule** (also in `docs/COLLABORATION.md`): any change to craft-gating,
queue admission, failure handling, or mode/soak lifecycle ships with its
reasoning — a real commit body (root cause + chosen policy) or an entry here.
Five undocumented revisions of one policy is the failure mode this prevents.

Format per entry: what was happening, the policy chosen, where it is enforced,
and what gates it.

---

## 1. Auto-mode failure policy (settled 2026-07-07, backfilled)

**What was happening.** Live auto mode had two runaway modes: `autoApprove`
admitted every planner deficit at once (a big base floods the queue in one
cycle), and failed rows auto-retried after cooldown (a persistent failure —
missing pattern, missing inputs — re-fired forever, burning bridge calls and
filling the audit with noise). The 2026-07-07 series iterated through fail-stop
→ hold-everything → bounded admission → per-row quarantine before settling.

**Policy.**
- **Failed rows quarantine individually.** The runner always gets
  `holdFailed = true`: a row with an error never re-fires until an operator (or
  a manual retry path) explicitly retries or clears it — in every mode.
- **Admission is bounded.** `autoApprove` gets `maxNew = maxQueued =
  stockKeeper.maxCraftsPerCycle`: auto keeps at most a runnable backlog of that
  size, not the whole deficit list.
- **Failed rows do not consume runnable capacity.** The `maxQueued` count
  excludes rows with errors, so one quarantined failure cannot starve healthy
  work out of the bounded slots. (The mid-series revision that held *all* work
  on any failure was rejected as the always-on behavior — it froze unrelated
  quotas — and became the soak-only knob below.)
- **Hold-everything is reserved for unattended windows.** The runner's
  `holdWhenAnyFailed` knob halts every non-manual row while any failure exists.
  It is armed only during an agent soak (entry 2), where the goal is to prove
  trustworthiness, not to maximize throughput.

**Enforced in** `lib/atm10-craftrunner.lua` (`holdFailed`,
`holdWhenAnyFailed`), `lib/atm10-queue.lua` (`autoApprove` opts,
`failureCount`), manager `autoApprovePlans` + `processCraftQueue` deps.

**Gated by** sim scenarios `auto-admission-bounded`,
`auto-quarantines-failed-row`; smoke `AUTO-FAILSTOP-1`; `tests/run.lua` runner
unit tests.

## 2. Agent-driven bounded auto soak (2026-07-08)

**What was happening.** Auto mode could only be proven live with Zach as the
actuator (toggle auto on, watch, toggle it back), so every verification pass
cost a human round-trip — and production became the discovery mechanism for
failure modes (see the 2026-07-07 series). The simulator + soak scenarios now
discover; a bounded live soak confirms.

**Policy.** An agent asks a LIVE manager for a bounded unattended-auto window
over the file channel; the manager owns the entire lifecycle and always returns
to manual by itself.
- **Channel:** agent writes `.atm10-soak-request`
  (`{requestedAt, durationMs?, maxPerCycle?}`, manager-clock ms — use
  `tools/atm10-iterate.sh soak`). Manager replies via `.atm10-status` (`soak`
  block) and `.atm10-soak-report` (end **or** rejection, with the reason).
- **Start gates:** request fresh (60s TTL), base mode `manual`, no drain in
  progress, bridge not degraded, no failed rows in the queue. A soak is an
  excursion from a safe manual base — never a way to re-arm a misbehaving auto
  base. Boot deletes pre-boot request files (unknown age/intent).
- **Bounds:** duration clamped to 30s..15m (default 5m); `maxPerCycle` may only
  tighten the config cap, never widen it.
- **Fail-stop:** the runner runs with `holdWhenAnyFailed = true` — the first
  failed row anywhere halts all quota fire that same cycle, and the soak
  formally ends next cycle with reason `queue failure`.
- **Always reverts to manual.** End paths: first failure, operator mode change
  (tapping the mode chip kills it), deadline, manager restart (boot finds
  leftover `.atm10-soakstate`, reports `manager restart`, stays manual). The
  soak never touches the persisted mode override, so there is nothing to undo.

**Enforced in** `lib/atm10-control.lua` (`soakSpec`, `soakEndReason`), manager
(`ui.processSoak`, `effectiveMode`, boot cleanup, runner deps).

**Gated by** sim scenarios `soak-request-bounded-window`,
`soak-fail-stop-reverts`, `soak-restart-stays-manual`; `tests/run.lua` soak
unit tests. Live driver: `tools/atm10-iterate.sh soak [durationSec]
[maxPerCycle]`.

## 3. Late-progress reconcile: order-independent failure recovery (2026-07-08)

**What was happening.** AP (0.7.61b) reports "craft failed" for jobs whose
items land seconds LATER (verified live: job 1092 "failed" then delivered +36).
When the delivery beat the failure event, `progressJobId` absorbed it; when it
arrived after, `failJobId` had already latched the error and cleared the jobId,
so nothing could ever reconcile the row — it stayed quarantined until a human
retried, and any running soak fail-stopped on a craft that actually worked.
Arrival order changed the outcome; policy said it shouldn't.

**Policy.** Progress clears a failure regardless of arrival order, with the
same one-batch ambiguity AP-EVENT-3 already accepts:
- `failJobId` freezes a **failure-time snapshot** (`failedRequest` = the batch,
  `failedAmount` = stock at failure). Deliberately separate from `e.amount`:
  auto-mode's plan refresh overwrites `e.amount` every scan and would hide the
  late gain.
- Each scan, `reconcileFailedRows` credits stock gained since the snapshot,
  **capped at the failed batch**, clearing the error/backoff and reducing the
  request. Unrelated inflow can thus unlatch a row by at most one batch — a
  genuinely broken row re-fails on its next fire and re-latches.
- Snapshots expire after 10 minutes (a delivery that late is indistinguishable
  from normal production); expiry keeps the quarantine, only stops watching.
- A new fire (`markCrafting`) or an in-window progress credit invalidates any
  older snapshot, so one delivery can never be credited twice.
- Soaks stay strictly fail-stop: a bogus failure whose delivery lands after the
  soak's next end-check still ends the soak (correctly conservative); the row
  then self-clears so the NEXT soak isn't blocked.

**Enforced in** `lib/atm10-queue.lua` (`failJobId`, `markCrafting`,
`applyStockProgress`, `reconcileFailedRows`), manager (`handleCraftEvent`,
`pollCraftJobCompletion`, the scan reconcile block, audit kind
`late_progress`).

**Gated by** sim scenario `late-progress-clears-failed-row` (written first,
red against the pre-fix code); `tests/run.lua` reconcile unit tests.

## 4. Script-controlled production lines (2026-07-09)

**What was happening.** High-drain commodity metals (aluminum first: starved
to zero twice in two days) don't fit on-demand RS crafting — 32-per-batch
through AP's flaky job layer can't outrun consumption, and a bare always-on
RS Exporter is ungoverned (Zach's catch: it would eat the 6.2M-dust reserve
that other recipes need). Zach's requirement, verbatim intent: *the script
controls things; he's happy to build hardware; it has to work.*

**Policy.** Two-tier dust→ingot architecture:
- **High-rate tier (continuous lines):** an RS Exporter (redstone mode
  active-with-signal) feeds a smelter; the MANAGER decides on/off per line
  each scan — `control.lineDecision`: hysteresis (ON below `low`, off at
  `high`), a feedstock floor the line never draws below, and OFF on unreadable
  stock (never run blind). Decisions ride a compact `atm10-lines-v1` packet
  every scan; the larger viewer snapshot keeps `payload.lines` only for
  dashboards and is rate-limited. A tiny actuator computer (`atm10-line.lua`,
  one per machine bank, `--manager <id> <line>:<side>` args) validates the
  sender, manager source, session, sequence, and timestamp before it converts
  anything to redstone. It has a **dead-man switch**: manager silent >30s → all
  lines OFF. No AP, no patterns, no craftItem anywhere in the loop.
- **Low-rate tier (unchanged):** dust→ingot processing patterns in crafters
  that each SIT ON a smelter, batch-fired by quotas. AP's false-failure noise
  on this leg is absorbed by DECISIONS #3's reconcile.
- Lines are **earned by drain** (dashboard FALLING-BEHIND is the graduation
  signal), configured in `inventory-config` `lines = {...}` — thresholds live
  in config, not in block GUIs (RS device settings have no API; the script
  owns flow, the operator owns topology).

**Enforced in** `lib/atm10-control.lua` (`lineDecision`), manager broadcast +
status blocks, `atm10-line.lua` actuator, `inventory-config-example.lua`.

**Gated by** `tests/run.lua` line-decision/packet unit tests (hysteresis,
floor, blind-stock, replay, sender, session) + compile check of the actuator.
