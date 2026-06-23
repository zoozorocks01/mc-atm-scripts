# Repository Structure

The repo now has a canonical source layout plus temporary root compatibility
mirrors.

## Canonical Source Layout

```text
lib/
  atm10-status.lua
  atm10-palette.lua
  atm10-draw.lua
  atm10-control.lua

power/
  display.lua
  display-startup.lua
  probe.lua
  probe-startup.lua

inventory/
  manager.lua
  manager-startup.lua
  remote.lua
  remote-startup.lua
  config.lua
  config-example.lua

dashboard/
  README.md
  modules/
    README.md

docs/
  CONTROL_ARCHITECTURE.md
  REPO_STRUCTURE.md
```

## Root Compatibility Mirrors

Root-level runnable scripts still exist for now:

```text
power-display.lua
power-probe.lua
inventory-info.lua
inventory-remote.lua
display-startup.lua
probe-startup.lua
inventory-startup.lua
inventory-remote-startup.lua
inventory-config.lua
inventory-config-example.lua
atm10-*.lua
```

These are compatibility mirrors for older in-game updater installs. Older
updaters download role files from root before downloading the new updater, so
removing root files immediately would strand those computers.

Do not `git rm` these root mirrors as part of normal feature work. They can be
removed only in an explicit compatibility cleanup release after all active
computers have successfully run the nested-path updater.

New versions of `atm10-update.lua` download from the canonical folders and
install to the same simple local filenames used by CC:Tweaked computers.

## Migration Rule

Until all active computers have run the nested-path updater at least once:

- Keep root compatibility mirrors.
- Make behavior changes in the canonical folder file first.
- Mirror the same change to the root compatibility file.
- Do not change the in-game local filenames unless the startup scripts change
  in the same release.

Once the updater migration is proven in-game, root compatibility mirrors can be
removed in a later cleanup release.
