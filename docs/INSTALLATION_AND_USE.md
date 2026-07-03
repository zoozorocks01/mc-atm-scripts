# ATM10 Scripts Installation And Use Guide

ComputerCraft/CC:Tweaked scripts for an ATM10 base:

- **Inventory manager** — a touchscreen console over a Refined Storage grid (via
  an Advanced Peripherals RS Bridge): stock quotas, a compress/overflow balancer,
  gated autocrafting, presets, and an opt-in smart mode.
- **Inventory remotes (viewers)** — read-only mirror screens, separate from the
  manager (different role / computer).
- **Power dashboard** — a Mekanism induction-matrix monitor.

One updater installs each computer; after that the inventory manager uses
`update` + `atm10-reload`, while other roles still use `update` + `safereboot`.

## What this system can and cannot control

Be clear-eyed about scope:

- **Can control now:** RS **autocrafting** — it calls `craftItem` on the RS
  Bridge to ask Refined Storage to craft an item. That is the only actuator wired.
- **Architected but NOT built:** item **export** (push exact amounts to a chest),
  **redstone** outputs (machines/lights/doors), and **security**. The safety gate
  (`lib/atm10-control.lua`) defines capabilities for these, but no actuator is
  connected. See `docs/CONTROL_ARCHITECTURE.md`.
- **Cannot control:** Modern Industrialization (and other multiblock) machines
  directly — Refined Storage can't drive them without a bridge, so MI-only items
  are kept as monitor/buffer targets, not autocraft.

Everything that isn't "request an RS craft" is, today, a **display/monitor**.

## Control modes (the master safety switch)

Set in `inventory-config` as `mode`:

| Mode | Behavior |
| --- | --- |
| `monitor` | read-only; never crafts |
| `dry-run` | plans deficits; never crafts |
| `manual` | plans, and **you approve each craft** on the console (default) |
| `auto` | crafts approved deficits unattended |

`allowAutocraft = false` hard-disables crafting regardless of mode. Nothing crafts
unless: the mode allows it **and** the capability is on **and** (in manual) you've
approved it **and** RS actually has a pattern for it. Keep `manual` while you set
up patterns.

## Required blocks

**Inventory manager (the console):**

- 1 Advanced Computer
- 1 Advanced Monitor (advanced = color **and** touch; touch is required)
- 1 Advanced Peripherals **RS Bridge** on your Refined Storage network
- 1 modem (only if you want remote mirror screens)

**Inventory remote display:** 1 Advanced Computer + 1 Advanced Monitor + 1 modem
on the same network as the manager.

**Power dashboard:** 1 computer + induction port for the probe; 1 computer +
monitor for the display; a modem on each (same network).

## Wiring

- Place the **monitor** against the manager computer (a 3×2 or larger advanced
  monitor reads well). Right-clicking the monitor in-game **is a touch/tap**.
- Connect the **RS Bridge** to the computer (adjacent, or on the same wired-modem
  network) and to the Refined Storage network.
- Inventory scripts **auto-detect** the monitor, modem, and RS Bridge sides.
- Keep these chunks loaded so screens recover after you leave: computers,
  monitors, modems, RS Bridge, induction port.

Check the computer sees its peripherals:

```lua
lua
for _, n in ipairs(peripheral.getNames()) do print(n, peripheral.getType(n)) end
exit()
```

You should see a `monitor` and an `rs_bridge` (or `rsBridge`).

## Install

