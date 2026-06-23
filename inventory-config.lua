return {
  mode = "dry-run",

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
    maxRequest = 4096,

    items = {
      { label = "Glass", name = "minecraft:glass", target = 512, craftTo = 1024 },
      { label = "Redstone", name = "minecraft:redstone", target = 1024, craftTo = 2048 },
      { label = "Iron Ingots", name = "minecraft:iron_ingot", target = 512, craftTo = 1024 },
      { label = "Quartz", name = "minecraft:quartz", target = 256, craftTo = 512 },
    },
  },
}
