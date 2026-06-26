# mc-atm-scripts — Improvement Plan

A staged, **loopable** roadmap for an implementing agent. Goals: better inventory
viewing + info, power viewing + info, autocrafting management, **stability (never
crash the server — top priority)**, and UI/display polish.

> Produced from a grounded audit of the codebase (5 parallel subsystem audits →
> synthesis → human hardening pass). Every task is concrete, test-gated, and
> ordered by value/risk. One task = one loop iteration.

> **Operator priorities (2026-06-25 review):** the system must first be *reliable* and
> *usable as good software others may run*. Ranked pains: (1) reliability / crashes,
> (2) can't control machines, (3) autocraft is opaque (can't tell if a craft worked).
> The external viewer is wanted but secondary (the in-game grid covers ad-hoc lookups).
> §5 sequencing reflects this. NOTE: autocraft is **LIVE** in-world (see §1) — the old
> `craftable_rows=0` framing was a CC introspection blind spot, not a crafting blocker.

---

## 0. How to use this doc (read first)

- **One task = one iteration:** implement → run the full gate → commit → push.
- **The gate (non-negotiable, identical every time):**
  - `lua tests/run.lua` → expect `361+ passed, 0 failed`
  - `lua tests/smoke.lua` → `SMOKE OK`
  - `lua tests/smoke_auto.lua` → `SMOKE-AUTO OK`
  - `lua tests/smoke_probe.lua` → `SMOKE-PROBE OK` *(runtime-executes the power probe loop; run.lua only parses it)*
- **Mirror discipline is a HARD gate** (see §2). After any edit, diff every touched
  pair and confirm identical *before* committing. A green suite on one copy still
  ships the unfixed copy to the in-game computer.
- **Pure-code vs in-game:** most tasks are pure-logic/render-with-stubs and can be
  finished + pushed unattended on the test gate. Tasks whose *real* effect needs a
  live RS Bridge / monitor must be implemented + unit-tested off-CC, then marked
  `in-game-verify: pending` and NOT considered fully done until verified in-world.
- **Never stall the loop:** if a task is in-game-blocked, skip it and take the next
  pure-code task.
- **Commit message format:** `<ID>: <what changed>` + a `mirror: verified identical`
  line + an `in-game-verify: <yes|pending|n/a>` line.
- **Stop rule:** after two failed attempts at the same task, stop and report what
  was tried, what failed, and what you suspect. Do **not** weaken/skip a test or
  wrap a failure in pcall to make the gate pass.

---

## 1. Architecture & hard constraints

- **Pure-lib design:** logic lives in `lib/atm10-*.lua` (unit-tested off-CC); thin
  UI in `inventory/manager.lua` (the touchscreen console, 5 tabs) + read-only
  viewers (`inventory/remote.lua`) + a two-computer power dashboard (`power/`).
- **Mirror pairs — every edit must touch BOTH halves:**
  - `lib/atm10-<x>.lua` ⇄ root `atm10-<x>.lua`
  - `inventory/manager.lua` ⇄ `inventory-info.lua`
  - `inventory/remote.lua` ⇄ `inventory-remote.lua`
  - `inventory/manager-startup.lua` ⇄ `inventory-startup.lua`
  - `power/display.lua` ⇄ `power-display.lua`
  - `power/probe.lua` ⇄ `power-probe.lua`
  - The updater (`atm10-update.lua`) distributes per role; if a new file is added,
    register it in `commonFiles`/`roles` there and in the compile list in
    `tests/run.lua`.
- **The headline crash (THE thing not to regress):** AdvancedPeripherals throws
  `NotAttachedException` and crashes the **whole server tick** if a computer
  detaches while AP still has an RS craft job pending (AP fires the job's
  completion event at a gone computer). This is a **server-thread async
  exception — no Lua pcall can catch it.** Code can only *shrink the trigger
  window*; the real fix is **force-loading** the CC chunk. Reads (`getItems`,
  energy, storage) are safe — only the autocraft path is fragile.
