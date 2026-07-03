# Next Improvements — ranked backlog (touch / perf / UI / reliability)

A ranked backlog of every touchscreen, performance, UI, and reliability finding from
the recon pass. Ranked by **value ÷ risk/effort**, reliability ahead of polish (per
the operator's stated priority order: reliability → control → autocraft-truth →
viewer → polish).

> **Line numbers are from the recon snapshot.** The repo has since advanced
> (HEAD `e4bdcba`); `inventory-info.lua` is at **186** top-level locals (over the 185
> soft cap) — any new manager state MUST go into an existing table, never a bare
> top-level local. CC's Cobalt counts stricter than Lua 5.4, so a green gate is NOT
> proof CC accepts it. Verify each line:area against current code before editing.

## Legend

- **Verify:** `gate` = fully provable on `tests/run.lua` + smokes (ship unattended) ·
  `visual` = needs a live monitor/bridge (`in-game-verify: pending`, not done until
  verified in-world).
- **Phase:** `Code` = the Code phase will attempt · `discuss` = pinned as
  major-for-discussion (too large/risky to fire unattended).
- Size · Value · Risk as reported by recon.

---

## Session log — 2026-07-03 (UNKNOWN-ID split + pattern unknown bucket local)

Quota ID validation now distinguishes `UNKNOWN-ID` from `NOT CRAFTABLE`. The
manager threads live-grid presence into stock/overflow planning, renders unknown
IDs separately in PLAN category/tally rows, and includes `unknownIdCount` in the
compact plan diagnostics. `atm10-patterns` now reads the live item grid, excludes
unknown/not-in-grid IDs from pattern-build lists, and writes
`.atm10-pattern-unknown-ids.txt` alongside the existing flat/bucketed pattern
lists. Dismissed smart suggestions are pruned at load/save boundaries, not only
at call sites.

- **Gate:** 912 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PATTERNS OK;
  SMOKE-RELOAD OK; SMOKE-SAFEREBOOT OK; SMOKE-REMOTE OK; SMOKE-REQUEST OK;
  SMOKE-PROBE OK; SMOKE-BRIDGE-PROBE OK; diagnostics shell parse clean; mirror
  diffs empty; git diff --check clean.
- **in-game-verify: pending** — after the next deploy, run `atm10-patterns` on
  computer `6` and inspect `.atm10-pattern-unknown-ids.txt`; PLAN should show
  `UNKNOWN-ID` rows for quotas absent from the live RS item grid instead of
  folding them into `NOT CRAFTABLE`.

## Session log — 2026-06-30 (stale CRAFTING recovery + craft metrics local)

Live monitoring caught a real control-truth bug: `craftItem` could return success
and move a row to `CRAFTING`, while RS reported zero active tasks. If stock did not
recover, that row stayed stuck forever. The queue now marks stale inactive
`CRAFTING` rows back to `APPROVED` with a retryable `no active RS task` error after
a grace period. `.atm10-craftstate` also now persists operational metrics for
server-side monitoring: active task source/count, queue approved/crafting/failed/
stale counts, queue depth, would-craft backlog count/amount, and crafts/min.

- **Gate:** 813 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; SMOKE-REMOTE OK; SMOKE-BRIDGE-PROBE OK; git diff --check clean.
- **in-game-verify: pending** — update computer `6`, let the manager loop run for
  one cycle, then confirm stale `CRAFTING` rows report as retryable and craftstate
  includes the new metric fields.

## Session log — 2026-06-30 (Pattern bucketed setup lists local)

Pattern/setup workflow improved locally. `atm10-patterns` still writes the flat
`.atm10-pattern-ids.txt`, but now also writes bucketed setup lists for the three
different next actions: `.atm10-pattern-crafting-ids.txt` for safe crafting-grid
patterns that can use the `/give` emitter, `.atm10-pattern-processing-ids.txt` for
machine/processing patterns that need a captured reference, and
`.atm10-pattern-manual-ids.txt` for recipe checks that need manual handling.

- **Gate:** 807 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; SMOKE-REMOTE OK; SMOKE-BRIDGE-PROBE OK; pattern-give mirror
  diff empty; git diff --check clean.
- **in-game-verify: pending** — after publishing, run `atm10-patterns` on computer
  `6` and inspect the flat plus bucketed ID files.

## Session log — 2026-06-30 (CRAFT-2 active task snapshot local)

Control-truth groundwork is local. `atm10-control` now normalizes the live
Advanced Peripherals craft-task rows into an active craft snapshot keyed by
registry name, including `bridge_id`, `resource.name`, `crafted`, `quantity`, and
percent progress. The manager caches that snapshot for the existing crafting TTL,
uses it before falling back to per-item craft checks, threads it into the scan
payload, and shows live task progress in the Queue page's result column when a
queued item is present in RS's active task list.

- **Gate:** 804 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; SMOKE-REMOTE OK; SMOKE-BRIDGE-PROBE OK; manager/control mirror
  diffs empty; git diff --check clean.
- **in-game-verify: pending** — after publishing, run/update the manager, start a
  visible RS craft from the queue, and confirm the Queue row shows active progress.

## Session log — 2026-06-30 (CRAFT-1 bridge probe hardening local)

CRAFT-1 probe hardening is ready for live use. `atm10-bridge-probe` now records
bounded raw samples for task-list methods, retries `getCraftingTask` with sampled
task IDs/names when available, probes `isItemCrafting` / `isCrafting` with table,
table+count, and string argument forms, and includes queued item names from the
manager queue as extra probe candidates. The first live active-craft report from
computer `6` showed Advanced Peripherals task rows shaped as `bridge_id` +
`resource`, so the local probe now retries that numeric ID and probes the task
resource name too. A new off-CC smoke runs the bridge probe against a fake RS
Bridge and verifies the report is written.

- **Gate:** 798 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; SMOKE-REMOTE OK; SMOKE-BRIDGE-PROBE OK; git diff --check clean.
- **in-game-verify: pending** — run `atm10-bridge-probe` once idle and once while
  RS is actively crafting, then inspect/share `.atm10-bridge-probe.txt`.

