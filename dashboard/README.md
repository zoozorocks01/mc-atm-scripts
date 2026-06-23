# Dashboard Host

This folder is reserved for the future multi-module monitor host.

The current working scripts remain:

- `power/display.lua`
- `power/probe.lua`
- `inventory/manager.lua`
- `inventory/remote.lua`

The dashboard host should not replace those until the shared drawing helpers
and display profiles have been proven in-game.

Future dashboard responsibilities:

- Receive or assemble state from power, inventory, machines, and alerts.
- Render configured modules onto a wall/remote/terminal profile.
- Keep displays read-only.
- Route real actions through trusted controller scripts, never monitor modules.