- **Autocraft is LIVE; CC-side craftability introspection is BLIND.** The system has
  actually crafted (`enderio:vibrant_alloy_ingot`, 2026-06-24) through RS as the queue
  recommended — patterns exist and `craftItem` fires in-world. But the CC RS-Bridge
  export reports `craftable_rows=0` / `isCraftable=false` for *every* item (RS 2.0 stores
  patterns as block-entity data-components the export can't see). Consequences: (a) the
  craft + crash path IS exercisable in-world — **STAB-2 matters now**; (b)
  `getCraftableItems`/`isCraftable` are **NOT trustworthy** craftability signals — the
  only reliable "exists" signal is presence in the `getItems` grid; (c) `craftItem`'s
  exact return shape and `getCraftingTasks` shape are still **in-game-gated** (need a
  live-bridge probe — CRAFT-1).
- **Three standing guardrails:**
  1. Never add an un-throttled bridge call — gate new reads behind a
     `STATS_INTERVAL_MS`-style throttle.
  2. Never grow a persisted file unbounded — every on-disk state needs a cap/TTL
     and `atomicWrite` (a ~1MB CC disk already locked up once from an unbounded file).
  3. Keep hit-region builders in lockstep with any render restyle, or taps land on
     the wrong control.

---

## 2. ✅ Already shipped (do NOT redo — read the current code first)

The crash-resistance pass from the prior session is already merged. All items below are
**code-confirmed + unit-tested off-CC, but `in-game-verify: pending`** — none has been
verified against a live craft, so §2 means "code levers shipped," not "server-crash
solved." Verify against current code before starting STAB tasks:

- `control.rebootSafety()` + **`safereboot`** command + `.atm10-craftstate` drain
  snapshot — drain-safe reboot (waits until nothing crafting + 120s drain window).
- **Reboot-safety chip** on manager header line 4 (`reboot ok` / `DO NOT REBOOT Ns`).
- **Viewer readiness banner** — `STARTING` / `RECONNECTING (last ok Ns)` / `LIVE`.
- **Hang watchdog** — manager emits `.atm10-heartbeat` each cycle; the startup
  wrapper runs the program under `parallel.waitForAny` with a watchdog that
  restarts the **program** (not the computer → bridge stays attached) after 90s
  with no heartbeat. **This already satisfies STAB-6's goal** (detect + recover a
  hung loop); only an optional in-loop peripheral self-heal remains.
- README stability section documenting the AP crash + safereboot + force-load.
- Exact-number refill (`effectiveCraftTo`, no auto-band/rounding).

**Reconciliation of STAB tasks below:** STAB-6 = essentially done (skip or reduce
to the in-loop self-heal nicety). STAB-7 = README docs done; only the **startup
boot-time force-load reminder print** remains. STAB-3 (crash-loop backoff) is still
open. All other STAB tasks are open.

---

## 3. Workstreams

| Code | Workstream | Goal |
|---|---|---|
| **STAB** | Stability & crash-resistance | Shrink crash probability/blast radius; lock safety invariants under tests so refactors can't silently regress them. |
| **QUICK** | High-value quick wins | Surface info/behavior that costs near-zero new bridge load (data already collected or helper already exists). |
| **VIEW** | Inventory viewing, search & detail | Turn the viewer from an 8-item teaser into a paginated, searchable, sortable list with detail + trends. |
| **CRAFT** | Autocrafting management & job truth | Make the queue reflect RS's *real* crafting state; validate quota IDs; pattern-setup worklist; fairer scheduling. |
| **UI** | Display polish & touch ergonomics | Wire the (already-written, unused) double buffer to kill flicker; styled components; bigger tap targets. |
| **CTRL** | Control foundation | Turn the dead capability scaffolding (`atm10-control.lua` redstone/export/security gates + `CONTROL_ARCHITECTURE.md`) into one real, gated, testable actuator path — the bones of the eventual factory/base control center. |