## Session log — 2026-06-30 (Viewer filter/detail shipped)

Read-only viewer filter/detail shipped. The inventory viewer now has keyboard-free
filter chips (`ALL`, alpha ranges, `DUST`, `ESS`), filters a copied snapshot before
sorting, and lets a row tap open a read-only item detail card with registry ID,
count, and trend when present. The existing paging/sort controls remain read-only;
the new smoke proves the viewer sends no rednet control messages.

- **Gate:** 798 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; SMOKE-REMOTE OK; remote mirror diff empty; `git diff --check`
  clean.
- **in-game-verify: pending** — off-CC smoke covers the touch paths; live viewer
  monitor spacing/readability still needs a look.

## Session log — 2026-06-30 (Pattern checklist hints shipped)

Pattern checklist groundwork shipped. `atm10-patterns` now writes an IDs-only copy
list to `.atm10-pattern-ids.txt` alongside the full worklist, and each needed row
gets a next-step hint from the pattern helper. The `/give` emitter now classifies
crafting-grid derivations separately from processing-pattern blockers and refuses
to emit commands for alloy/circuit outputs even when their names end in `_ingot`.
Processing patterns still require a captured in-world reference; no guessed NBT was
introduced.

- **Gate:** 798 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; pattern-give mirror diff empty; `git diff --check` clean.
- **in-game-verify: pending** — run `atm10-patterns` on the manager computer and
  inspect both `.atm10-patterns-needed.txt` and `.atm10-pattern-ids.txt`.

## Session log — 2026-06-30 (Queue retry UX shipped)

Queue retry UX shipped. Failed approvals now show a retry countdown in the Queue
page's `LAST/RTY` column, the page summary counts failed entries, and the footer
renders `[RETRY FAILED]` when any approval is waiting on failed-craft backoff. That
button clears only the local error/backoff timestamps so the gated runner can try
again on its next pass; it does not craft directly and row taps still cancel.

- **Gate:** 792 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; manager and queue mirror diffs empty; `git diff --check`
  clean.
- **in-game-verify: pending** — off-CC smoke covers failed-row rendering and retry
  tap persistence; live monitor spacing/readability still needs a look.

## Session log — 2026-06-30 (Request panel filter UX shipped)

Request-panel UX polish shipped. The craft request browser now renders preset
filter chips (`ALL`/`ZINC`/`IRON`/`DUST`/`ESS`) above the item list, applies the
existing case-insensitive `filterItems()` helper before sorting, and keeps the
source snapshot order untouched. Request-panel buttons now paint through the
active frame buffer instead of writing directly to the monitor during a buffered
render, so first-render controls cannot be overwritten by the diff buffer pass.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; request mirror diff empty; `git diff --check` clean.
- **in-game-verify: pending** — off-CC smoke proves the filter/submit path and
  buffered button rendering; live monitor spacing/readability still needs a look.

## Session log — 2026-06-30 (Browse sort controls shipped)

Browse sort/filter controls shipped. The BROWSE footer now has a `[QTY]` /
`[A-Z]` / `[MOD]` sort chip using the existing console sort helpers, while
ALL/MANAGED remains a separate toggle. Repeated renders of the same scan reuse the
sorted list until the source table or selected sort mode changes, and smoke now
covers real BROWSE tab entry plus sort cycling and empty MANAGED footer rendering.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK; mirror diff empty; `git diff --check` clean.
- **in-game-verify: pending** — off-CC smoke covers the touch path; Zach should
  verify the footer spacing and sort cycling on the live monitor.

## Session log — 2026-06-29 (Browse glitch fix shipped)

Browse glitch fix shipped after an in-world report. The smoke test was corrected to
tap the real BROWSE tab instead of HEALTH, then a regression covered the empty
MANAGED-filter state. `drawBrowsePage()` no longer returns before drawing the footer
toggle when the filtered list is empty, clips the footer hint to the monitor width,
and caches the sorted Browse list for repeated renders of the same scan.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: pending** — off-CC smoke now exercises Browse, but Zach should
  verify the live monitor no longer glitches when entering/toggling Browse.

## Session log — 2026-06-29 (QA/resilience sweep shipped)

Manager QA/resilience sweep shipped. The loop guard now only drops/reacquires the
monitor for display/peripheral-sensitive failures, while render failures are handled
inside `renderCurrent()` where the failing surface is known. Bridge storage/energy
stats now preserve prior per-field values when a throttled stat refresh returns nil,
so viewer panels do not blank from one partial read. State writes now serialize tables
inside `atomicWrite()`, keeping serialization failures inside the guarded best-effort
write path instead of leaking to the loop guard. Smoke coverage now bites all three
paths.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: n/a** — these are fail-safe control/display semantics covered by
  off-CC smoke tests; live observation is still useful for wording/readability.

## Session log — 2026-06-29 (scan error hold-last-good shipped)

Scan-loop resilience shipped. If `scan()` throws after a previous good frame, the
manager now keeps the last-good plan on screen, marks it stale with the scan error,
and feeds the failure into the bridge-degraded craft gate instead of dropping the
console to the WAITING / attach screen. A smoke regression forces a good scan followed
by a malformed item scan and checks that the stale banner remains visible.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: n/a** — fail-safe display behavior is smoke-covered off-CC; live
  bridge/peripheral wording can still be observed during the next in-world check.

## Session log — 2026-06-29 (C3 manager tap targets shipped)

Manager touch-target polish shipped. PLAN/BROWSE nav arrows, PLAN approve-all,
QUEUE clear-all, the header mode chip, and quota-editor action/step/plus-minus
controls now render as wider filled chips, with each hit region rebuilt from the
same painted width so taps match what the monitor shows. Mirror pair stayed
byte-identical.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: pending** — the render/hit geometry is stub/compile verified;
  physical monitor tap comfort and spacing still need an in-world look.

## Session log — 2026-06-29 (D2 + D5 viewer panels shipped)

