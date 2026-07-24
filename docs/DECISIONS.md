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

## 5. Same-output pattern priority and block-unpacking fallback (2026-07-10)

**What was happening.** Block→ingot patterns shared outputs with dust→ingot
processing patterns and, for some metals, essence→ingot crafting patterns. With
those routes installed without an explicit ordering, RS could choose an
undesired source path; the block-unpacking patterns were removed live because
they were interfering with normal ingot production.

**Policy.** Keep block→ingot available, but only as an isolated last-resort
route:

- Put all block→ingot patterns in one dedicated fallback Autocrafter. Do not
  mix them back into the preferred dust/essence banks.
- Give every pattern that produces the same ingot an explicit priority ladder.
  Start with dust→ingot at `20`, an intentionally approved secondary route
  (for example essence→ingot) at `10`, and block→ingot fallback at `0`.
- The exact numbers are not meaningful; their ordering is. Any new same-output
  route must be placed deliberately in this ladder rather than inheriting an
  equal/default priority.
- Keep the manager's compression-pair guard. Autocrafter priority selects the
  RS recipe; it does not authorize ingot↔block quota thrash.

**Control boundary.** The installed Advanced Peripherals RS bridge accepts an
output request (`craftItem({name, count})`), but exposes no supported
selected-pattern or selected-route argument. Route selection therefore belongs
to the physical Autocrafter priority ladder, not to the manager after it has
requested an ingot.

This matches Refined Storage 2's documented behavior: the highest-priority
pattern for a shared output is tried first, and lower-priority patterns are
checked when higher-priority routes lack resources.

**Live acceptance (pending; operator action).** With a preferred route's inputs
available, one ingot request must show that route/machine in the Autocrafting
Monitor. With those inputs intentionally unavailable and a source block in
storage, one bounded request must fall through to the dedicated block bank.
No bulk retry sweep is part of this test.

**Reference.** Refined Storage 2 feature overview:
<https://refinedmods.com/refined-storage/news/20250308-whats-new-in-refined-storage-2.html>.

## 6. Drain-aware craft batch sizing for high-drain metals (2026-07-23)

**What was happening.** A fixed per-turn batch cap starved high-drain metals.
Live (production, 2026-07-22): gold sat at 18,776 of a 100,000 target while the
planner requested only 4,096/turn. 19 items below target shared ONE serial
crafting lane at ~3 crafts/min (a deliberate guard against an RS 2.0.6
concurrent-task deadlock), and a Dyson-swarm crafting chain drained gold faster
than 4,096/turn. Each turn's request was smaller than what got consumed before
the next turn, so the deficit never closed no matter how long the lane ran. The
consumption signal was already measured — the FALLING-BEHIND dashboard
(`monitor.demand`) has shown gold declining for days — but the planner ignored
it when sizing a request.

**Policy.** One turn's request may scale with MEASURED drain, up to an explicit
per-item or global ceiling. Nothing else about the pipeline changes.
- **Base cap unchanged.** The per-turn request still defaults to `maxRequest`
  (4,096 when unset). With no measured drain and no `maxBatch` configured, sizing
  is byte-identical to before — the feature is strictly opt-in.
- **Drain-aware ceiling (`maxBatch`).** When a sustained drain is measured for an
  item AND a `maxBatch` greater than `maxRequest` is configured (per-item, else
  the global `stockKeeper.maxBatch`), the planner raises THIS turn's cap to
  `maxRequest + floor(perMin * cooldownMinutes)` — cover the consumption expected
  before the item can be re-requested (~one cooldown) plus one base batch of
  headway — bounded by `maxBatch`. So one turn now outpaces the drain and the
  deficit shrinks instead of treading water.
- **Same drain signal as the dashboard.** "Sustained drain" is
  `monitor.drainRate` (factored out of `monitor.demand`): net decline over a
  window ≥10 min, ≥4 samples, ≥20/min, with the transient-spike guard. Below that
  floor, 4,096/turn already keeps pace, so no scaling. The persisted trend window
  is loaded BEFORE planning so a rebooted manager sizes correctly on its first
  scan.
- **Bounds preserved.** The request never exceeds the deficit (`craftTo`
  ceilings hold), the `craftFrom` input reserve still clamps it afterward,
  oresight-reserve semantics for raw allthemodium/vibranium/unobtainium are
  untouched, quarantine/cooldown policy is unchanged, and the serial lane still
  fires one task at a time and yields to ALREADY CRAFTING. Only the ceiling on a
  single turn's ask changed — a larger single task, not more concurrent tasks.