**Key audit findings driving these:** the flicker-free diff double-buffer + box/gauge
helpers in `atm10-draw.lua` have **zero callers** (both UIs clear-and-redraw every
frame) — highest polish-per-effort. Viewing is weakest (`TOP_ITEM_COUNT=8`, no
search, one sort). Queue job state is **partial** — CRAFTING *is* reconciled against RS
via live `isItemCrafting` (`manager.lua:847`); what's local is timestamps, ETA, and
made-vs-requested progress (no RS task-list is read). `requestCraft` issues the mutating
`craftItem` with no `isConnected` recheck (the read path checks it; the craft path doesn't).

---

## 4. Backlog (ordered, independently shippable)

Each task: **what** to do, **why**, **files**, **acceptance**, size, risk, deps.

### STAB — Stability & crash-resistance (do first)

**STAB-1 — Pin synchronous-exception containment with smoke tests** · S · low · deps: STAB-2 *(ships paired — this test pins STAB-2's fix; do STAB-2 first)*
- *What:* Extend `tests/smoke_auto.lua`: (a) inject an unknown event name into stubbed `pullEvent`, assert the loop ignores it without throwing; (b) make stubbed `bridge.craftItem` raise, assert `call()`/`guard()` contain it, the loop survives, and the entry is treated as rejected (BLOCKED) not crafted.
- *Why:* Locks the most important server-safety invariant (no unhandled throw reaches the loop) before any refactor can regress it. Pure off-CC.
- *Files:* `tests/smoke_auto.lua`
- *Acceptance:* `lua tests/smoke_auto.lua` prints SMOKE-AUTO OK with two new assertions; temporarily removing the pcall in `call()` makes the throwing-craftItem assertion fail (proves the test bites).

**STAB-2 — Recheck bridge attachment immediately before every mutating `craftItem`** · S · med · deps: none *(loop starts here)*
- *What:* In `requestCraft` (`inventory/manager.lua:~735`) before `craftItem`, add: if `call(bridge,'isConnected') ~= true` (and/or `isOnline`) then null the cached bridge handle and return `false,'bridge offline'`. Mirror into `inventory-info.lua`. Add a unit test with a disconnected fake bridge.
- *Why:* Issuing the mutating call at a half-detached peripheral is the precise trigger for the async crash. `scan()` checks connection for reads; the craft path doesn't. The only code-side lever on the #1 risk (shrinks the window; does not fully eliminate the async exception).
- *Files:* `inventory/manager.lua`, `inventory-info.lua`, `tests/run.lua`
- *Acceptance:* Unit test: `requestCraft` with a disconnected fake bridge returns `false,'bridge offline'` and `craftItem` call count stays 0. `lua tests/run.lua` pass; mirror identical. **in-game-verify: pending** (real crash effect needs patterns).

**STAB-3 — Crash-loop backoff + circuit-breaker in startup wrappers** · S · low · deps: none
- *What:* In `inventory/manager-startup.lua` (mirror the others) track time-since-start; if the program dies `<N`s after launch K consecutive times, switch the flat 5s sleep to exponential backoff (5→10→30→60s, capped) and print a loud persistent `persistent crash — check inventory-config` line. Reset on a run surviving > threshold.
- *Why:* A corrupt config or bad self-update currently becomes a tight 5s crash loop forever. (Note: the hang watchdog already exists here; add backoff alongside it.)
- *Files:* `inventory/manager-startup.lua`, `inventory-startup.lua`, `inventory/remote-startup.lua`, `power/probe-startup.lua`, `power/display-startup.lua`
- *Acceptance:* Review: a simulated immediate-exit escalates the sleep after K iterations + prints the banner; a long run resets. Startups compile via `tests/run.lua`. **in-game-verify: pending.**

**STAB-4 — Cap and age the `.atm10-dismissed` set** · S · low · deps: none
- *What:* Give `dismissedSuggestions` the trends treatment: hard entry cap (drop-oldest) and/or TTL prune during the smart cycle; call prune where dismissed is saved (`~manager.lua:1923`). Mirror into `inventory-info.lua`. Unit test adding > cap entries.
- *Why:* Trends + queue are bounded; `.atm10-dismissed` grows monotonically on a shared ~1MB disk that already caused an out-of-space lockup (`atomicWrite` needs ~2× transient space).
- *Files:* `inventory/manager.lua`, `inventory-info.lua`, `tests/run.lua`
- *Acceptance:* Unit test: inserting cap+50 dismissals leaves the saved set ≤ cap. Tests pass; mirror identical.

**STAB-5 — Make updater writes atomic** · S · low · deps: none
- *What:* In `atm10-update.lua` convert `writeRole`'s plain open+write+close (`~77-81`) to tmp+move atomic, and make `download()`'s delete-then-move (`~114-115`) write to tmp then move over, so a crash mid-update can't leave a deleted-but-unreplaced script.
- *Why:* A crash during self-update currently bricks that computer until re-bootstrapped — inconsistent with the atomicWrite discipline used for all state files.
- *Files:* `atm10-update.lua`
- *Acceptance:* Review confirms no path deletes the live script before the replacement is fully written. Compiles via `tests/run.lua`.

**STAB-6 — (LARGELY DONE) In-loop self-heal nicety** · S · low · deps: STAB-1
- *Status:* The hang-detect+restart goal is already shipped (heartbeat + startup `parallel` watchdog). **Optional remainder:** on a detected stall, drop+reacquire peripherals in-loop (faster than a full program restart). Skip unless cheap.
- *Files (if done):* `inventory/manager.lua`, `inventory-info.lua`
- *Acceptance:* Logic test with a stubbed clock past threshold triggers recovery once; normal progress resets. Tests pass; mirror identical.

**STAB-7 — Startup boot-time force-load reminder** · S · low · deps: none
- *Status:* README/docs force-load section already shipped. **Remainder:** have manager startup print a one-line `STABILITY: this computer must be chunk force-loaded` reminder on boot.
- *Files:* `inventory/manager-startup.lua`, `inventory-startup.lua`
- *Acceptance:* Startup prints the reminder line (verified by reading the wrapper). No test impact.

### QUICK — High-value quick wins

**QUICK-2 — Unit-test the power math** · M · low · deps: none · *(do early; unblocks power work)*
- *What:* Tests feeding synthetic samples (no monitor): `estimateTime` (incl. `/20` and near-zero "stable"), `effectiveNet` (reported-vs-estimated switch), `getPercent` (0-1 / 1-100 / maxEnergy=0), `fmt` thresholds (FE/kFE/MFE/GFE/TFE). Refactor those functions to be require-able if needed (keep `display.lua` mirror-identical to `power-display.lua`).
- *Why:* Load-bearing power conversions have zero coverage; a `/20` or percent regression would ship silently. Enables safe iteration on all power UI.
- *Files:* `tests/run.lua`, `power/display.lua`, `power-display.lua`
- *Acceptance:* New power-math assertions pass; breaking `/20` makes `estimateTime` tests fail. Mirror identical.

**QUICK-1 — Surface power `transferCap` as a throughput-headroom readout** · S · low · deps: QUICK-2
- *What:* In `power/display.lua` read `msg.transferCap` (already sent by `probe.lua`, currently ignored) and render `Cap: <in>/<cap> in, <out>/<cap> out` or a headroom bar. Mirror into `power-display.lua`.
- *Why:* Data already on the wire for free; a key matrix-tuning number that's dead weight today. **in-game-verify: pending** (placement).

**QUICK-3 — Redstone + speaker alarm on CRITICAL / DRAINING-to-empty / STALE** · S · low · deps: QUICK-2
- *What:* On entry to CRITICAL / draining-toward-empty / STALE, pulse a configurable redstone side and/or `speaker.playNote`, with hysteresis so it doesn't chatter at the threshold. Config-driven side/enable. Mirror.
- *Why:* Low power is silent today unless someone watches the monitor — the biggest power-dashboard gap. **in-game-verify: pending** (sound/redstone).
- *Acceptance:* Unit test on the alarm-decision function (stubbed redstone/speaker): fires on entry to CRITICAL, not again until cleared.

**QUICK-4 — Distinct SENSOR-UNREACHABLE state in the power probe** · M · low · deps: QUICK-2
- *What:* `probe.lua`'s `call()` distinguishes method-missing/pcall-fail from a real 0 (`sample.ok=false`); display shows a `SENSOR` state instead of a fabricated `0/0/0%`. Mirror both files.
- *Why:* A detached/wrong induction port currently renders as a plausible empty matrix — a false-negative read as a glitch or a fake low-power event.

**QUICK-5 — Persist per-item last-craft-result; surface on QUEUE + editor** · S · low · deps: STAB-2
- *What:* Record last `requestCraft` outcome per item (ok/reason/timestamp) in the ledger (`recordCraftRequest` already writes there) and render `last craft: OK 2m ago` / `last craft: bridge rejected` on QUEUE rows + in the editor. Keep bounded. Mirror.
- *Why:* `craftItem`'s return shape is unconfirmed; a persistent per-item result makes the first real craft debuggable from the screen.

**QUICK-6 — Magnitude bars + storage-headroom line in the viewer** · S · low · deps: none
- *What:* (a) Render each Top-Items row with `uiDraw` bar/gauge scaled to the #1 amount. (b) Add a storage-headroom line: free-types-remaining when available, plus a fallback (unique type count + total amount) when `getMaxItemDiskStorage` is unavailable so the section never degrades to one gray line. Mirror into `inventory-remote.lua`.
- *Why:* Both reuse helpers/data already present; turns a flat number list into something scannable.

**PWR-1 — Persist power history to disk + hour/day view** · M · low · deps: QUICK-2
- *What:* Write the display ring buffer (or a downsampled 1/min + 1/hour aggregate) to a **bounded** file via `atomicWrite` so a watchdog restart doesn't wipe history; add an hour/day graph toggle. Cap file size. Mirror.
- *Why:* History is RAM-only (~3 min); the documented recovery (watchdog restart) wipes it. Bounded per the ~1MB disk lesson.

### UI — Display polish (strict chain: each depends on the prior)

**UI-1 — Wire the double buffer into the viewer (`remote.lua`) first** · M · med · deps: none
- *What:* Replace `remote.lua`'s `monitor.clear()`+line-by-line redraw with `uiDraw.newBuffer`/`bufferWrite`/`renderBuffer` (build a frame, end with `prev=renderBuffer(monitor,buf,prev)`). Layout unchanged (viewer has no touch). Mirror. **Do the viewer first — smaller, no hit-regions.**
- *Why:* Eliminates the whole-screen flash every refresh (the largest "feels cheap" tell) using existing tested code, on the lower-risk surface first. **in-game-verify: pending** (flicker).
- *Acceptance:* Smoke renders a real (non-blank) viewer page through the buffer path; tests + smokes pass; mirror identical.

**UI-2 — Wire the double buffer into the console (`manager.lua`), hit-regions in lockstep** · M · med · deps: UI-1
- *What:* Same buffer wiring on `manager.lua` page draws + `renderCurrent` (called after each touch). Leave region-table builders untouched (they compute x/y independently) and verify no draw moved a row. Mirror into `inventory-info.lua`.
- *Acceptance:* `smoke.lua` still asserts a real page rendered; console hit-testing tests still pass (taps land on same rows); tests + both smokes pass; mirror identical.

**UI-3 — Styled-component layer (header band, chips, zebra table, boxed gauges)** · M · med · deps: UI-2
- *What:* Build helpers on `bufferWrite`: `drawHeaderBand` (inverted title+tabs with right-aligned chips), `drawChip`, `drawTable` (underline + alternating row bg + right-aligned numerics), and use `draw.box`/`draw.gauge` for the viewer's storage/energy. Apply across PLAN/QUEUE/BROWSE + viewer. Update each restyled row's hit-region builder in the same edit. Mirror all 4 files.
- *Acceptance:* hit-testing tests pass against restyled coords; smokes render non-blank; tests pass; all mirrors identical. **in-game-verify: pending** (visual).

**UI-4 — Enlarge tap targets; make interactive elements obvious** · M · med · deps: UI-3
- *What:* Render row actions + primary buttons (mode chip, nav arrows, editor +/−, APPROVE ALL/CLEAR QUEUE) as bg-filled chips and accept taps in the full painted area; widen single-char buttons; give destructive controls a wider/taller hit band; right-anchor + clamp the editor `[+]` so a 7-digit value can't push it off-screen. Update `console.rowHit`/`buttonHit` (or region tables) to match. Mirror all 4 files (incl. console lib⇄root).
- *Why:* Rows/buttons are one char tall → mis-taps that approve/cancel the wrong craft on a coarse cursor (dangerous for CLEAR/cancel/auto).

**UI-5 — Composed empty / loading / too-small states** · S · low · deps: UI-3
- *What:* Replace bare gray one-liners (`drawWaiting`, "Grid is empty", "No suggestions yet") with centered boxed icon-led panels; add an explicit `Monitor too small — enlarge to ≥ NxM` panel when `pickTextScale` bottoms out below 42×18. Mirror all 4 files.

### VIEW — Inventory viewing, search & detail (founded on VIEW-1)

**VIEW-1 — Broadcast a bounded fuller item slice (change-gated, chunked)** · M · med · deps: none
- *What:* Replace the hard `TOP_ITEM_COUNT=8` broadcast slice with a topN summary + a larger **bounded** full list: send sorted list in bounded chunks or only-on-change, with an explicit max-payload cap (do NOT raise naively to thousands). Keep the 8-item summary for the header. Mirror into `inventory-info.lua`. Test asserting the payload never exceeds the cap regardless of grid size.
- *Why:* Foundation for a real viewer while bounding rednet/serialization cost over ~5.9k items.
- *Acceptance:* Unit test: with a synthetic 5.9k-item grid the payload entry count stays ≤ cap; 8-item summary unchanged. Tests pass; mirror identical.

**VIEW-2 — Paginated, scrollable read-only viewer list** · M · med · deps: VIEW-1
- *What:* Give `drawView` `console.paginate` + touch paging like Browse (`[< PREV]`/`[NEXT >]`, row numbers) consuming VIEW-1's bounded list, with `monitor_touch` on the viewer computer. Mirror.
- *Why:* Turns the viewer into something that answers "do I have X, how much" — the single biggest viewing win.

**VIEW-3 — Selectable sort modes (Quantity / A-Z / Mod / Craftable)** · M · low · deps: VIEW-2
- *What:* Tappable sort chip cycling Quantity (default) / A-Z / Mod-namespace / Craftable-only, re-sorting the in-memory `sorted[]`/`itemsByName` (already built in `scan`). Apply on Browse and, via a sort field in the broadcast, on the viewer. Mirror.

**VIEW-4 — Touch A-Z / prefix filter strip (keyboard-free search)** · L · med · deps: VIEW-3
- *What:* Tappable A-Z/prefix filter strip on Browse (+ viewer) narrowing the in-memory list by `string.find` on name/id. **Keyboard-free** (players may have no keyboard); optionally also handle char/key when a keyboard is attached. Keep filter state bounded. Mirror all files (incl. console lib⇄root).
- *Why:* Finding one item among ~5.9k is impractical with quantity-sorted paging — search is the difference between usable and unusable at late game.

**VIEW-5 — Per-item trend arrows (up/down/flat + rate)** · M · low · deps: VIEW-1 · *(parallel to VIEW-2..)*
- *What:* Add a compact trend field (direction + per-min rate) to the broadcast, sourced from `atm10-suggest.lua`'s existing history. Render an arrow + rate next to rows (reuse `uiStatus` glyphs; add a rising counterpart to the DRAINING `v`). **MUST degrade gracefully** (hide, never error) when smart mode is off / history empty. Mirror.
- *Why:* "What's filling/draining and how fast" comes free from data already collected — no new bridge calls.

**VIEW-6 — Read-only item-detail card on tap (viewer + console)** · M · med · deps: VIEW-2
- *What:* On the viewer, wire `monitor_touch` to a read-only detail overlay (name, registry id from `compactItems.id`, namespace, exact count + stacks, craftable y/n, recent trend). On the console, show the same read-only block above the quota editor so Browse doubles as a lookup tool. Keep lookup visually distinct from tap-to-manage. Mirror.

### CRAFT — Autocrafting management & job truth

> CRAFT-1/2 need a **live RS Bridge** to confirm the `getCraftingTasks` / `craftItem`
> return shapes (patterns DO exist — crafting is live — but those API shapes are
> unconfirmed from CC). Implement off-CC against a stubbed task-list, mark
> `in-game-verify: pending`. CRAFT-3/4/5/6 are pure-logic and interleave freely.

**CRAFT-3 — Validate quota IDs; flag UNKNOWN-ID on PLAN + editor** · M · low · deps: none
- *What:* On `scan` build a name set from `getItems` (the ~5.9k stored rows — the ONLY trustworthy signal; do **NOT** use `getCraftableItems`/`isCraftable`, which read empty even for items that craft fine — see §1). In the editor and on PLAN distinguish UNKNOWN ID (not in grid — likely typo/version drift) from OK (present in grid). Add a PLAN header count: `Quotas: 48 (3 unknown IDs)`. Mirror.
- *Why:* `effectiveCraftTo`/`managed.set` never validate the ID; a typo'd preset ID silently never crafts and is invisible today. Presence-in-grid is the only reliable check given the blind craftability export.

**CRAFT-4 — Patterns worklist + ID export to kill setup toil** · M · low · deps: CRAFT-3
- *What:* A page (or QUEUE section) listing every managed quota lacking a pattern, grouped by category, with the exact registry name + a recipe hint, plus a `dump IDs` action writing the list to a file so the operator can `/give` + build Crafters in one pass. Auto-check items off as `isCraftable` flips true. Mirror.
- *Why:* The manual per-item pattern build is the costliest user task with zero tooling. A finite, shrinking checklist turns "set up Crafters" into a concrete to-do.

**CRAFT-5 — Split `maxCraftsPerCycle` into per-category/overflow budgets** · M · med · deps: none
- *What:* In `atm10-stockplan.lua`/`processCraftQueue` replace the single global `maxCraftsPerCycle` with reserved slots: a budget for high-value categories (alloys/essences), a separate budget for compress/overflow rows, a remainder for general refills — round-robin across categories within the total cap rather than pure global deficit sort. Mirror lib⇄root.
- *Why:* With ~50+ late-game quotas a dust-refill flood can starve a below-floor alloy, and compress rows compete for the same 8 slots.

**CRAFT-6 — Smart-mode `craftTo` cooldown-consistent + compress suggestions + re-surface dismissals** · M · med · deps: none
- *What:* In `atm10-suggest.lua`: compute suggested `craftTo` from observed `perMin` drain × `cooldownSeconds` (refill lasts until the next allowed craft) instead of arbitrary `perMin*5`; add a "compress chain" suggestion kind when an item grows past a stable band (pre-seed ceiling+into+ratio); let a dismissed suggestion re-surface if drain materially accelerates. Mirror lib⇄root.

**CRAFT-1 — Probe + confirm the RS crafting-task API shape** · S · high · deps: none · **IN-GAME (live bridge)**
- *What:* Extend `atm10-bridge-probe.lua` to probe `getCraftingTasks` / `isItemCrafting` (with amounts) / per-task progress and dump exact return shapes to a file. Recon-only, throttled. Patterns exist (crafting is live), so request a known-craftable item (e.g. vibrant alloy) and capture the real shapes.
- *Acceptance:* The probe code compiles via `tests/run.lua`. IN-GAME: probe output records the actual return shapes (or notes absence). **in-game-verify: pending.**

**CRAFT-2 — Reconcile CRAFTING entries against real RS tasks; show made/requested + ETA** · M · high · deps: CRAFT-1
- *What:* Using CRAFT-1's confirmed shape, read RS tasks (throttled like `bridgeStats`) and reconcile CRAFTING queue entries: show `made X / requested Y`, a simple ETA from observed throughput, and drop a CRAFTING entry the instant RS reports the task gone (instead of the 30-min prune). Mirror. Unit tests with a stubbed task-list bridge.
- *Why:* Turns the queue from "what I asked for" into "what is actually happening." The throttle is load-bearing for TPS. **in-game-verify: pending.**

### CTRL — Control foundation (minimal, staged)

> The repo already *designed* a general control system — `lib/atm10-control.lua` defines
> `CAPABILITY_REDSTONE/EXPORT/SECURITY` + `allowRedstone/allowExport/allowSecurity` gates,
> and `docs/CONTROL_ARCHITECTURE.md` describes a sensors→state→rules→trusted-controller model
> with an (empty) `dashboard/` host. Today **nothing outside the lib consumes any of it** —
> the only actuation anywhere is QUICK-3's one-way alarm. These three tasks turn that
> scaffolding into one working, gated, testable control path without committing to wiring
> every machine. **Build for multi-user from the start: gate every action; never actuate on
> an offline or unauthorized path.**

**CTRL-1 — Trusted-controller command schema + dispatcher (pure-logic, gated)** · M · med · deps: none
- *What:* In `lib/atm10-control.lua` (mirror root `atm10-control.lua`) add a pure command model:
  a `command` shape `{action, target, args, token}` and `dispatch(cmd, caps, actuator)` that
  validates the action against the capability gates (`allowRedstone` etc.), rejects unknown
  actions / missing capability / bad token, and on success calls the injected `actuator`
  callback — **never touches a peripheral directly** (so it's unit-testable, no I/O).
- *Why:* One safe, validated entry point for every future control action — the foundation the
  control center needs and the place to enforce authorization for multi-user use.
- *Files:* `lib/atm10-control.lua`, `atm10-control.lua`, `tests/run.lua`
- *Acceptance:* Unit tests: dispatch rejects an action whose capability is off / an unknown action /
  a bad token (actuator called 0 times); accepts a permitted action (actuator called once with the
  right target). `lua tests/run.lua` pass; mirror identical.

**CTRL-2 — Rednet command channel with sender allowlist + token** · M · med · deps: CTRL-1
- *What:* A thin transport: a `control` rednet protocol where the actuator host receives `command`
  messages, checks the sender ID against a config allowlist + a shared token, and feeds valid ones
  to CTRL-1's `dispatch`. Bounded + throttled, no unbounded state. Allowlist + token live in
  `inventory-config.lua`. Mirror per role.
- *Why:* The wire that lets a screen/computer issue gated actions to the actuator host. Allowlist +
  token keep it safe when others use the base.
- *Acceptance:* Unit test with a stubbed rednet: a message from an allowlisted sender + good token
  dispatches; a non-allowlisted sender or bad token is dropped (dispatch not called). Tests pass;
  mirror identical.

**CTRL-3 — One real redstone toggle end-to-end** · S · med · deps: CTRL-2 · **IN-GAME**
- *What:* Wire CTRL-1's actuator callback to `redstone.setOutput` on a configured side for a single
  `redstone_toggle` action, exposed as one button on a screen (or a `control` CLI command).
  Config-driven side + enable, gated by `allowRedstone`. Mirror.
- *Why:* The smallest end-to-end proof of the control center: tap → gated dispatch → real redstone
  output. Turns the dead capability scaffolding into a working feature.
- *Acceptance:* Unit test: the toggle drives a stubbed `redstone.setOutput` with the configured
  side/level **only** when `allowRedstone` is true. Tests pass; mirror identical. **in-game-verify: pending** (real redstone).

---

## 5. Recommended sequencing

Reordered for the operator's stated priorities (2026-06-25 review): **reliability +
control + autocraft-truth first**; the external viewer is wanted but secondary (the
in-game grid covers ad-hoc lookups); UI polish is last. Lead each workstream with behavior
the operator can *feel*; let invisible test-only tasks ride behind the fix they pin.

1. **Tier 1 — Reliability bones:** STAB-2 → STAB-4 → STAB-5 → STAB-1 (pins STAB-2) →
   STAB-3 → STAB-7. (STAB-6 already done.)
2. **Tier 2 — Autocraft truth** (unblocked — crafting is live): QUICK-5 → CRAFT-3 →
   CRAFT-1 (in-game probe) → CRAFT-2 (in-game-verify).
3. **Tier 3 — Control foundation** (minimal, staged): CTRL-1 → CTRL-2 → CTRL-3 (in-game).
4. **Tier 4 — External viewer:** VIEW-1 → VIEW-2 → VIEW-3; VIEW-5 branches off VIEW-1.
5. **Tier 5 — Polish & power:** QUICK-2 → UI-1 (flicker kill) → QUICK-1 → QUICK-4 →
   QUICK-6 → CRAFT-5 → CRAFT-6 → UI-2 → CRAFT-4 → VIEW-4 → VIEW-6 → UI-3 → UI-5 →
   UI-4 → QUICK-3 → PWR-1.

**Guiding rules:** never let an in-game-blocked task stall the loop — skip to the next
pure-code task. **Mirror-pair diff is a HARD gate every iteration.** Decide
wire-in-or-delete for the dead `atm10-draw.lua` double-buffer by the time UI-1 lands
(don't leave it as cruft on the ~1MB disk). Build for multi-user from the start: gate
every control action.

---

## 6. Per-iteration checklist (paste into each loop)

```
1. Read the task + the current code for the files it names (some STAB work is already done).
2. Implement on BOTH halves of every mirror pair you touch.
3. Gate:
   lua tests/run.lua          # 361+ passed, 0 failed
   lua tests/smoke.lua        # SMOKE OK
   lua tests/smoke_auto.lua   # SMOKE-AUTO OK
   lua tests/smoke_probe.lua  # SMOKE-PROBE OK (runtime-executes the power probe loop)
4. Mirror check (must be identical):
   diff -q lib/atm10-X.lua atm10-X.lua        (for each lib touched)
   diff -q inventory/manager.lua inventory-info.lua
   diff -q inventory/remote.lua inventory-remote.lua
   diff -q inventory/manager-startup.lua inventory-startup.lua
   diff -q power/display.lua power-display.lua
   diff -q power/probe.lua power-probe.lua
5. Commit:  "<ID>: <what>"  + "mirror: verified identical"  + "in-game-verify: <yes|pending|n/a>"
6. Push.  Then next task.
Stop after two failed attempts on the same task and report.
```
