# ATM10 Control Architecture

This repo is moving toward a shared base-control system. The rule is:

```text
sensors -> state -> rules -> optional planner -> trusted controller outputs
```

Displays are renderers. They show state and planned actions, but they do not
perform actions.

## Current Systems

- `power-probe` reads Mekanism induction data and broadcasts power state.
- `power-display` renders the power dashboard.
- `inventory-info` reads the RS Bridge, shows inventory, and builds dry-run
  stock keeper plans.
- `inventory-remote` renders inventory snapshots from the source computer.

## Baseline Modules

- `atm10-status` defines shared status names, glyphs, colors, and tallies.
- `atm10-palette` applies the shared monitor color palette.
- `atm10-draw` provides bars, gauges, panel boxes, and a diff-buffer renderer.
- `atm10-control` describes proposed actions and gates execution modes.

The current scripts do not depend on these modules yet. They are the baseline
for the next migration pass.

## Control Modes

Every system that can affect the base should use one of these modes:

- `monitor`: read-only; show state only.
- `dry-run`: compute what would happen; never execute.
- `manual`: compute actions, require local approval before execution.
- `auto`: execute enabled actions without approval.

Default mode for new control systems should be `dry-run` or `monitor`.

## Safety Rules

- Displays and remote monitors never execute actions.
- Rednet messages never directly execute actions.
- A trusted controller is the only computer allowed to execute actions.
- Every real output must have a label, type, target, mode, and enabled flag.
- Every real output starts disabled until explicitly configured.
- Automation requires hysteresis/cooldowns when toggling redstone or machines.
- Security/defense outputs stay architecture-only until explicitly built later.

## Future Output Types

Inventory:

- RS autocrafting request.
- Export exact item quantities to a chest.
- Stage exact machine recipe batches.

Power:

- Enable emergency generators.
- Disable nonessential machine branches.
- Pause high-draw machines.
- Request low-power lighting mode.

Utilities:

- Alarm lights.
- Base lighting modes.
- Door/lockdown outputs.

Security, later:

- Detection zones.
- Lockdown mode.
- Defense outputs. These require stricter manual arming and emergency disarm.

## Inventory Rule

Viewer can show anything. Manager only manages explicitly configured items.

Unlisted items are unmanaged by default. `listedItems` are display-only.
Only items under `stockKeeper.categories[].items` enter the stock planner.

## Next Implementation Steps

1. Convert `inventory-info` drawing to use `atm10-status` and `atm10-draw`.
2. Convert `inventory-remote` to the same renderer style.
3. Convert `power-display` to shared status and drawing helpers.
4. Add display profiles: `wall`, `remote`, `terminal`, `debug`, `alerts`.
5. Add a control-room monitor host after the old displays are stable.