Viewer polish shipped for the read-only inventory display. `draw.box` / `draw.gauge`
now support render-buffer targets, so the diff-buffered viewer can use the shared
panel primitives without bypassing `renderBuffer`. The VIEW profile now renders boxed
Storage and Energy panels with gauges, boxed WAITING / NO ITEMS / MONITOR TOO SMALL
states, and the old local one-off bar renderer was removed. Mirror pairs stayed
byte-identical.

- **Gate:** 777 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: pending** — this was render-stub/compile verified; real monitor
  spacing and readability still need an in-world look.

## Session log — 2026-06-29 (B2 scan-sort trim shipped)

Low-risk B2 code slice shipped. `scan()` no longer sorts the full RS item table every
refresh; it returns raw scan order, while Browse and viewer broadcasts request sorted
copies only when those surfaces need quantity ordering. Smart-mode trend snapshots were
already gated behind `smartMode`, so no further change was needed there. The larger
parallel/coroutine scan rewrite remains pinned for discussion.

- **Gate:** 780 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: n/a** — behavior-preserving sort placement change; no new visual
  layout or bridge call path.

## Session log — 2026-06-29 (E1 page-rotation pause shipped)

Small interaction polish shipped. The manager records the most recent monitor touch on
the existing `ui` state table, and auto-rotation now waits from the newer of page-shown
time or last-touch time. PLAN/QUEUE/HEALTH no longer rotate immediately after a tap.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: n/a** — pure timing change with unit coverage.

## Session log — 2026-06-29 (D4 viewer zebra rows shipped)

Viewer list polish shipped. The stored-items list now alternates row backgrounds via
the existing diff-buffer path, making dense item/amount rows easier to scan without
changing paging, sorting, nav buttons, or broadcast payloads.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: pending** — visual readability needs a real monitor look.

## Session log — 2026-06-29 (D1 power-display double buffer shipped)

Power display flicker polish shipped. `power/display.lua` now renders through the
shared diff-buffer path used by the viewer: line/bar/graph cells write into a frame
when active, then `renderBuffer` updates only changed rows/cells. The render-error
fallback resets the diff baseline after a manual clear so the next good frame redraws
fully. Mirror pair stayed byte-identical.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: pending** — graph framing/flicker needs a real monitor look.

## Session log — 2026-06-29 (B1 hardening + A3/D3 header chips shipped)

Manager header/render polish shipped. B1 was already present in code, but this pass
hardened the buffer-aware writer fallback (`mwrite` no longer recurses if called outside
an active frame), verified the manager mirror pair, and marked the B1 row as done. The
header now renders as a full-width title band with mode/autocraft chips on every page,
and the A3 craft-hold state surfaces as a visible `[BRIDGE HELD]` chip when degraded
bridge gating pauses craft firing.

- **Gate:** 784 passed / 0 failed; SMOKE OK; SMOKE-AUTO OK; SMOKE-PROBE OK;
  SMOKE-REQUEST OK.
- **in-game-verify: pending** — header spacing/color/readability needs a real monitor look.

## Session log — 2026-06-26 (A2 — request-panel program shipped)

