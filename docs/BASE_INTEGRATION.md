# Base Integration — toward a full base control surface

How the CC system grows from "inventory manager + power dashboard + one redstone
toggle" into a **base control center**: machines wired for autocraft and control, a
dedicated control screen, and eventually one converged control room.

> **This doc EXTENDS, does not duplicate, `docs/MACHINE_INTEGRATION_PLAN.md`.**
> That doc owns the per-machine physical wiring + the two tracks (A: autocraft
> through machines, B: control machines). Read it first. This doc adds: the
> base-layout understanding from live recon, the open questions the operator must
> answer, and a staged path that sequences both tracks against the real hardware.

---

## 1. Base layout — what's actually on the network

> ⚠️ **Recon freshness (round-2, 2026-06-26): this pass did NOT read the live base.**
> SSH to `zjn-home-two` failed — the 1Password ED25519 agent was locked
> ("communication with agent failed; Permission denied"). Per the hard rules SSH is
> best-effort, so this section is **from repo files + the `base-recon-findings` memory
> (point-in-time 2026-06-24/25)**, NOT a fresh live read. RS-network figures, mid-craft
> state, and "control proven" claims are from that earlier snapshot. Re-verify on the
> next unlocked pass (read-only: the five `.atm10-*` files under
> `computercraft/computer/6/` + the latest server log tail).

Inferred from the 2026-06-24/25 live recon (read-only SSH; computer disks + RS probe)
and the repo mirror of computer 6's deployed scripts.

### Computers

| Computer | Role | Evidence / notes |
|---|---|---|
| **6** | **Manager** (the autocraft console) | `.atm10-role`=inventory-source; RS bridge on `bottom` (type `rs_bridge`, probe-confirmed). Single-threaded event loop. This is the chunk that MUST stay force-loaded. |
| 4 / 5 / 7 / 8 | Viewers + power dashboard (probe+display) | Full script sets, updated together; likely the read-only viewers and the 2-computer power pair. |
| 1 / 2 / 3 | Older / minimal | Pre-existing, minimal scripts. Candidates to repurpose for a CTRL host or a control screen (keeps load off the manager). |

### RS network

- **~5,887 stored item types** (probe count; older export said ~5,883). Item shape is
  `{ name, count, displayName, isCraftable, components, fingerprint, maxStackSize,
  tags }` — **use `.count`, not `.amount`.** Bridge exposes the RS 2.0 NeoForge API:
  `getItems`/`getItem`/`craftItem`/`exportItem`/`importItem`/`isCrafting`/
  `isConnected`/`isOnline`/`getPatterns` present.
- **Craftability signal caveat:** `getCraftableItems` returned **29** and
  `item.isCraftable` is true only for those — but the queue crafts items NOT in that
  29-set, so `isCraftable`/`getCraftableItems` are **NOT a trustworthy craftability
  signal** (RS 2.0 stores patterns as data-components the export reads blind). The only
  reliable signals are **presence in the `getItems` grid** and **`ok=true` rows in
  `.atm10-craft-results`**.
- **`getMaxItemDiskStorage` ABSENT** → storage-headroom readouts (VIEW/QUICK-6) MUST
  use the documented fallback (type count + total amount), never assume the method.
- **`getCraftingTasks` present but returns 0 entries** even with 13 items mid-craft;
  `isItemCrafting` ABSENT; `getCraftingTask` errors without an arg. The ONLY working
  crafting-progress signal is **`isCrafting({name=...})`** (boolean). This bounds
  CRAFT-2: present/absent reconciliation only — no made/requested counts or per-task
  ETA from RS on this build (`refinedstorage-neoforge 2.x`).
- `getStoredEnergy`=50000 is the **bridge's own buffer**, not base power.

### Deployed config reality (round-2 finding — the single biggest gap)

