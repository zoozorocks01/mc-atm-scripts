# MC ATM Scripts

ComputerCraft/CC:Tweaked scripts for ATM10 base automation.

## Power Dashboard

This setup uses two computers:

- Display computer: modem on `top`, monitor on `right`
- Power computer: modem on `top`, Mekanism induction port on `bottom`

The two ender modems should be on the same private band/color.

### Install on display computer

```lua
wget https://raw.githubusercontent.com/zoozorocks/mc-atm-scripts/main/power-display.lua startup
startup
```

### Install on power computer

```lua
wget https://raw.githubusercontent.com/zoozorocks/mc-atm-scripts/main/power-probe.lua startup
startup
```

## Notes

- Label the computers with `label set atm10-power-display` and `label set atm10-power-probe`.
- Keep both chunks loaded, or the dashboard can stop updating.
- This reads total induction matrix input/output. Per-machine top users/producers require Energy Detectors on individual branches.
