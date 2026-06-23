# ATM10 Scripts Installation And Use Guide

This guide covers the current live systems:

- Power dashboard for a Mekanism induction matrix.
- Inventory source/manager for a Refined Storage grid through an RS Bridge.
- Inventory remote monitors that mirror the inventory source.

The scripts are written for ComputerCraft/CC:Tweaked in ATM10. They use the
repo updater so you only paste one install command per computer, then use
`update` and `reboot` for future changes.

## Current Safety State

The current public build is mostly read-only:

- Power scripts read Mekanism induction data and draw it on monitors.
- Inventory scripts read RS Bridge data, show stock information, and build a
  dry-run stock keeper plan.
- Inventory `WOULD CRAFT` lines are previews only. The current inventory
  manager does not call RS autocrafting.
- Remote inventory monitors are display-only.
- Shared control gates exist for future autocraft/export/redstone/security
  work, but no real actuator is wired yet.

## Required Blocks

Power dashboard:

- 1 advanced computer for the power probe.
- 1 advanced computer for the power display.
- 1 advanced monitor for the display computer.
- 1 modem on each computer, on the same modem network.
- A Mekanism induction port available to the power probe computer.

Inventory manager:

- 1 advanced computer for the inventory source.
- 1 advanced monitor for the source display.
- 1 Advanced Peripherals RS Bridge connected to the Refined Storage grid.
- 1 modem if you want remote inventory monitors.

Inventory remote display:

- 1 advanced computer per remote display.
- 1 advanced monitor per remote display.
- 1 modem on the same modem network as the inventory source.

## Modem And Chunk Setup

All computers that talk to each other must share the same modem network.

If you are using Ender Modems with color/band settings, set the matching
color/band on the modem blocks/items themselves. The scripts do not change
modem bands in Lua.

Keep these chunks loaded if you want the screens to recover cleanly after
everyone leaves the area:

- the computers
- the monitors
- the modems
- the RS Bridge
- the induction matrix or induction port

Each installed computer gets a `startup` watchdog. If the chunk unloads or the
script crashes, the computer should restart the right script on reboot.

## Default Peripheral Sides

Power scripts currently use fixed sides:

- power probe modem: `top`
- power probe induction port: `bottom`
- power display modem: `top`
- power display monitor: `right`

Inventory scripts auto-detect their monitor, modem, and RS Bridge by default.

If you edit side constants inside a downloaded script, remember that `update`
will replace that script. Long-term side/profile customization should move into
config files.

## Role Layout

Use one role per computer.

| Role | Goes On | Needs | Local Program |
| --- | --- | --- | --- |
| `power-probe` | computer at the induction port | modem + Mekanism induction port | `power-probe` |
| `power-display` | monitor computer for power wall | modem + monitor | `power-display` |
| `inventory-source` | main inventory computer | RS Bridge + monitor + optional modem | `inventory-info` |
| `inventory-remote` | inventory mirror display | modem + monitor | `inventory-remote` |

The role is stored in `.atm10-role`, so after the first install that computer
knows what to download when you run `update`.

## First Install

