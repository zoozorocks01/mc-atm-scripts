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
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/power/display.lua power-display
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/power/display-startup.lua startup
startup
```

### Install on power computer

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/power/probe.lua power-probe
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/power/probe-startup.lua startup
startup
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
approval by tapping its row on the Queue page.

Modes (config `mode`): `monitor` and `dry-run` never craft; `manual` requires
your approval per item; `auto` crafts approved deficits unattended. Setting
`allowAutocraft = false` hard-disables crafting regardless of mode. Every craft
passes the shared safety gate in `lib/atm10-control.lua` before the runner in
`lib/atm10-craftrunner.lua` touches the bridge.

### Console pages

The manager monitor has three tabs (tap a tab, or pulse the page-button
redstone side to cycle): **Plan** (stock-keeper deficits; tap a `WOULD CRAFT`
row to approve), **Queue** (approved/in-flight crafts; tap a row to cancel), and
**Browse** (the live grid, paginated). Plan and Queue auto-rotate; Browse is
manual only.

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

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/inventory/manager.lua inventory-info
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/inventory/manager-startup.lua startup
label set atm10-inventory-info
startup
```

Low-stock watches and stock keeper dry-run settings live in `inventory-config`.
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
caps a single planned craft request. `inventory-config-example` contains a
larger Mekanism, Modern Industrialization, Mystical Agriculture, and RS starter
list to copy from.

### Install on remote inventory display

Remote displays need only an advanced monitor and modem on the same modem
network/band as the inventory source computer.

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/inventory/remote.lua inventory-remote
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/inventory/remote-startup.lua startup
label set atm10-inventory-remote
startup
```

## Development

Off-CC unit tests cover the pure logic in the shared libs (the control-mode
safety gate, the theme resolver, and the status vocabulary). They stub the
CC:Tweaked globals, so they run anywhere Lua is installed. From the repo root:

```sh
lua tests/run.lua
```

The tests are dev-only and are not distributed by the updater. They do not
exercise display rendering or the RS Bridge, which still need an in-game check.