- **The deployed `inventory-config.lua` on computer 6 is a small hand-written set, NOT
  the late-game spec.** ~13 quota items (Base / Mekanism / MystAgri / MI),
  `mode = "manual"`, `stockKeeper` on, `cooldownSeconds = 300`,
  `maxCraftsPerCycle = 8`, `overflowReserve = 0`, `maxRequest = 65536`. **NO compress
  chains, NO 264k dust bands, NO ceiling/into/ratio overflow rules, no metals beyond
  iron/gold/quartz/redstone.** The banded balancer the docs + `late-game-spec` memory
  describe is the **`zoozo-late-game` preset** (`lib/atm10-presets.lua`), which must be
  **explicitly applied on the console** and **has not been**. See `AUTOMATION_PLAN.md`
  for the deployed-vs-documented and three-source-of-truth detail.

### Crafting state at recon (2026-06-24/25 snapshot — `in-game-pending`)

- Crafting was **live and stable** at the snapshot: ~13 items mid-craft, heartbeat
  fresh, no `NotAttachedException` in the spot log tail. Mode was **manual + smart**
  (operator approves; smart mode records trends in a ~146KB `.atm10-trends`, within the
  ~150KB bound). First proven live craft: `enderio:vibrant_alloy_ingot` (2026-06-24).
  The Ultra Autocrafter referenced in recon sits at world coords **~1128, 72, 2660**
  (re-confirm location + hosted patterns on the next unlocked pass).

### Control surface today

