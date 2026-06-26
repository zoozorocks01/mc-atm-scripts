# Machine integration plan — MI + Mekanism → autocrafting + base control

How to connect Modern Industrialization (MI) and Mekanism machines so the system
(1) **autocrafts** through them (dust/ingot/alloy/component chains) and (2) eventually
**controls** them from the CC control center. Written 2026-06-26; execute in stages,
verify each before scaling.

Two independent tracks — do them in parallel or one at a time.

---

## Track A — Autocrafting THROUGH machines (RS processing patterns)

Goal: RS pushes inputs into a machine and pulls the result back, so machine recipes
(ingot→dust, dust→ingot, alloys, MI components) become `WOULD CRAFT` on the PLAN page.

### Physical wiring (per machine)
1. Run **RS network cable** to the machine cluster.
2. Put an **RS Autocrafter** on the machine's **input** side (or pipe its output into
   the machine input). It holds the processing pattern + exports the inputs.
3. Put **External Storage** (or an Importer) on the machine's **output** side → results
   flow back into the RS network.
4. Make sure the chunk is **force-loaded** (FTB Chunks) — same stability rule as the
   manager; an unloaded chunk also risks the AP crash.

So one machine = Autocrafter-on-input + External-Storage-on-output. RS has no machine
"registry" — this physical pair *is* how RS knows where the machine is.

### Patterns (the software)
- Machine recipes need **PROCESSING patterns** (explicit inputs→outputs), NOT the
  crafting-grid format. **These are not yet hand-authorable** — see
  `docs/RS_PATTERN_SPAWNING.md` §"Processing patterns".
- **Unblock step (in-game, one-time):** make ONE processing pattern in-world (e.g.
  `copper dust → copper ingot` via an RS Pattern Grid / the Autocrafter UI), then read
  its exact NBT (`/data get` the held item). That captures the real `pattern_state.type`
  + inputs/outputs shape. Once we have that reference, CRAFT-4 can clone it for every
  other material by swapping item ids — same as the block patterns.
- Until then: encode processing patterns by hand (Pattern Grid → "Processing" mode →
  set input + output; JEI's `+` helps).

### Rollout
1. Pick ONE machine + ONE metal end-to-end (e.g. tin: dust→ingot in a smelter).
   Wire it, make the pattern, confirm tin ingot flips to `WOULD CRAFT`.
2. Capture that processing pattern's NBT → hand it to CRAFT-4 work.
3. Replicate across metals (dust↔ingot, tiny-dust↔dust), then MI components
   (circuits, motors, wires) and Mekanism alloys (infused/reinforced/atomic).
4. Re-run `atm10-patterns` after each batch — the worklist shrinks; it's your tracker.

---

## Track B — CONTROLLING machines (the control center)

Goal: turn machines on/off (and later more) from the CC control center. The pipeline
is already proven end-to-end (CTRL-1/2/3 — a command lit a redstone lamp on computer 6).

### Physical wiring (per machine)
1. Machines respect **redstone control** — set each machine to "active on signal" (or
   "active without signal" for an off-switch). MI + Mekanism both have a redstone-control
   mode in their GUI/config.
2. Run a **redstone signal** from a CC-controlled output to that machine's control input.
   Options as it scales: a redstone output side per machine cluster from a small CC
   computer, or a bundled-cable / redstone-integrator so one computer drives many lines.

### Commands (the software — extends what already works)
1. Add each controllable thing to `control.COMMANDS` in `lib/atm10-control.lua`
   (currently: `redstone_set`, `redstone_toggle`). e.g. `pause_smelter`, `enable_macerator`
   — each mapped to a capability (start with `redstone`).
2. The actuator already exists (`control.redstoneActuator` → `rs.setOutput`). New
   machine = new command name + the side it drives.
3. Send commands from any allowlisted computer (CTRL-2 `handleMessage`: token + sender
   allowlist — already built; lock it down with `controlToken`/`controlAllowedSenders`).

### Rollout
1. Re-use tonight's lamp wiring: point that redstone line at a real machine's control
   input → toggle it on/off from a sender computer. (Same command, real target.)
2. Add a 2nd and 3rd machine (more sides / a bundled cable).
3. Build a **control SCREEN** (touch buttons → toggles) on a monitor — a small CTRL UI,
   separate from the manager so it doesn't add to the manager's locals cap.
4. Later: feed machine/power **state back** as readouts (sensors → the control center),
   converging power + inventory + autocraft + machine control into the (currently empty)
   `dashboard/` host = one control room.

---

## Sequencing suggestion
1. **Track A first metal** (tin dust↔ingot) — proves machine autocraft + gives the
   reference processing pattern that unblocks CRAFT-4 pattern-emission.
2. **Track B first machine** (repoint the lamp line at a real machine) — proves machine
   control with zero new code.
3. Then scale both, guided by `atm10-patterns` (A) and `control.COMMANDS` (B).

## Hard rules (don't regress)
- Force-load every CC/machine chunk involved in crafting.
- On the manager, restart with `startup` (program restart), never `reboot` — a reboot
  detaches the bridge and can crash the server (happened twice 2026-06-26).
- Gate every control action (capability + token + sender allowlist). Build for multi-user.
- Keep the manager's main-chunk locals well under ~185 (CC's Lua cap; bundle into tables).