On every new computer, paste this once:

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/atm10-update.lua update
```

Then run the role command for that specific computer.

Power display computer:

```lua
update power-display
reboot
```

Power probe computer:

```lua
update power-probe
reboot
```

Inventory source computer:

```lua
update inventory-source
reboot
```

Inventory remote display computer:

```lua
update inventory-remote
reboot
```

Do not install multiple roles on the same computer unless you intentionally
want to replace its `startup` file.

## Normal Updates

After the first install, future updates on each computer are:

```lua
update
reboot
```

The updater downloads shared libraries first, then the role-specific script,
then a fresh copy of the updater.

For inventory source computers, `inventory-config` is only installed if missing.
Your local edits are preserved by normal updates.

## Power Dashboard Use

The power probe reads the induction peripheral and broadcasts snapshots. The
power display receives those snapshots and renders:

- stored energy
- total capacity
- fill percent
- input FE/t
- output FE/t
- net FE/t
- estimated time to empty or full
- recent history graph
- status line

Current limitations:

- Input and output are total induction matrix values.
- The script cannot show the top 5 power users/producers by itself yet.
- Per-machine or per-branch rankings will need extra sensors, such as energy
  detectors on individual branches.

If the power screen is running but input/output show `0 FE/t`, check:

- the power probe computer is loaded and running
- the modem network is connected
- the induction port is on the bottom of the probe computer
- the Mekanism peripheral exposes input/output values at that moment

Some differences between the monitor and the Mekanism block UI are normal
because the script reads peripheral methods and formats/rounds values for the
wall display.

## Inventory Source Use

The inventory source reads the RS Bridge and renders:

- RS/grid online status
- item storage usage when available
- RS energy and RS usage when available
- low-stock warnings
- top stored items
- category summaries
- dry-run stock keeper plan

The source also broadcasts compact snapshots over `atm10-inventory-v1` for
remote displays.

The inventory source needs an RS Bridge peripheral named or typed as one of:

- `rs_bridge`
- `rsBridge`
- a peripheral whose type is exposed as an RS Bridge by Advanced Peripherals

## Inventory Remote Use

Inventory remotes are read-only mirrors. They wait for broadcasts from the
inventory source and draw the latest snapshot.

If a remote says it is waiting for an inventory source:

- confirm the inventory source computer is running
- confirm both modems are on the same network/band
- confirm the remote has a monitor
- reboot the remote after updating

## Editing Inventory Config

On the inventory source computer:

```lua
edit inventory-config
```

The default rule is unmanaged. Items do not become managed just because they
exist in the RS grid.

Items can be used in three different ways:

- top stored item lists: automatic, display-only
- `listedItems`: selected display/watch items
- `stockKeeper.categories[].items`: dry-run managed stock planner entries

Only `stockKeeper.categories[].items` enter the stock planner.

Example:

```lua
stockKeeper = {
  enabled = true,
  categories = {
    {
      label = "Mekanism",
      items = {
        {
          label = "Infused Alloy",
          name = "mekanism:alloy_infused",
          target = 128,
          craftTo = 256,
          maxRequest = 128,
        },
      },
    },
  },
}
```

Field meanings:

- `label`: text shown on the monitor.
- `name`: exact item id, such as `minecraft:glass`.
- `target`: the low line.
- `craftTo`: the planned refill line.
- `maxRequest`: cap for a single planned craft request.

If an item is below target and craftable, the manager can show `WOULD CRAFT`.
That is still dry-run only in the current build.

## Useful In-Game Commands

Show attached peripherals:

```lua
lua
for _, name in ipairs(peripheral.getNames()) do print(name, peripheral.getType(name)) end
```

Exit the Lua prompt:

```lua
exit()
```

Rerun the current role manually:

```lua
startup
```

Force a fresh update for the current role:

```lua
update
reboot
```

Change a computer to a different role:

```lua
update inventory-remote
reboot
```

Replace `inventory-remote` with the role you want.

## Troubleshooting

`No such program`

- The program has not been downloaded onto that computer yet.
- Install the updater, run the correct `update <role>`, then `reboot`.

Blank monitor after login

- Click the computer and run `reboot`.
- If it still fails, run `update`, then `reboot`.
- Confirm the monitor, modem, and watched peripheral chunks are loaded.

Inventory source cannot find RS Bridge

- Confirm the RS Bridge is connected to the computer or wired network.
- Run the peripheral listing command above.
- Make sure the source computer has the `inventory-source` role.

Inventory remote waits forever

- Confirm the source says it is running and has a modem.
- Confirm source and remote modems share the same band/network.
- Confirm the remote role is `inventory-remote`.

Power display has stale age or old values

- Reboot the power probe computer first.
- Then reboot the power display computer.
- Confirm both modems are on the same network.

Config edit broke inventory source

- Reopen `inventory-config` and check commas, braces, and quotes.
- The source should fail closed to dry-run if config mode is invalid.
- Use `inventory-config-example` as a reference.

## What To Install Next

A practical base layout is:

1. Power probe near the induction port.
2. Power display on the main wall.
3. Inventory source beside the RS Bridge.
4. One inventory remote on the control wall.
5. More inventory remotes wherever they are useful.

Future control systems should follow the same pattern:

- one source/controller computer close to the real peripheral
- any number of display-only remote monitors
- no real action unless the controller gates explicitly allow it