- ⚠️ **Track B is proven in a TEST config, NOT enabled in the live config**
  (round-2 finding #4). The actuator (`control.redstoneActuator` → `rs.setOutput`),
  command schema, capability gates, and the rednet channel with sender-allowlist +
  token all exist in code, and a `control` command reportedly lit a redstone lamp on
  computer 6. **But the deployed `inventory-config.lua` has NO `controlEnabled` /
  `allowRedstone` / `controlToken` / `controlAllowedSenders` keys at all** — they exist
  only in `inventory-config-example.lua`, all OFF/nil. With `controlEnabled` absent
  (falsy), **computer 6 cannot accept an `atm10-control` rednet command today.** So the
  lamp test was either a one-off with a temporarily edited config, or the "proven
  end-to-end on the live computer 6" framing overstates the deployed state. Treat it as
  **proven in a test config; not enabled live.** Stage 0 remaining work = enable the
  control keys + lock down the token/allowlist (operator Q5).
- Power-side QUICK-3 alarm (latching redstone + speaker on CRITICAL/STALE) is live
  (commit `bc7f611`).
- **`dashboard/` host is still empty** — the eventual one-room convergence target.

---

## 2. Operator open questions (need answers before scaling)

These gate the staged path; the agent cannot answer them off-CC.

1. **Reference processing pattern.** Will the operator make ONE dust→ingot
   processing pattern in-world so its NBT can be captured? This single in-game step
   unblocks the entire BLOCKED autocraft tier (alloys, MI metals, circuits). Without
   it, Track A cannot scale past crafting-grid recipes. *(See RS_PATTERN_SPAWNING §Processing.)*
2. **Which machines first, and where?** MACHINE_INTEGRATION names tin dust↔ingot
   (Track A) and "repoint the lamp line at a real machine" (Track B). Which physical
   machine cluster, on which side, driven from which computer? Needs the operator's
   in-world layout.
3. **Redstone fan-out strategy.** As control scales: one redstone side per cluster
   from a small CC computer, or a bundled-cable / redstone-integrator so one
   computer drives many lines? Affects how many computers and which command→side map.
4. **Control host placement.** Put the CTRL actuator + control screen on a *separate*
   computer (1/2/3 are candidates), NOT the manager — the manager is at 186 top-level
   locals (over the 185 cap) and is the fragile force-loaded chunk. Confirm a free
   computer + monitor for the control UI.
5. **Multi-user policy.** Who may issue control commands? The allowlist + token exist
   (`controlAllowedSenders` / `controlToken` in config) but are not locked down.
   Operator must set the trusted sender IDs + token before the channel is real.
6. **State feedback scope.** Eventually feed machine on/off + power + autocraft state
   back to one screen. Which sensors/readouts matter first (machine running y/n,
   per-cluster power draw, queue depth)?

---

## 3. Staged path to full base integration

Each stage is independently useful and verifiable. A/B refer to MACHINE_INTEGRATION
tracks. **In-game steps are gated on operator availability and force-loaded chunks.**

### Stage 0 — Foundations (partly DONE; control NOT live yet)

- Manager autocraft live; power dashboard live; QUICK-3 power alarm live.
- CTRL-1/2/3 proven **in a test config** (gated dispatch → rednet channel → redstone
  lamp), but **control is NOT enabled in the deployed config** (finding #4).
- **Remaining Stage 0 work (the real blocker, not just hygiene):**
  - **Enable control on computer 6:** add `controlEnabled = true` + `allowRedstone =
    true` to the live `inventory-config.lua` (absent today → control commands are
    silently rejected), then **lock down `controlAllowedSenders` + `controlToken`**
    (Q5). Without this the channel is not real.
  - **Deploy the late-game config** if/when the operator wants banding: apply the
    `zoozo-late-game` preset (flips smart mode on) + the dust-floor and namespace fixes
    (see `AUTOMATION_PLAN.md`). The live config is the ~13-item hand-written set today.

### Stage 1 — First machine, both tracks (proves the model)

- **A:** Wire ONE machine + ONE metal end-to-end (tin dust→ingot in a smelter):
  Autocrafter-on-input + External-Storage-on-output, force-loaded. Confirm tin ingot
  flips to `WOULD CRAFT`. **Capture the processing pattern's NBT** (Q1) — this is the
  keystone deliverable.
- **B:** Repoint the existing lamp redstone line at that machine's control input →
  toggle it on/off from an allowlisted sender. Same command, real target, zero new code.
- *Exit:* one machine autocrafts AND is remotely toggleable; one reference processing
  pattern captured.

### Stage 2 — Tooling catches up (off-CC, pure code)

- **CRAFT-3** (validate quota IDs against the `getItems` grid; UNKNOWN vs present).
- **CRAFT-4** (patterns worklist + ID export; clone the captured processing pattern
  across metals/alloys by swapping ids — same as the block patterns).
- **CRAFT-5** (per-category/overflow budgets so the metal-dust flood can't starve
  alloys/essences/compress rows).
- *Exit:* a shrinking, grouped worklist that turns "set up Crafters" into a checklist;
  the planner schedules fairly across ~70 quotas.

### Stage 3 — Scale autocraft (Track A across categories)

- Replicate processing patterns: remaining metal dust↔ingot, then EnderIO + Mekanism
  alloys, then Mekanism circuits (depend on alloys), then MA essences (pure grid).
- Re-run `atm10-patterns` after each batch (live tracker). MI assembler components
  last — some may stay manual.

### Stage 4 — Scale control (Track B) + a dedicated control screen

- Add 2nd/3rd machine control lines (more sides or a bundled cable — Q3).
- Add each controllable thing to `control.COMMANDS` (`pause_smelter`, etc.).
- Build a **CTRL screen** on a free computer + monitor (1/2/3 — Q4): touch buttons →
  gated dispatch → toggles. Kept **separate from the manager** so it adds nothing to
  the manager's locals cap and doesn't touch the fragile force-loaded chunk.

### Stage 5 — Convergence (the control room)

- Feed machine/power/autocraft **state back** as readouts (sensors → control center).
- Populate the empty `dashboard/` host: power + inventory + autocraft + machine
  control on one screen = one control room. Multi-user from the start (every action
  gated by capability + token + sender allowlist).

---

## 4. Hard rules carried from MACHINE_INTEGRATION_PLAN (do not regress)

- **Force-load every CC + machine chunk in any craft path** — an unloaded chunk risks
  the uncatchable AP detach crash (server-thread async; no pcall catches it).
- **On the manager, restart with `startup` (program restart), never `reboot`** — a
  reboot detaches the bridge and can crash the server.
- **Gate every control action** (capability + token + sender allowlist). Build for
  multi-user from day one; never actuate on an offline or unauthorized path.
- **Keep the manager's main-chunk locals well under ~185** (CC's Cobalt counts
  stricter than Lua 5.4) — bundle new state into tables; put new UI/host code on a
  *separate* computer, not the manager.
- **Bound every persisted file** (cap/TTL + `atomicWrite`) — the ~1MB CC disk locked
  up once from an unbounded file.
