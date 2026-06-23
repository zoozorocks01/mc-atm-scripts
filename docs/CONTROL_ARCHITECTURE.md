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
- `inventory-info` reads the RS Bridge, shows inventory, builds stock keeper
  plans, and (in `manual`/`auto` mode, capability permitting) executes approved
  crafts through the control gate via `atm10-craftrunner`.
- `inventory-remote` renders inventory snapshots from the source computer.

## Baseline Modules

- `atm10-status` defines shared status names, glyphs, colors, and tallies.
- `atm10-palette` applies the shared monitor color palette.
- `atm10-draw` provides bars, gauges, panel boxes, and a diff-buffer renderer.
- `atm10-control` describes proposed actions and gates execution modes.

The canonical module names are the shipped `atm10-*` names. Use exact requires:

```lua
local status = require("atm10-status")
local palette = require("atm10-palette")
local draw = require("atm10-draw")
local control = require("atm10-control")
```

Do not introduce `draw.lua`, `status.lua`, or `require("draw")` style aliases.
CC:Tweaked `require` is string-exact, and the updater installs these files as
`atm10-status.lua`, `atm10-palette.lua`, `atm10-draw.lua`, and
`atm10-control.lua`.

Inventory source and remote scripts already use the shared status/draw/palette
modules. Power display and future dashboards should wire into the existing
modules instead of creating a second shared layer.

## Control Modes

Every system that can affect the base should use one of these modes:

- `monitor`: read-only; show state only.
- `dry-run`: compute what would happen; never execute.
- `manual`: compute actions, require local approval before execution.
- `auto`: execute enabled actions without approval.

Default mode for new control systems should be `dry-run` or `monitor`.

This is the single mode vocabulary. Do not add a separate `armed` mode.
`armed` is an action-level gate, not a global mode.

## Execution Gates

Any real actuator has to pass every gate below before it can run:

1. Global mode:
   - `monitor` never executes.
   - `dry-run` only returns planned action descriptions.
   - `manual` requires local approval.
   - `auto` may execute after the remaining gates pass.
2. Per-action gates:
   - `enabled = true`
   - `armed = true`
3. Capability policy:
   - `allowAutocraft = true` for RS craft requests.
   - `allowExport = true` for item/fluid export.
   - `allowRedstone = true` for machine, generator, light, alarm, or door
     redstone outputs.
   - `allowSecurity = true` for future defense/security outputs.
4. Trusted command channel, when rednet is involved:
   - commands use protocol `atm10-control-v1`.
   - only a trusted controller listens on that protocol.
   - controller config has an allowed sender list.
   - command messages include a shared token.

Displays never wrap or call actuators. Remote monitors never listen on
`atm10-control-v1`.

## Safety Rules

- Displays and remote monitors never execute actions.
- Rednet messages never directly execute actions.
- A trusted controller is the only computer allowed to execute actions.
- Every real output must have a label, capability, target, mode, enabled flag,
  armed flag, and capability allow flag.
- Every real output starts disabled and unarmed until explicitly configured.
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

1. Finish wiring existing displays to `atm10-status`, `atm10-palette`, and
   `atm10-draw`. Inventory is started; power display is next.
2. Add display profiles: `wall`, `remote`, `terminal`, `debug`, `alerts`.
3. Keep stock keeper in dry-run while the planner, ledger, and cooldown logic
   mature.
4. Add a trusted controller stub that can describe gated actions but has no
   attached actuators.
5. Add a control-room monitor host after the old displays are stable.

Inventory autocrafting is now wired behind the control gate (manual mode,
operator-approved via the console queue), pending in-game verification of the
RS `craftItem` call. Exports, redstone control, and security outputs come after
the inventory craft path is proven in-game.