On every new computer, once:

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
```

Then the role for that computer:

| Role | Command |
| --- | --- |
| Inventory manager | `update inventory-source` then `atm10-reload` |
| Inventory remote | `update inventory-remote` then `safereboot` |
| Power display | `update power-display` then `safereboot` |
| Power probe | `update power-probe` then `safereboot` |

The role is saved in `.atm10-role`. Future updates on the inventory manager are
`update` then `atm10-reload`; future updates on the remote/power computers are
`update` then `safereboot`. `inventory-config` is only installed if missing, so
your edits survive updates.

One-time bootstrap caveat: the first deploy onto an already-running old
inventory manager may need the old safe stop path once, because that running
program does not yet know how to exit for `atm10-reload`. After that first
reload-capable version is running, use `update` then `atm10-reload`.

## The console (touchscreen tabs)

Right-click the monitor to tap. Tabs (tap a tab, or pulse the page-button
redstone side to cycle):

- **PLAN** — stock deficits and overflow/compress jobs. Tap a `WOULD CRAFT` row
  to approve it into the queue.
- **QUEUE** — approved / in-flight crafts. Tap a row to cancel it.
- **BROWSE** — the live grid, paginated (`[< PREV]` / `[NEXT >]`). Tap any item to
  open its quota editor.
- **PRESETS** — one-tap quota bundles (see below).
- **SMART** — opt-in suggestions (see below).

Pages do not auto-rotate (the console is interactive); switch with the tabs or a
redstone pulse on the page-button side. The header also has a tappable **mode
chip** (monitor / dry-run / manual / auto; switching to auto needs a confirm tap)
and shows the queue depth.

## Quotas (the core idea)

Every managed item has up to three independent lines:

- **TARGET** — the floor: when stock drops below this, craft to refill.
- **CRAFTTO** — refill up to this, then stop. (`TARGET` < `CRAFTTO` gives a
  hysteresis band; `TARGET` = `CRAFTTO` is a hard line.)
- **CEILING** — the max: if stock rises above this, **compress** the surplus into
  a denser item (the `compress into` target) at a `ratio` (e.g. 9 ingots → 1
  block). `0` = no ceiling.

Set quotas three ways:

1. **Browse editor** — tap an item, use `[STEP]` to pick a step size
   (1→10→…→10000), then `[-]/[+]` on TARGET / CRAFTTO / CEILING. `SET INTO` then
   tap the denser item to choose the compress target; set its `x` ratio.
   `SAVE` / `REMOVE` / `CRAFT` (one-off) / `BACK`.
2. **Presets** — apply a bundle (below).
3. **Config** — `stockKeeper.categories[].items` in `inventory-config`.

Quotas you set on the console persist in `.atm10-managed` and **merge with** your
hand-edited `inventory-config` — config is never overwritten.

A compress chain (e.g. dust→ingot→block) is just ceilings: dust has a ceiling that
compresses into ingot, ingot has a ceiling that compresses into block.

## Presets

The **PRESETS** tab applies a bundle of quotas in one tap (they merge into your
managed quotas). Generic stage presets (Early/Mid/Late/Mega) are neutral starting
points. A `★` profile (e.g. **Zoozo Late-Game**) is **personal**: it carries the
full late-game metal chains and turns on smart mode when applied. Preset item IDs
must match your pack; anything that doesn't reads `NOT CRAFTABLE` on PLAN
(harmless) — fix it by tapping the real item on BROWSE. Edit
`lib/atm10-presets.lua` to curate your own.

## Smart mode (opt-in)

The **SMART** tab is **off by default**. Enable it there, or apply a profile that
turns it on. When on, the manager tracks consumption over time and suggests:

- **STOCK** — an unmanaged item that keeps draining → set a recurring quota.
- **RAISE** — a managed item stuck below target while still draining → raise its
  `craftTo`.
- **CAP** — an item that keeps accumulating → set a compress ceiling.

Tap a suggestion to open the editor pre-filled, then SAVE. Nothing is auto-applied.
`CLEAR` dismisses the current suggestions. With smart mode off, the tool is a plain
stock manager — so it stays generic for anyone.

## Setting up RS autocrafting (required before anything crafts)

The script only **requests** crafts; **Refined Storage does the crafting**, and
only for recipes it has a **Pattern** for. If the RS Bridge reports
`craftable_rows = 0` (nothing craftable), it means **RS has no patterns yet** —
that is a Refined Storage setup task, not a script issue.

1. Place a **Crafter** block touching your RS network (a cable or the controller).
2. Make a **Pattern** for each recipe you want auto-made:
   - **Crafting Pattern** (Pattern Grid) for table recipes, e.g. `9 ingot → 1
     block`.
   - **Processing Pattern** for machine recipes (e.g. `dust → ingot` smelting):
     it defines inputs and the expected outputs, and the Crafter pushes inputs
     into the machine and pulls the result back.
3. Put the Pattern(s) into the Crafter.
4. **Connect the Crafter to its machine** for processing patterns: face the
   Crafter at the machine's input (or route with conduits/external-storage so the
   inputs go in and the output returns to the RS network).

The instant a pattern exists, that item becomes craftable: it stops showing
`NOT CRAFTABLE` on PLAN, and `craftItem` can fulfill it.

**Start with one pattern** (e.g. 9 iron → iron block, or zinc dust → zinc ingot)
to validate the loop before building the whole tree. RS resolves dependency
**trees** automatically — if every sub-step has a pattern, requesting the top item
crafts everything beneath it; a missing sub-pattern makes the whole thing
uncraftable.

## Testing the craft loop

With at least one pattern in place and `mode = manual`:

1. On **PLAN**, tap that item's `WOULD CRAFT` row to approve it.
2. Watch the computer terminal for `Craft requested: <item> x<n>`, and confirm RS
   starts crafting.
3. If you see `Craft failed (<reason>)`, the bridge rejected it — note the reason
   (e.g. missing pattern / wrong call shape) and adjust.

Once you trust it, switch the most hands-off items to `mode = auto`.

## Config reference (`inventory-config`)

```lua
edit inventory-config
```

Key fields:

- `mode` — `monitor` / `dry-run` / `manual` / `auto` (default `manual`).
- `allowAutocraft` — `true`/`false`; master craft capability (default `true`).
- `listedItems` — display-only watched items.
- `lowStock` — warning-only thresholds (never craft).
- `stockKeeper.enabled`, `cooldownSeconds`, `maxCraftsPerCycle`,
  `maxBridgeRequest`, `maxRequest`, `overflowReserve`, `manualReserve`,
  `categories[].items[] = { name, label, target, craftTo, maxRequest, craftFrom,
  ceiling, into, ratio, craftMode, blockReason }`.

Machine-written state files (do not hand-edit): `.atm10-managed` (console quotas +
settings), `.atm10-craft-queue`, `.atm10-craft-results`, `.atm10-craftstate`,
`.atm10-stock-ledger`, `.atm10-planstate`, `.atm10-loopstate`, `.atm10-status`.
The `.atm10-status` file is a compact summary for SSH diagnostics and agent
polling; it mirrors the HEALTH page's current mode, bridge, queue, craft, loop,
and demand signals without adding extra RS Bridge calls.

At large quotas, keep the conservative throttle defaults until the read-only
`tools/atm10-diagnostics.sh doctor` check is clean and live queue/craft evidence
stays stable while a backlog drains. `maxRequest` can describe a large desired
deficit, but `maxBridgeRequest` still bounds each RS Bridge call (default `32`) and
`maxCraftsPerCycle` bounds how many new calls start per cycle (default `2`).

Use `craftMode = "watch"` on a stock-keeper item when the buffer should be
tracked but RS should not craft it. This is the right default for Modern
Industrialization assembler/machine outputs and any recipe where a dedicated
machine route is better than an RS crafting pattern. Add `blockReason` so the
PLAN page and `.atm10-planstate` explain the route.

## Power dashboard

Install the two power roles as above. The probe reads the induction port
(`bottom`) and broadcasts; the display (`monitor` on `right`, modem on `top`)
renders stored/in/out/net FE, time-to-full/empty, and history. If input/output
read `0 FE/t`, check the probe is loaded, the modems share a network, and the
induction port is under the probe.

## Inventory remotes (viewers)

These are the read-only **inventory viewers** — a different role/computer from the
manager. They have no RS Bridge and no controls; they wait for the manager's
`atm10-inventory-v1` broadcasts and
draw the latest snapshot. If one waits forever: confirm the manager is running with
a modem, both modems share a band/network, the remote has a monitor, and run
`safereboot`.

### Display profiles (pick what each viewer shows)

Each viewer renders one of three screens, set per computer in a one-line
`atm10-display` file (installed once, survives `update`, like the theme file):

- **`view`** (default) — inventory: item storage bar, RS energy, top stored items.
- **`autocraft`** — category summary, stock-keeper plan, tally, and the craft queue.
- **`alerts`** — errors, stale data, low stock, and craft problems only (a
  glance-able wall board).

```lua
edit atm10-display
```

Put one profile name on a line (`view`, `autocraft`, or `alerts`) and run
`safereboot`; an unknown/missing value falls back to `view`. So one manager can
feed a storage viewer, a crafting-status board, and an alerts board — each its
own computer + monitor.

## Troubleshooting

- **`No such program`** — install the updater and run the role's `update`, then
  `safereboot`.
- **Blank monitor** — run `startup`; if needed `update` then `safereboot`;
  confirm the monitor/bridge chunks are loaded and the monitor is advanced.
- **Can't find RS Bridge** — confirm it's connected to the computer/network and
  typed `rs_bridge`/`rsBridge` (peripheral listing command above).
- **Everything reads `NOT CRAFTABLE` / `craftable_rows=0`** — RS has no patterns;
  set up Crafters + Patterns (see above). Not a script bug.
- **A craft never fires in manual** — did you tap to approve on PLAN? Is `mode`
  manual/auto and `allowAutocraft` true? Does the item have a pattern?
- **Config edit broke the manager** — check commas/braces/quotes; it fails closed.
  Compare against `inventory-config-example`.

## Useful commands

```lua
startup          -- rerun this computer's role
update; atm10-reload -- update/reload the inventory manager without rebooting
update; safereboot   -- update/reboot non-manager roles
update <role>; safereboot   -- change role (inventory-source/-remote/power-*)
```

## Development

Off-CC tests cover the pure libs (planner, balancer, control gate, queue, managed
quotas, suggestions, presets, console hit-testing) and run the manager end-to-end
against a stubbed CC environment. From the repo root:

```sh
lua tests/run.lua    # unit tests + required-lib guard
lua tests/smoke.lua  # executes inventory/manager.lua (scan + every page + touches)
```