**Enforced in** `lib/atm10-stockplan.lua` (`ctx.drain`, `maxBatch`, the
effective-cap block), `lib/atm10-monitor.lua` (`monitor.drainRate`), manager
`planStockActions` (builds the drain map from `trendHistory`),
`effectiveStockKeeper` + `loadConfig` (`maxBatch` plumbing), scan trend-load
ordering.

**Gated by** sim scenario `drain-aware-batch-sizing` (written first, red against
the pre-fix planner: gold fired 4,096 < the 7,074 consumed per cooldown; green
after: 11,170, which outpaces the drain and stays under `maxBatch`);
`tests/run.lua` stockplan drain-aware unit tests + `monitor.drainRate` tests.

**Rollout (operator action, Zach-gated).** The code ships the capability; it does
nothing until `maxBatch` is set. Set a global `stockKeeper.maxBatch` (or a
per-item `maxBatch`) above `maxRequest` to arm it for high-drain items, gold
first.

## 7. In-game chat bridge wired into the manager loop (2026-07-24)

**What was happening.** The pure `atm10-chatbridge` module (command grammar,
reply shaping, length-safe split, outbound spool drain, heartbeat->presence)
landed fully unit-tested but unwired: the 24/7 manager could not yet answer a
player in-game or relay an agent's message. The presence contract also wants an
honest in-world signal that a seat is actually listening, not an implicit claim.

**Policy.** Wire the module into the live loop behind an OFF-by-default flag so a
deploy is inert until an operator arms it.
- **Config flag.** `chatBridge = { enabled = false, players = {...} }`. Disabled
  by default; `players` is an optional allowlist (empty = anyone may command).
  Normalized fail-closed in `loadConfig` (bad/absent block => OFF, open list).
- **Peripheral fail-open.** The AP Chat Box is wrapped once at boot
  (`peripheral.find`/type "chatBox"). Wrapping is unconditional and harmless;
  USAGE is gated per-cycle on the flag (so enabling via config reload needs no
  re-detect). Enabled but no Box => log once, run normally. Never crashes the
  manager: every path is `pcall`/`call`-guarded and the module require is
  defensive.
- **Inbound.** The Chat Box fires a "chat" os event; the input coroutine parses
  it (`chatbridge.parse`, allowlist applied), answers from the SAME snapshot the
  dashboard renders (`chatbridge.reply` over `lastData`/queue/throughput), and
  sends each piece back to that player (`sendMessageToPlayer`, `sendMessage`
  fallback), each already <= `chatbridge.MAX_LEN`.
- **Outbound spool.** Each scan drains `.atm10-chat-outbox` (a Lua-serialized
  array of `{text, from}`, same file convention as every other agent channel --
  NOT JSON), rate-capped by `chatbridge.outbound`, rewriting the remainder
  (deleting when empty). Boot discards a leftover outbox (stale/unknown age),
  exactly like a pre-boot soak request.
- **Presence.** Each scan reads `.atm10-seat-heartbeat-<seat>` files (embedded ms
  else file mtime) and announces LIVE/offline transitions via
  `chatbridge.presence`, so a dead agent session can never keep an implicit
  presence claim alive.
- **200-local cap.** All state and functions hang off the existing `ui` table
  (`ui.chatBox`, `ui.chatMod`, `ui.chatPresence`, `ui.serviceChatBridge`,
  `ui.handleChatEvent`, ...); no new top-level locals in the manager.

**Enforced in** `inventory/manager.lua` (`ui.chatbridge`/`chatSayTo`/`chatBroadcast`/
`chatReadSeats`/`chatState`/`handleChatEvent`/`serviceChatBridge`, boot detection +
outbox cleanup, scan-loop service call, input-loop "chat" dispatch, `DEFAULT_CONFIG`
+ `normalizeConfig` `chatBridge`, `FILES.chatOutbox`/`seatHeartbeatPrefix`),
`lib/atm10-chatbridge.lua` (pure module, merged from `fable/chatbridge-proof`).

**Gated by** sim scenario `chatbridge-relay` (fake AP Chat Box + a real "chat" os
event through the manager's input loop: an allowed player's `!stock` gets a
snapshot reply, the agent outbound spool drains and its file is deleted, and a
non-allowlisted player's command is dropped); plus the module's `tests/run.lua`
unit tests.

**Rollout (operator action, Zach-gated).** Attach an AP Chat Box to the manager
computer and set `chatBridge.enabled = true` (optionally an allowlist). Agents
relay by appending `{text, from}` rows to `.atm10-chat-outbox`.
