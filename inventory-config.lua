return {
  -- OPERATING TIER (recommended): "viewer" (read-only, never crafts) / "manual"
  -- (approve each craft) / "auto" (crafts unattended). Set this to pick a whole
  -- behavior set; it overrides mode/allowAutocraft/stockKeeper.enabled. Leave it
  -- commented out to use the individual fields below. See inventory-config-example.lua.
  -- operatingTier = "manual",
  mode = "manual",

  -- Bridge poll interval (seconds). Live computer 6 uses 15s so the manager stays
  -- comfortably below its refresh budget while still updating often enough.
  refreshSeconds = 15,

  itemDefaults = {
    handling = "unmanaged",
  },

  -- Display-only selected items. These do not create warnings or craft plans.
  listedItems = {
  },

  lowStock = {
    { label = "Glass", name = "minecraft:glass", target = 512 },
    { label = "Redstone", name = "minecraft:redstone", target = 1024 },
    { label = "Iron Ingots", name = "minecraft:iron_ingot", target = 512 },
    { label = "Quartz", name = "minecraft:quartz", target = 256 },
  },

  stockKeeper = {
    enabled = true,
    cooldownSeconds = 300,
    maxCraftsPerCycle = 2,
    overflowReserve = 0,    -- compress slots reserved first within maxCraftsPerCycle (0 = pure priority)
    maxRequest = 65536,
    maxBridgeRequest = 32,  -- max count sent to one RS Bridge craftItem call

    categories = {
      {
        label = "Base",
        items = {
          { label = "Glass", name = "minecraft:glass", target = 512, craftTo = 1024 },
          { label = "Redstone", name = "minecraft:redstone", target = 1024, craftTo = 2048 },
          { label = "Iron Ingots", name = "minecraft:iron_ingot", target = 512, craftTo = 1024 },
          { label = "Quartz", name = "minecraft:quartz", target = 256, craftTo = 512 },
        },
      },
      {
        label = "Mekanism",
        items = {
          { label = "Infused Alloy", name = "mekanism:alloy_infused", target = 128, craftTo = 256 },
          { label = "Basic Circuit", name = "mekanism:basic_control_circuit", target = 64, craftTo = 128 },
          { label = "Steel Casing", name = "mekanism:steel_casing", target = 16, craftTo = 32 },
        },
      },
      {
        label = "Mystical Agriculture",
        items = {
          { label = "Inferium Essence", name = "mysticalagriculture:inferium_essence", target = 4096, craftTo = 8192 },
          { label = "Prudentium Essence", name = "mysticalagriculture:prudentium_essence", target = 512, craftTo = 1024 },
        },
      },
      {
        label = "Modern Industrialization",
        items = {
          -- Replace these IDs with the exact item IDs from JEI if your pack differs.
          { label = "Steel Plate", name = "modern_industrialization:steel_plate", target = 128, craftTo = 256 },
          { label = "Copper Wire", name = "modern_industrialization:copper_wire", target = 128, craftTo = 256 },
        },
      },
    },
  },
}
