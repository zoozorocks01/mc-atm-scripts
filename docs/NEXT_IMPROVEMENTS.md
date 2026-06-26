# Next Improvements — ranked backlog (touch / perf / UI / reliability)

A ranked backlog of every touchscreen, performance, UI, and reliability finding from
the recon pass. Ranked by **value ÷ risk/effort**, reliability ahead of polish (per
the operator's stated priority order: reliability → control → autocraft-truth →
viewer → polish).

> **Line numbers are from the recon snapshot.** The repo has since advanced
> (HEAD `bc7f611`); `inventory-info.lua` is at **186** top-level locals (over the 185
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
- **M · value med · risk med · Verify: visual · Phase: discuss**
- One-row, label-width targets: APPROVE ALL (`1331`), CLEAR QUEUE (`1407`), mode chip
  (`1768`), nav arrows, editor `[+]`/`[-]` (`1536-1539`). Coarse cursor → dangerous
  mis-taps (CLEAR QUEUE, mode→auto).
- **Change:** render as bg-filled chips, accept taps across the full painted area,
  widen destructive ones. **CRITICAL:** update the matching region builder
  (`planActionRegion:1332`, `queueActionRegion:1408`, `modeChip:1770`, `*NavRegions`,
  editorRows `1540`) in the SAME edit. Depends on B1 landing first.
- **Pinned:** depends on the buffer; mis-tap behavior is physical (in-game only).

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
| A3 | bridge-degraded chip | S | med | low | gate | pinned (payoff is visual + adds state at local cap) |
| B1 | UI-2 manager double buffer | major | high | high | visual | discuss |
| B2 | shrink touch-block window | M | high | med | gate | Code/discuss |
| C1 | tap flash on Browse/Smart/Presets/editor | S | med | low | gate | Code |
| C2 | notInGrid hoist | S | med | low | gate | DONE (d0cfc86) |
| C3 | UI-4 enlarge tap targets | M | med | med | visual | discuss |
| D1 | power-display double buffer | M | high | med | visual | discuss |
| D2 | box/gauge wire-or-delete | S | med | low | gate | Code |
| D3 | UI-3 header band + chips | M | med | med | visual | discuss |
| D4 | viewer zebra rows | S | med | low | visual | Code |
| D5 | UI-5 empty/too-small panels | M | med | low | gate+visual | Code |
| E1 | pause auto-rotation on interaction | S | low | low | gate | Code/skip |

**Code phase will attempt (gate-provable, ship unattended):** A1, A2, A3, B2 (parts),
C1, C2, D2, D4, D5, E1.

**Pinned major-for-discussion (in-game-visual and/or high-risk):** B1 (manager double
buffer), C3 (tap targets), D1 (power double buffer), D3 (header band). These touch
mirror pairs + hit-regions and their payoff is only verifiable on a live monitor; do
B1 first since C3/D3 depend on it.
