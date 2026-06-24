# MC ATM Scripts

ComputerCraft/CC:Tweaked scripts for ATM10 base automation.

Full setup instructions live in
[`docs/INSTALLATION_AND_USE.md`](docs/INSTALLATION_AND_USE.md).

## Updater

Install the updater once:

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
```

Set the computer role once:

```lua
update power-display
update power-probe
update inventory-source
update inventory-remote
```

After that, future updates are just:

```lua
update
reboot
```

## Shared Baseline

The repo now includes shared baseline modules for the next dashboard/control
pass:

- `lib/atm10-status.lua`: common status names, glyphs, colors, and tallies
- `lib/atm10-palette.lua`: shared monitor palettes
- `lib/atm10-draw.lua`: bars, gauges, panel boxes, and diff-buffer rendering
- `lib/atm10-control.lua`: proposed-action records and execution-mode gates
- `lib/atm10-craftrunner.lua`: runs approved craft-queue entries through the gate

These modules are installed locally as `atm10-status.lua`,
`atm10-palette.lua`, `atm10-draw.lua`, and `atm10-control.lua`. Scripts should
require those exact `atm10-*` names.

Inventory displays already use the shared status/draw/palette modules. Future
power, dashboard, machine, and security systems should wire into the same
display/control language. See `docs/CONTROL_ARCHITECTURE.md` for the safety
model.

Canonical source lives in folders:

- `power/`
- `inventory/`
- `lib/`
- `dashboard/`
- `docs/`

Root-level scripts remain as temporary compatibility mirrors for computers still
running the older root-path updater. Do not remove them during normal feature
work; mirror changes to them instead. See `docs/REPO_STRUCTURE.md` for the
migration rule and when the mirrors can be retired.

## UI Theme

Every display applies a shared monitor palette. The default is `controlRoom`;
`amber` and `green` are also built in (see `lib/atm10-palette.lua`).

To change the theme on a computer, edit its `atm10-theme` file:

```lua
edit atm10-theme
```

Put one theme name (`controlRoom`, `amber`, or `green`) on a line and reboot.
The updater installs `atm10-theme` only if it is missing, so your choice
survives future updates; an unknown or missing value falls back to the default.

## Power Dashboard

This setup uses two computers:

- Display computer: modem on `top`, monitor on `right`
- Power computer: modem on `top`, Mekanism induction port on `bottom`

The two ender modems should be on the same private band/color.

The display shows stored energy, input/output, net FE/t, estimated time to
empty/full, status, and history graphs.

### Install on display computer

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
update power-display
reboot
```

