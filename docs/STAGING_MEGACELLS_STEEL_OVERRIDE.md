# Staging MEGA Cells steel-compression override

This is a **staging-only** KubeJS data-pack overlay for the MEGA Cells 4.11
`megacells:compression_overrides` NeoForge data map. It prevents the generic
`c:ingots/steel` recipe scan from selecting `oritech:biosteel_ingot` by giving
the intended AllTheOres steel chain explicit item-to-variant mappings.

## Canonical target path

Copy this repository file to the identical path beneath the verified Home Two
server root:

```
kubejs/data/megacells/data_maps/item/compression_overrides.json
```

Its exact contents are intentionally additive:

```json
{
  "values": {
    "alltheores:steel_nugget": { "variant": "alltheores:steel_ingot" },
    "alltheores:steel_ingot": { "variant": "alltheores:steel_block" }
  }
}
```

Do not add a root `replace` field or a `remove` list. NeoForge applies a
higher-priority data-pack value to the same exact item key, while those fields
could erase existing MEGA Cells compression data. The two keys here do not
overlap the bundled MEGA Cells defaults.

## Staging validation ladder

1. Preserve a timestamped copy of any existing target file.
2. Run `tools/validate-megacells-steel-override.sh` against the staged file.
3. Restart or reload **Home Two only** so KubeJS data packs and data maps load.
4. Confirm the staging log reports no data-map/KubeJS JSON decode error.
5. In a disposable MEGA Cells compression card, verify the chain is exactly
   `alltheores:steel_nugget -> alltheores:steel_ingot -> alltheores:steel_block`;
   `oritech:biosteel_ingot` must not appear in that chain.
6. Roll back by restoring the timestamped file (or removing this new file if
   none existed) and reload Home Two again.

Nothing in this repository change deploys, reloads, or changes a server.
