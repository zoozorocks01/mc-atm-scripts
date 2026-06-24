return {
  mode = "manual",

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
    maxCraftsPerCycle = 8,
    maxRequest = 65536,

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