### Install on power computer

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
update power-probe
reboot
```

## Notes

- Label the computers with `label set atm10-power-display` and `label set atm10-power-probe`.
- Keep both chunks loaded, or the dashboard can stop updating.
- `startup` is a watchdog wrapper. It reruns the dashboard/probe if the real script crashes or exits.
- This reads total induction matrix input/output. Per-machine top users/producers require Energy Detectors on individual branches.
- Display tuning lives at the top of `power/display.lua`: `TEXT_SCALE`, `SHOW_NET_GRAPH`, `SHOW_STORED_GRAPH`, warning thresholds, and history length.

## Inventory Manager

Dry-run RS Bridge inventory manager. It shows bridge/grid status, item storage
usage when available, RS energy/usage, watched low-stock items, top stored
items, category summaries, and a stock keeper plan.

The source inventory computer is the manager. It reads the RS Bridge, plans
stock actions from `inventory-config`, and broadcasts a compact snapshot to
remote display computers over the `atm10-inventory-v1` rednet protocol.
Remote displays are read-only mirrors.

### Crafting (manual mode)

The manager ships in `manual` mode with the autocraft capability on. It plans
deficits but never crafts on its own: a `WOULD CRAFT` row on the console Plan
page is tappable, and tapping it **approves** that craft into the queue. A gated
runner then issues exactly one RS `craftItem` request per approval and moves the
entry to `CRAFTING`; it is dropped once stock recovers. Cancel a pending
approval by tapping its row on the Queue page. To approve every deficit at once,
tap **[APPROVE ALL]** on the Plan page; **[CLEAR QUEUE]** on the Queue page
cancels all approvals.

Modes (config `mode`): `monitor` and `dry-run` never craft; `manual` requires
your approval per item; `auto` **maintains quotas hands-free** — it auto-approves
every craftable deficit (refill *and* overflow/compress) and crafts it, so set
your quotas, switch to `auto`, and walk away. All modes are still rate-limited by
`stockKeeper.maxCraftsPerCycle` (bridge requests per cycle) and the per-item
`cooldownSeconds`, so `auto` drains a backlog steadily instead of flooding a
laggy server. Setting `allowAutocraft = false` hard-disables crafting regardless
of mode. Every craft passes the shared safety gate in `lib/atm10-control.lua`
before the runner in `lib/atm10-craftrunner.lua` touches the bridge.

### Console pages

The manager monitor has five tabs (tap a tab, or pulse the page-button redstone
side to cycle): **Plan** (stock-keeper deficits + overflow/compress; paginated;
tap a `WOULD CRAFT` row to approve, or **[APPROVE ALL]**), **Queue**
(approved/in-flight crafts; tap a row to cancel, or **[CLEAR QUEUE]**),
**Browse** (the live grid, paginated, with an ALL/MANAGED
filter; tap an item to set its quota), **Presets** (one-tap quota bundles), and
**Smart** (opt-in quota suggestions). The header shows a tappable mode chip
(monitor / dry-run / manual / auto) and the queue depth. Pages do not auto-rotate
(the console is interactive); use the tabs or the redstone page button.

**Everything reading `NOT CRAFTABLE` is expected until you set up Refined Storage
autocraft patterns** — see "Setting up RS autocrafting" in
[`docs/INSTALLATION_AND_USE.md`](docs/INSTALLATION_AND_USE.md). It is a Minecraft
setup task (Crafters + Patterns), not a script error.

To see exactly what your RS Bridge exposes (method names, the item-table shape,
how many items it reports craftable), run the read-only diagnostic on the manager
computer: `atm10-bridge-probe`. It never crafts or moves anything — it just prints
the bridge's API and saves it to `.atm10-bridge-probe.txt` for sharing.

### Setting quotas from the console (tap-to-manage)

On the **Browse** page, tap any item to open its quota editor — no registry IDs
to type. Pick a **step size** with `[STEP]` (1 → 10 → … → 10000, so big late-game
numbers are reachable), then use `[-]` / `[+]` on each field:

- **TARGET** — floor: craft when stock drops below this.
- **CRAFTTO** — refill up to this.
- **CEILING** — cap: when stock rises above this, *compress* the surplus into a
  denser item (0 = off). Tap `SET INTO`, then tap the target item on the grid;
  set the `x` **ratio** (source units per crafted unit, e.g. 9 ingots → 1 block).
  `CLR OVF` removes the overflow rule.

`SAVE` stores it; `CRAFT` queues a one-off craft; `REMOVE` deletes the quota;
`BACK` exits. Items with a quota show `Q <target>` in the grid. Overflow/compress
crafts appear on the Plan page under the **Overflow** category and approve like
any other craft.

These quotas persist on the computer (`.atm10-managed`) and are **merged into the
planner alongside your hand-edited `inventory-config`** — the config is never
overwritten, and either source (or both) can drive crafting. Having any quota is
enough to start planning even if `stockKeeper.enabled` is false in config.

### Presets

The **Presets** tab offers stage bundles (Early / Mid / Late / Mega Late) defined
in `lib/atm10-presets.lua`. Tap one to apply its stock targets in a single step
(they merge into the managed quotas). Preset item IDs are best-effort ATM10
names; anything that doesn't match your pack reads `NOT CRAFTABLE` on the Plan
page — fix it by tapping the real item on Browse. Edit the lib to curate your own.

A profile marked `★` (e.g. `zoozo-late-game`) is a **personal** profile: it can
carry behavior settings (like enabling smart mode) and the full compress chain,
not just floors. Generic presets stay neutral.

### Smart mode (opt-in)

The **Smart** tab is **off by default**. Enable it there, or apply a profile
whose settings turn it on. When on, the manager tracks consumption over time and
suggests **recurring quotas** for items that keep draining — tap a suggestion to
open the editor pre-filled, then SAVE. Nothing is auto-applied; suggestions are
advisory. With smart mode off, the tool behaves exactly as a plain stock manager,
so it stays generic for anyone to use.

The computer needs access to:

- an advanced monitor
- an Advanced Peripherals RS Bridge peripheral, named either `rs_bridge` or `rsBridge`

### Install on inventory computer

Use the updater (it pulls the shared `lib/atm10-*` modules too — a bare `wget` of
just the script will crash on the first `require`):

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
update inventory-source
reboot
```

