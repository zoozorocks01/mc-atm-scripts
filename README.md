# MC ATM Scripts

ComputerCraft/CC:Tweaked scripts for ATM10 base automation.

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

The current scripts still work independently. These modules are installed by
the updater so future power, inventory, machine, and security systems can share
one display/control language. See `docs/CONTROL_ARCHITECTURE.md` for the
safety model.

Canonical source now lives in folders:

- `power/`
- `inventory/`
- `lib/`
- `dashboard/`
- `docs/`

Root-level scripts remain as compatibility mirrors for older in-game updaters.
See `docs/REPO_STRUCTURE.md` before moving or deleting root files.

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
- Display tuning lives at the top of `power-display.lua`: `TEXT_SCALE`, `SHOW_NET_GRAPH`, `SHOW_STORED_GRAPH`, warning thresholds, and history length.

## Inventory Manager

Dry-run RS Bridge inventory manager. It shows bridge/grid status, item storage
usage when available, RS energy/usage, watched low-stock items, top stored
items, category summaries, and a stock keeper plan.

The source inventory computer is the manager. It reads the RS Bridge, plans
stock actions from `inventory-config`, and broadcasts a compact snapshot to
remote display computers over the `atm10-inventory-v1` rednet protocol.
Remote displays are read-only mirrors.

This build does not trigger autocrafting. `WOULD CRAFT` means the planner found
a deficit and craftable pattern, but no `craftItem` call is made.

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