New viewer-style touch program **inventory/request.lua** (+ root mirror +
request-startup wrapper + `inventory-request` role in atm10-update.lua). Browses
the snapshot's `viewItems`, taps to a detail screen, picks a quantity (step
buttons), and submits a one-shot **craft_request** over `atm10-control-v1`
(token-gated via `console.resolveControlToken`, A1's `args={count,force}` shape).
Live jobs strip reconciles against the broadcast `craftQueue` (matches by name),
lingers finished jobs, and offers CANCEL (sends a forward-compatible `craft_cancel`
— A1 ships only `craft_request`, so the manager default-denies it and the panel
surfaces that reply; no client no-op). New pure console helpers
(`filterItems`/`stepQuantity`/`quantityButtonRow`/`quantitySteps`/`jobRowFormat`/
`requestStatusLabel`/`resolveControlToken`) with biting unit tests; biting
load+submit smoke (`tests/smoke_request.lua`, SMOKE-REQUEST OK) proves the SUBMIT
touch emits exactly one craft_request with the right target/count/token.

- **Gate:** 722 passed / 0 failed (+41); SMOKE OK; SMOKE-AUTO OK; SMOKE-REQUEST OK;
  all four mirror pairs byte-identical.
- **in-game-verify: pending** — rendering + monitor_touch on a real panel, and the
  real manager round-trip (craft_request enqueues a job; CANCEL is denied until A1
  adds craft_cancel). Free-text search deferred (CC monitors have no soft keyboard;
  v1 ships sort + pagination only). The panel cannot pre-filter to craftable-only
  (isCraftable reads blind — CRAFT-3); it submits any item and surfaces the
  manager's no-recipe rejection as the job error.

---

## Session log — 2026-06-26 (reliability PASS 1 — 4 safe wins shipped)

Four pure-logic / genuine-resilience reliability wins, each its own commit, gate
green throughout (606 -> 610 passed), mirrors identical, manager locals unchanged
at 186 (state folded onto existing tables).

- **A3 bridge-degraded GATING wired (back-off) — SHIPPED** (`bb73312`). New pure
  `health.gateCrafts(state, ok, threshold)` (allowFire = not degraded) in
  `atm10-health.lua`. `scan()` feeds the single per-cycle bridge outcome (false on
  no-bridge / offline / stale, true on a clean read) and stashes `allowFire` on
  `craftingCache.__bridge` (reserved __-keys on a never-pairs()-iterated table → no
  new local). `refreshAndDraw` SKIPS `autoApprovePlans` + `processCraftQueue` while
  degraded — pausing the mutating `craftItem` at a half-attached bridge (the
  uncatchable AP `NotAttachedException` trigger). Auto-resumes on the first clean
  scan. `data.bridgeDegraded` is set but NOT rendered — the header **chip stays
  PINNED** (B1, in-game-visual). Biting test on `gateCrafts` (HOLD-at-threshold).
- **Thrown rednet.broadcast contained — SHIPPED** (`acd60da`). `broadcast()` built
  its payload inline then called `rednet.broadcast` raw, before `renderCurrent()`;
  a modem closed/removed mid-run threw into `guard()`, which nulled a healthy
  monitor and skipped the primary console's frame for a refresh interval. Payload
  now built outside a `pcall` that wraps only the send (genuine resilience for an
  optional outbound transport — payload-build bugs still throw). Biting smoke test:
  a throwing broadcast must still render PLAN; reverting the pcall fails it.
- **craftResults prune-on-load — SHIPPED** (`aa49927`). `loadCraftResults` now
  bounds via `cqueue.pruneResults` on load (was only pruned on the craft-fired
  path), matching the dismissed prune-on-load pattern. Biting test (300 → 150).
- **trendHistory prune-on-load — SHIPPED** (`358eb83`). `loadTrends` now bounds via
  `suggest.prune` on load (was only pruned in the throttled save block, never with
  smart mode off). Biting test (1000 → 800).

### Reliability PASS 1 — PINNED (not fired unattended)

- **Persistence: .tmp-orphan recovery on load** — `S · value high · risk MED-for-this-pass`.
  `atomicWrite` (`inventory-info.lua:316-330`) deletes the live file then moves tmp
  over it; on a move failure the new data lives ONLY in `path..'.tmp'`, and no
  loader checks for it — worse, the NEXT `atomicWrite` deletes the orphan (line 318)
  before writing, discarding the only surviving copy on a disk-full incident (the
  exact scenario that locked the disk once). The fix (copy `download()`'s self-heal
  at `atm10-update.lua:122-124` into a shared "read state file, recovering .tmp if
  the main file is missing" helper used by all 6 loaders) is the **largest-blast-radius**
  persistence change: it couples the write path (must NOT blindly delete a tmp that
  is the only copy) with all 6 read paths, and getting the recover-vs-discard
  ordering wrong could resurrect stale data over good. Not trivially gate-provable
  without a multi-file crash-simulation harness → **pinned for a careful, owned
  commit** rather than fired unattended this pass.
- **Scan-loop: scope guard()'s monitor-drop to render/peripheral faults only — SHIPPED** —
  `S · value med`. `guard()` (`inventory-info.lua:2237-2244`) nulls the monitor on
  ANY error class, so a logic/persistence fault needlessly drops a healthy monitor +
  forces a full palette/redraw. Refinement, not a crash hole (the loop already
  survives). Shipped with a redstone-handler smoke that proves a non-render handler
  failure does not force a monitor re-wrap.
- **Scan-loop: hold-last-good on a THROWN scan — SHIPPED** — `S · value med`. The pcall-failed
  branch (`2227-2229`) nulls `lastData` and drops to WAITING, unlike the `stale`
  branch which holds the last plan. A transient scan throw should hold last-good with
  a banner. Shipped as the smaller owned slice first; guard() monitor-drop scoping
  remains separate.
- **Scan-loop: per-field hold-last-good on bridgeStats — SHIPPED** — `S · value low`. The
  whole `bridgeStats` table is replaced each throttled refresh, so a transient nil
  blanks all six display stats. Shipped with a broadcast-payload smoke that proves
  storage/energy fields preserve their prior values on a partial nil refresh.
- **AP-window micro-shrinks (both already incidentally contained, low value)** —
  (a) craftrunner offline sentinel: have `requestCraft` return a distinguishable
  `'bridge offline'` so the runner STOPS the rest of the fire loop and leaves
  entries APPROVED not ERROR; (b) `isConnected` recheck at the top of
  `processCraftQueue`. Both are defense-in-depth on a path already contained by
  STAB-2 + the per-call recheck; low value, pinned.

---

## Session log — 2026-06-26 (round 3: two safe wins — C1 flash + A3 health helper)

- **C1 tap-flash ack on Smart / Presets / editor — SHIPPED** (`166a75c`). Reuses the
  existing `flashMsg`/`flashAt`/`FLASH_MS` mechanism proven on PLAN/QUEUE; sets the flash
  in `toggleSmart` / `applyPreset` / `saveEditing` / `removeEditing` and renders it on the
  Smart-page + Presets-page hint lines (editor save/remove flash shows on the PLAN/QUEUE
  page it returns to). Render-only, no hit-region change, no new locals (still 186).
  `in-game-verify: pending` (visual is in-world; mechanism is identical to PLAN/QUEUE).
- **A3 bridge-degraded counter — pure helper SHIPPED, chip STILL PINNED** (round-3 commit below).
  New `lib/atm10-health.lua` (+ root mirror) `health.bridgeDegraded(state, ok, threshold)`:
  increments a consecutive-failure count, resets on success, returns degraded once
  count>=threshold (default 3). 20 biting tests in run.lua (N-1 not degraded, Nth degraded,
  success resets, monotonic until reset, nil/false = failure, default threshold). **NOT
  wired into the manager render this round** — the header chip needs manager state at the
  186-local cap and is in-game-visual, so it stays pinned to land with B1.
- **Gate after round 3:** 573 passed / 0 failed (+20), both smokes OK, mirrors identical,
  manager locals unchanged at 186.

---

## Session log — 2026-06-26 (round 2: smart-mode accuracy sweep + recon)

- **SMART-1 confidence-weighted ranking — SHIPPED** (`8b35ac3`). `analyze()` weights
  `_rank` by `(0.5 + 0.5*conf)` where `conf = nSamples-confidence × span-confidence`;
  thin/short evidence is demoted but never zeroed. Exposes `s.conf`. Pure lib, biting
  tests.
- **SMART-2 maxA + spiky detection — SHIPPED** (`db2b73f`). `record()` tracks a running
  max; `analyze()` seeds cap/compress ceilings from `max(aN, maxA)` (not a possibly-low
  last sample) and tags self-replenishing items `spiky`, damping their confidence so
  they rank below monotone drainers of equal net decline. Backward-compatible (maxA
  defaults to aN). Pure lib.
- **SMART-3 surface rate + confidence on the SMART row — SHIPPED** (`195c096`). New pure
  `suggest.confLabel`; row shows `~N/min, conf lo/med/hi[, spiky]`. Render-only, no
  hit-region or local-count change. `in-game-verify: pending` (exact row layout is
  in-world-visual).
- **SMART-6 suggestion invariants pinned — SHIPPED** (`e4bdcba`). Test-only:
  at-most-one-suggestion-per-name + max-truncation-keeps-highest-confidence. Both bite.
- **Gate after round 2:** 553 passed / 0 failed (+28 tests), both smokes OK, mirrors
  identical, manager locals unchanged at 186.
- **SKIPPED (conservative):**
  - **SMART-4 (regression/min-floor slope gate):** behavior-changing, can suppress
    legitimate quotas, and overlaps the spiky-confidence damping already shipped in
    SMART-2 (a safer mechanism for the same recovery-spike false-quota concern). See
    SMART-7 below for the residual idea, kept as flag-only.
  - **SMART-5 (needpattern/CRAFT-4 advisory branch):** blocked on the live-grid
    `craftable`-blind recon blocker; not shipping a dead pure branch with no value
    alone. Pinned as SMART-8 below, gated on a craftable source.
- **RECON (SSH locked):** the round-2 base recon could **not** read the live base —
  the 1Password ED25519 agent was locked, so SSH to `zjn-home-two` failed. All
  base-state findings this pass are from repo files + the 2026-06-24/25 memory snapshot.
  The big finding (deployed config is the ~13-item hand-written set, NOT the late-game
  banded spec; control not enabled live) is now flagged in `AUTOMATION_PLAN.md` and
  `BASE_INTEGRATION.md`. Re-verify on the next unlocked pass.

---

## Session log — 2026-06-26 (Code phase, touch/perf/reliability sweep)

- **C2 notInGrid hoist — SHIPPED** (`d0cfc86`). Added `managed.countNotInGrid(store,
  itemsByName)` (pure, unit-tested + bite-verified), compute the PLAN "not in grid"
  count once in `scan()`, drawPlanPage reads `data.notInGrid`. No new top-level
  locals; gate 525/0, smokes OK, mirrors identical.
- **A1 STAB-2 + A2 STAB-1 — CONFIRMED ALREADY SHIPPED** (no new commit). The
  `requestCraft` isConnected/isOnline recheck is live at `inventory-info.lua:813-825`
  and the `smoke_auto.lua` test (STAB-2 detach-after-scan) **bites** — removing the
  recheck flips "craftItem was NOT issued" to FAIL. Verified, then restored.
- **Pinned, NOT committed this pass (deferred to discussion / in-game-visual):**
  - **A3 bridge-degraded chip** — the useful payoff is a header chip whose value is
    only verifiable on a live monitor, and it adds per-frame state under the 186-local
    cap. Pin rather than ship a half-visible feature.
  - **C1 tap-flash on Browse/Smart/Presets/editor** — render-only, but its whole
    point (does a coarse tap acknowledge) is physical/in-game; pin.
  - **D2 box/gauge wire-or-delete** — neither half is safe unattended: "wire" needs
    visual verify; "delete" removes helpers Codex's UI-3/UI-5 roadmap intends to use.
    Needs the wire-or-delete decision made with the operator first.
  - **B1/B2/C3/D1/D3/D4/D5** — unchanged: double-buffer wirings + restyles are
    in-game-visual and/or major/high-risk (B1 manager buffer is at the local cap).
    Do B1 first; C3/D3 depend on it.

---

## Tier A — Reliability (do first)

### A1. STAB-2: recheck bridge attachment before every mutating `craftItem`
- **S · value high · risk med · Verify: gate (effect visual) · Phase: Code**
- `inventory-info.lua:808` `requestCraft` (mirror `inventory/manager.lua`), craft path
  at `914-927`. The read path rechecks `isConnected` (`1023-1036`); the craft path
  does NOT.
- **Change:** before `craftItem`, if `call(bridge,'isConnected') ~= true` then null
  the cached bridge handle and `return false,'bridge offline'`. Unit-test with a
  disconnected fake bridge (craftItem call count stays 0).
- **Why #1:** issuing the mutating call at a half-detached bridge is the precise
  trigger for the uncatchable AP `NotAttachedException`. The only code-side lever on
  the top reliability risk (shrinks the window; cannot eliminate the async exception).
  Verify against current code — some STAB work may already be merged.

### A2. STAB-1: pin STAB-2 with smoke tests (ships paired with A1)
- **S · value high · risk low · Verify: gate · Phase: Code**
- `tests/smoke_auto.lua`. Inject an unknown event → loop ignores without throwing;
  make stubbed `craftItem` raise → `call()`/`guard()` contain it, loop survives,
  entry treated as BLOCKED not crafted. Removing the pcall in `call()` must make the
  assertion fail (proves the test bites).

### A3. Surface "bridge degraded" chip from consecutive `call()` failures
- **S · value med · risk low · Verify: gate (chip visual) · Phase: Code**
- `inventory-info.lua:182-188` `call()` swallows every bridge error to nil; `515-519`
  getItems fallback; `1032-1036` stale-hold.
- **Change:** track a single consecutive-failure counter (bundle into an existing
  state table — locals cap) and render a `bridge degraded` chip on header line 4.
- **Why:** a flaky/slow bridge currently reads as "fine" until it fully drops; the
  operator gets no signal that scans are going stale/inconsistent.

---

## Tier B — Touch responsiveness (high value, the operator's felt pain)

### B1. UI-2: wire the double buffer into the manager console
- **M (recon) / major (caution) · value high · risk med→high · Verify: visual · Phase: discuss**
- `inventory-info.lua:1709-1710` (`clear()`+redraw every frame), `1736-1738`/`1764-1766`
  (per-line `clearLine`); diff buffer exists at `atm10-draw.lua:160-176` and is wired
  ONLY in the viewer (`inventory-remote.lua:233-235`) — **zero manager callers**.
- **Change:** build a frame, end with `prevFrame=renderBuffer(monitor,frame,prevFrame)`
  exactly as remote.lua does; drop `clear`/`clearLine`. **Bundle frame/prevFrame into
  an existing table** (locals at 186). Keep ALL hit-region builders (`planRowRegions`
  etc., `1711-1723`) in lockstep — buffer changes nothing about x/y math.
- **Why:** kills the full-screen flash on every tap + every 5s poll; makes taps feel
  instant (only changed rows repaint) and cuts per-frame monitor I/O. The operator's
  **top-priority polish item** and highest responsiveness-per-effort win.
- **Pinned for discussion** because: touches ~20 renderCurrent call sites, mirror pair,
  locals cap, and the whole point (flicker) is in-game-only verifiable. Wire BEFORE any
  restyle (chips/zebra on a still-`clear()`'d screen still flicker).

### B2. Shrink the touch-blocking window behind `scan()`
- **M · value high · risk med · Verify: gate (feel visual) · Phase: Code (parts) / discuss (coroutine)**
- `inventory-info.lua:2230-2256` single-threaded loop; `2190-2213` refreshAndDraw runs
  `scan`+craft before a queued `monitor_touch` is serviced; `1026` getItems / `1055`
  sort / `1095-1101` trend record. A tap arriving mid-scan waits for the whole
  scan+plan+craft cost.
- **Lowest-risk wins (Code):** (a) only build the full trend snapshot loop
  (`1094-1099`) when smart mode is on; (b) skip the whole-list `table.sort` (`1055`)
  when no page needs sorted order this frame.
- **Larger (discuss):** move `scan` onto a parallel coroutine so touch is never blocked.
- **Tunable (doc):** `refreshSeconds` floored at 2s (`229`) — raising it cuts TPS load
  AND touch-block frequency; document the tradeoff.

---

## Tier C — Tap feedback & safety (small, high-confidence)

### C1. UI-3 groundwork: flash confirmation on Browse / Smart / Presets / editor taps
- **S · value med · risk low · Verify: gate · Phase: Code**
- flashMsg rendered only on PLAN (`1323-1325`) and QUEUE (`1401-1402`). `toggleSmart`
  (`1969-1976`), `openEditor` (`1893-1919`), `applyPreset` (`1947-1966`, presetStatus
  only) give NO immediate on-screen ack — taps feel dropped, operator re-taps.
- **Change:** render the existing flashing pattern on the Browse/Smart/Presets/editor
  hint lines so every tap acknowledges. Pairs with B1 (flash line is one of the few
  rows that change per tap → repaints cheaply).

### C2. notInGrid hoist out of `drawPlanPage`
- **S · value med · risk low · Verify: gate · Phase: Code**
- `inventory-info.lua:1287-1290` iterates all ~79 quotas with an itemsByName lookup
  **every render** (fires on every touch + poll), though inputs only change on
  `scan()`/editor save.
- **Change:** compute notInGrid once at end of `scan()` (`~1044`, where itemsByName is
  rebuilt) and cache; the page reads the cached count. Pure refactor, no visual change.

### C3. UI-4: enlarge tap targets for destructive/primary buttons
- **M · value med · risk med · Verify: visual · Phase: DONE**
- One-row, label-width targets: APPROVE ALL (`1331`), CLEAR QUEUE (`1407`), mode chip
  (`1768`), nav arrows, editor `[+]`/`[-]` (`1536-1539`). Coarse cursor → dangerous
  mis-taps (CLEAR QUEUE, mode→auto).
- **Change:** render as bg-filled chips, accept taps across the full painted area,
  widen destructive ones. **CRITICAL:** update the matching region builder
  (`planActionRegion:1332`, `queueActionRegion:1408`, `modeChip:1770`, `*NavRegions`,
  editorRows `1540`) in the SAME edit. Depends on B1 landing first.
- **Shipped:** wider painted chips + matching hit regions are in code; physical
  monitor feel remains **in-game-verify: pending**.

---

## Tier D — Other UI flicker & polish

### D1. UI-1 sibling: wire the double buffer into the power display
- **M · value high · risk med · Verify: visual · Phase: discuss**
- `power-display.lua:239` `mon.clear()` every frame; `108`/`154`/`222` `clearLine`.
  Pattern proven in viewer (`remote.lua:230-237`).
- **Change:** port a `present()` wrapper; route `line()`/`drawBar` into the buffer;
  render graph cells as colored-space `bufferWrite` (bg arg already supported);
  diff-render. Stay byte-identical to `power/display.lua` (mirror).
- **Why:** removes the largest "feels cheap" tell on the most-watched screen. Graph
  cells are the only nontrivial port.

### D1b. Power graph tap-to-expand + interactive timeframe/scale cycle — PINNED
- **M · value med · risk high · Verify: visual (in-game only) · Phase: discuss**
- **Pure groundwork DONE (shipped):** `power.downsample`, `power.bucketByTimeframe`,
  `power.computeScale` in `atm10-power.lua` (gate-tested), and the nicer min-max
  sparkline render + `NET_SCALE_MODE`/`NET_SCALE_FIXED` config in `power/display.lua`.
  What remains is purely the INTERACTIVE layer.
- **Why pinned:** the display main loop is passive —
  `power-display.lua` `while true do local _, msg = rednet.receive(PROTOCOL, 1) ... pcall(draw)`.
  It never calls `os.pullEvent`/`monitor_touch`/`os.startTimer`, so it cannot see a tap.
  Tap-to-expand and a tap-to-cycle timeframe (1m/10m/1h via `bucketByTimeframe`) / scale
  (auto↔fixed via `computeScale`) selector REQUIRE converting it to an event-driven
  `os.pullEvent` loop like the viewer (`remote.lua:465-498`). That rewrite must preserve
  the existing `pcall(draw)` self-heal and history-on-receive append exactly, AND it
  overlaps the D1 double-buffer rewrite — so do it **with D1, one owner, in-game only.**
- **Also:** a 1h window needs `HISTORY_LIMIT` raised from 180 (3 min) to ~3600 (and
  optionally a pure save/load so the trend survives reboot — currently RAM-only,
  `power-display.lua` `history={}`/`netHistory={}`). The cap raise is low-risk but
  pointless without the timeframe UI, so it lands with this item.
- **Whether the power monitor is physically touch-capable is unknowable from code** —
  verify in-world before building the touch path. NOT to be fired unattended.

### D2. Decide: wire box/gauge into the viewer panels OR delete them
- **S · value med · risk low · Verify: gate · Phase: Code**
- `atm10-draw.lua:85-108` `box`/`gauge` have **zero callers** repo-wide. The plan says
  decide wire-or-delete by UI-1 (don't leave cruft on the ~1MB disk).
- **Change:** either frame the viewer's Item-Storage / RS-Energy blocks
  (`remote.lua:253-271`) with `box` + `gauge` for the percentage (UI-3 look), OR delete
  both functions + their tests to reclaim bytes. Both helpers are pure + gate-testable.

### D3. UI-3: styled header band + status chips across manager pages
- **M · value med · risk med · Verify: visual · Phase: discuss**
- `inventory-info.lua:1727-1777` header is flat; modeChip region `1770`, reboot chip
  `1775-1777`. Add `drawHeaderBand` (inverted full-width title) + bg-filled chips via
  `bufferWrite`; right-align the reboot-safety chip; keep modeChip's hit region in
  lockstep. **Depends on B1 — do NOT restyle while still clear-and-redrawing.**

### D4. Zebra rows + boxed gauges on the viewer's stored-items list
- **S · value med · risk low · Verify: visual · Phase: Code (lands with viewer buffer)**
- `remote.lua:289-307` row loop; `bufferWrite` bg support `atm10-draw.lua:131-158`.
  Alternate a faint bg on odd/even rows. Pure-additive, no hit-region impact.

### D5. UI-5: composed too-small / empty / loading panels
- **M · value med · risk low · Verify: gate (render) + visual (placement) · Phase: Code**
- Bare gray one-liners: Browse empty (`1448`), Smart none (`1665`), Queue none
  (`1350`), viewer drawWaiting (`remote.lua:239-245`). No explicit too-small panel when
  `pickTextScale` bottoms out (`remote.lua:87-95`, `power-display.lua:45-59`).
- **Change:** centered boxed panels (reuse `box`) for empty/loading + an explicit
  `Monitor too small — enlarge to ≥ NxM` panel at the scale floor. Gives box/gauge a
  second caller (pairs with D2).

---

## Tier S — Smart mode (pure lib, gate-provable; round-2 follow-ons)

> The four highest-value smart-mode wins (SMART-1/2/3/6) shipped round 2. These are the
> remaining ideas from the smart-mode lens, ranked. All are pure `lib/atm10-suggest.lua`
> (mirror to root `atm10-suggest.lua`) except where noted — gate-provable, ship
> unattended once tests bite.

### S7. Robust slope / min-floor sustained-drain gate (residual of SMART-4)
- **M · value med · risk med · Verify: gate · Phase: discuss**
- `lib/atm10-suggest.lua` `decline = a0 - aN` is two-point and hostage to the first/last
  sample. The full SMART-4 (least-squares slope) was **skipped** as behavior-changing +
  overlapping SMART-2's spiky damping. The residual safe idea: require `minA` to be
  within `minDrain` of `aN` before firing a steady-quota, so a single recovered dip
  (`1000→100→900`) does **not** emit a quota while a monotone `1000→…→100` does.
- **Why discuss, not Code:** still behavior-changing (can suppress a real quota); SMART-2
  already damps the same false-quota case via confidence. Only ship if SMART-2's damping
  proves insufficient in-world. Test must BITE: recovery-spike series emits no steady
  quota; monotone drainer still does.

### S8. needpattern advisory branch — PURE BRANCH SHIPPED, wiring still gated
- **M · value med · risk low · Verify: gate (pure) + blocked (wiring) · Phase: partially shipped**
- `analyze()` has no craftability input, so it can't separate "drains hard AND we can
  autocraft it" (actionable quota) from "drains hard but has NO pattern" (operator must
  spawn one — CRAFT-4). Add an optional `ctx.patternless = {[name]=true}`; for an
  unmanaged steady drainer in that set, emit `kind='needpattern'` (advisory, rendered
  `[NEEDS PATTERN]`). When `ctx.patternless` is absent, behavior is byte-identical
  (backward compatible).
- **Shipped locally:** the pure `ctx.patternless` branch now emits `kind='needpattern'`
  instead of a quota, with unit coverage and Smart-page advisory rendering. When
  `ctx.patternless` is absent, existing quota behavior is unchanged.
- **Still blocked:** the live grid reads `craftable` blind (recon blocker — see
  `base-recon-findings`), so there is no trustworthy source to populate
  `patternless` today. Manager feed wiring stays deferred until CRAFT-4 lands a
  craftable source.

---

## Tier F — Base / config truth (docs + deploy; round-2 recon)

> Not code-shippable unattended (most need the operator + a live base). Pinned so the
> deployed-vs-documented gap and the SSH-locked staleness are not lost.

### F1. Deploy the late-game config (or decide to stay minimal)
- **operator action · value high · risk med · Verify: in-game · Phase: discuss**
- Deployed `inventory-config.lua` = ~13-item hand-written manual set; the banded
  balancer lives only in the `zoozo-late-game` preset and is **not applied**. Deploying =
  apply the preset on the console (flips smart mode on) + the dust-floor fix (F2) + the
  namespace fix (F3). See `AUTOMATION_PLAN.md` §0/§8 and `BASE_INTEGRATION.md` §1.

### F2. Dust rows: floors-to-watch, NOT craftTo refill
- **S · value med · risk med · Verify: in-game · Phase: discuss**
- `chain()` sets every `*_dust` to `target = craftTo = 264000`, but `dust→ingot` is a
  processing recipe with no spawnable pattern yet (operator Q1) and no grid recipe
  produces dust — so the planner perpetually tries+fails to refill it. Change dust rows
  to watch/compress-source only (no `craftTo`) until the reference processing pattern
  exists. `lib/atm10-presets.lua` chain helper.

### F3. Reconcile preset metal namespaces (`alltheores:` is canonical)
- **S · value med · risk med · Verify: in-game · Phase: discuss**
- Early/mid presets use `mekanism:steel_ingot` / `mekanism:bronze_ingot` /
  `mysticalagriculture:prosperity_ingot` etc.; recon + the zoozo chain say these are
  `alltheores:*`. The wrong-namespace rows read NOT CRAFTABLE and never craft. Reconcile
  against the live `getItems` grid (`in-game-pending`).

### F4. Enable + lock down control on the live config
- **S · value high · risk low · Verify: in-game · Phase: discuss**
- Deployed config has NO `controlEnabled`/`allowRedstone`/`controlToken`/
  `controlAllowedSenders` keys → computer 6 cannot accept a control command today
  ("proven end-to-end" was a test config, finding #4). Stage 0 real work: add the keys
  (enabled + redstone), set trusted sender IDs + token (operator Q5). `BASE_INTEGRATION.md`
  §3 Stage 0.

### F5. Re-run live recon when 1Password is unlocked
- **S · value med · risk low · Verify: in-game · Phase: discuss**
- This pass's base findings are from repo + the 2026-06-24/25 memory (SSH locked). One
  read-only pass when unlocked (cat the five `.atm10-*` under `computercraft/computer/6/`
  + tail the latest server log) confirms which preset/quotas are loaded, current mode,
  what's mid-craft, and whether control was ever enabled — confirms/refutes F1, F2, F4.

---

## Tier E — Low value / flag-only

### E1. Pause auto page-rotation after any recent interaction on an auto page
- **S · value low · risk low · Verify: gate · Phase: Code (cheap) or skip**
- `inventory-info.lua:1809-1826` `advancePageIfDue` rotates PLAN↔QUEUE every
  PAGE_SECONDS; `1799-1804` setPage resets pageShownAt. A manual page is already held;
  only PLAN/QUEUE auto-rotate mid-read (reads as the UI "jumping").
- **Change:** extend the no-rotate-while-recently-touched window so any recent
  interaction on an auto page also pauses rotation briefly. Flag-only, minor.

---

## Roll-up

| ID | Item | Size | Value | Risk | Verify | Phase |
|---|---|---|---|---|---|---|
| A1 | STAB-2 craftItem isConnected recheck | S | high | med | gate | DONE (already shipped, test bites) |
| A2 | STAB-1 pin with smoke tests | S | high | low | gate | DONE (smoke_auto bites) |
| A3 | bridge-degraded helper / gating / chip | S | med | low | gate | DONE (helper + gating + `[BRIDGE HELD]` header chip; in-game-verify pending) |
| B1 | UI-2 manager double buffer | major | high | high | visual | DONE (existing diff-buffer path hardened; in-game-verify pending) |
| B2 | shrink touch-block window | M | high | med | gate | Code slice DONE (trend gated; scan no longer always sorts full grid); coroutine rewrite still discuss |
| C1 | tap flash on Browse/Smart/Presets/editor | S | med | low | gate | DONE (`166a75c`, in-game-verify pending) |
| C2 | notInGrid hoist | S | med | low | gate | DONE (d0cfc86) |
| C3 | UI-4 enlarge tap targets | M | med | med | visual | DONE (wider painted chips + matching hit regions; in-game-verify pending) |
| D1 | power-display double buffer | M | high | med | visual | DONE (diff-buffer wired; in-game-verify pending) |
| D2 | box/gauge wire-or-delete | S | med | low | gate | DONE (`draw.box`/`draw.gauge` wired into viewer panels; buffer target covered) |
| D3 | UI-3 header band + chips | M | med | med | visual | DONE (header band + mode/autocraft/bridge chips; in-game-verify pending) |
| D4 | viewer zebra rows | S | med | low | visual | DONE (alternating viewer row backgrounds; in-game-verify pending) |
| D5 | UI-5 empty/too-small panels | M | med | low | gate+visual | DONE (viewer waiting/no-items/too-small panels shipped; in-game-verify pending) |
| E1 | pause auto-rotation on interaction | S | low | low | gate | DONE (touches now pause dashboard auto-rotation) |
| SMART-1 | confidence-weighted ranking | S | high | low | gate | DONE (`8b35ac3`) |
| SMART-2 | maxA + spiky detection | M | high | low | gate | DONE (`db2b73f`) |
| SMART-3 | surface rate+conf on SMART row | S | med | low | gate | DONE (`195c096`, in-game-verify pending) |
| SMART-6 | suggestion invariants (tests) | S | low | low | gate | DONE (`e4bdcba`) |
| S7 | robust slope / min-floor gate | M | med | med | gate | discuss (overlaps SMART-2) |
| S8 | needpattern advisory branch | M | med | low | gate+blocked | pure branch shipped; wiring gated on CRAFT-4 |
| F1 | deploy late-game config | op | high | med | in-game | discuss |
| F2 | dust rows = watch, not refill | S | med | med | in-game | discuss |
| F3 | reconcile preset namespaces | S | med | med | in-game | discuss |
| F4 | enable+lock down live control | S | high | low | in-game | discuss |
| F5 | re-run live recon (SSH unlocked) | S | med | low | in-game | discuss |

**Code phase will attempt (gate-provable, ship unattended):** A1, A2, A3, B2 (parts),
C1, C2, D2, D4, D5, E1. *(Round 2: SMART-1/2/3/6 shipped.)*

**Pinned major-for-discussion (in-game-visual and/or high-risk):** B1 (manager double
buffer), C3 (tap targets), D1 (power double buffer), D3 (header band). These touch
mirror pairs + hit-regions and their payoff is only verifiable on a live monitor; do
B1 first since C3/D3 depend on it.

**Pinned for discussion (smart mode + base):** S7 (overlaps SMART-2's damping — only if
insufficient in-world), S8 (gated on CRAFT-4 craftable source), F1–F5 (operator + live
base; the deployed-vs-documented gap and SSH-locked staleness — see `AUTOMATION_PLAN.md`
+ `BASE_INTEGRATION.md`).