Low-stock watches and stock keeper settings live in `inventory-config`.
The updater installs that config only if it is missing, so your edited values
are preserved.

Default item handling is unmanaged. Items can be shown in top lists, selected
in `listedItems`, or used as low-stock warnings without becoming stock keeper
targets. Only items explicitly listed under `stockKeeper.categories[].items`
enter the planner.

```lua
itemDefaults = {
  handling = "unmanaged",
}

listedItems = {
  { label = "Nether Stars", name = "minecraft:nether_star" },
}
```

The stock manager is organized by categories:

```lua
stockKeeper = {
  enabled = true,
  categories = {
    {
      label = "Mekanism",
      items = {
        { label = "Infused Alloy", name = "mekanism:alloy_infused", target = 128, craftTo = 256 },
      },
    },
  },
}
```

`target` is the low line. `craftTo` is the planned refill line. `maxRequest`
caps a single planned craft request (default `65536`) and `maxCraftsPerCycle`
caps how many new craft requests fire per cycle (default `8`) — both tuned for
late-game bulk; lower them if a big batch strains your machines. Existing installs
keep their `inventory-config` on update, so `edit inventory-config` to adopt new
defaults. `inventory-config-example` contains a larger Mekanism, Modern
Industrialization, Mystical Agriculture, and RS starter list to copy from.

### Server TPS / performance

The manager is the only computer that polls the RS Bridge; the remote viewers are
push-driven (they read broadcasts, never call the bridge). So the manager's load
is the lever:

- **`refreshSeconds`** (config, default 5, floored at 2) — each scan does one full
  `getItems()` over the whole network, so this is the dominant per-tick cost. If
  `/spark` shows the RS Bridge / peripheral calls as a tick hog, raise it to
  `10`–`15`. Touch input stays responsive regardless (taps redraw from cached data).
- **`maxCraftsPerCycle` / `maxRequest`** — in `auto` mode every cycle can kick off
  up to `maxCraftsPerCycle` RS craft-tree calculations of up to `maxRequest` each,
  which is real RS work. If TPS dips while auto is grinding a big backlog, lower
  these (e.g. `3` / `16384`) — slower fills, lighter server.
- Most ATM10 TPS loss is **not** the computer: profile with `/spark profiler
  --timeout 60` and look at force-loaded chunks, Mekanism/MI machines, mob farms,
  and item/fluid pipes first.

### Install on remote inventory display

Remote displays (viewers) need only an advanced monitor and modem on the same
modem network/band as the inventory source computer.

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
update inventory-remote
reboot
```

Pick which screen a viewer shows with the one-line `atm10-display` file
(`view` / `autocraft` / `alerts`); see the viewer section of the install guide.

## Development

Off-CC tests cover the pure logic in the shared libs and now also execute the
manager itself against a stubbed CC:Tweaked environment. They stub the globals,
so they run anywhere Lua is installed. From the repo root:

```sh
lua tests/run.lua    # pure-logic unit tests + a required-lib guard
lua tests/smoke.lua  # runs inventory/manager.lua end-to-end (scan + every page + touches)
```

`run.lua` only parses the programs (a missing `require`/undefined global is valid
syntax), so `smoke.lua` actually executes the manager's event loop against fake
peripherals to catch runtime bugs that would otherwise only surface in-game. The
tests are dev-only and not distributed by the updater; they still don't exercise
real display rendering or the RS Bridge, which need an in-game check.
