# MC ATM Scripts

ComputerCraft/CC:Tweaked scripts for ATM10 base automation.

## Power Dashboard

This setup uses two computers:

- Display computer: modem on `top`, monitor on `right`
- Power computer: modem on `top`, Mekanism induction port on `bottom`

The two ender modems should be on the same private band/color.

The display shows stored energy, input/output, net FE/t, estimated time to
empty/full, status, and history graphs.

### Install on display computer

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/power-display.lua power-display
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/display-startup.lua startup
startup
```

### Install on power computer

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/power-probe.lua power-probe
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/probe-startup.lua startup
startup
```

## Notes

- Label the computers with `label set atm10-power-display` and `label set atm10-power-probe`.
- Keep both chunks loaded, or the dashboard can stop updating.
- `startup` is a watchdog wrapper. It reruns the dashboard/probe if the real script crashes or exits.
- This reads total induction matrix input/output. Per-machine top users/producers require Energy Detectors on individual branches.
- Display tuning lives at the top of `power-display.lua`: `TEXT_SCALE`, `SHOW_NET_GRAPH`, `SHOW_STORED_GRAPH`, warning thresholds, and history length.

## Inventory Info Dashboard

Read-only RS Bridge dashboard. It shows bridge/grid status, item storage usage
when available, RS energy/usage, watched low-stock items, and top stored items.

The computer needs access to:

- an advanced monitor
- an Advanced Peripherals RS Bridge peripheral, named either `rs_bridge` or `rsBridge`

### Install on inventory computer

```lua
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/inventory-info.lua inventory-info
wget https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/inventory-startup.lua startup
label set atm10-inventory-info
startup
```

Low-stock watches live at the top of `inventory-info.lua` in `LOW_STOCK`.
