return {
  -- OPERATING TIER (recommended) -- one switch that picks a whole behavior set:
  --   "viewer"  read-only dashboard; NEVER crafts (mode=monitor, autocraft off, planner off)
  --   "manual"  plans refills + you approve each craft on the console
  --   "auto"    crafts approved deficits unattended
  -- Set this and you can ignore mode/allowAutocraft/stockKeeper.enabled below -- the
  -- tier sets all three. Leave it commented out to control those individually instead
  -- (advanced; e.g. "dry-run"). The tier, if set, WINS over the individual fields.
  -- operatingTier = "manual",

  -- Control mode (used only when operatingTier is NOT set). Gates whether a planned
  -- craft can ever fire:
  --   "monitor"  read-only; never crafts
  --   "dry-run"  plans only; never crafts
  --   "manual"   plans + requires you to approve each craft on the console
  --   "auto"     crafts approved deficits unattended (advanced)
  mode = "manual",

  -- Autocraft capability flag. Must be true for any craft to fire (still gated
  -- by mode + per-item approval). Set false to hard-disable crafting on this
  -- computer regardless of mode.
  allowAutocraft = true,

  -- CONTROL CENTER (CTRL): OFF by default. When enabled, this computer accepts
  -- gated "atm10-control-v1" rednet commands (e.g. a redstone toggle) from
  -- allowlisted senders, dispatched through the same capability gates as autocraft.
  -- This is the foundation for a factory/base control surface; build it out as you
  -- add controllable outputs. Leave disabled unless you are wiring control.
  controlEnabled = false,      -- master switch: receive control commands at all
  allowRedstone = false,       -- capability: permit redstone_set / redstone_toggle
  -- allowExport = false,      -- (future) capability: permit item exports
  controlToken = nil,          -- shared secret a command must carry (nil = no token)
  controlAllowedSenders = nil, -- { 7, 12 } = only these computer IDs (nil = any sender)

  -- Bridge poll interval (seconds, floored at 2). A tuning knob, NOT a TPS fix:
  -- live /spark profiling found the once-per-poll getItems() is not a measurable
  -- server cost (an entity cull, not a slower poll, is what restored TPS). Lower
  -- for snappier refresh; raise only if you ever profile the bridge as a real cost
  -- on a very large network. Touch input stays responsive regardless.
  refreshSeconds = 5,

  itemDefaults = {
    handling = "unmanaged",
  },

  -- Display-only selected items. These can appear on future detail pages
  -- without becoming low-stock warnings or stock keeper plans.
  listedItems = {
    { label = "Nether Stars", name = "minecraft:nether_star" },
    { label = "Allthemodium Ingot", name = "allthemodium:allthemodium_ingot" },
  },

  -- These low-stock watches are just warnings.
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
    overflowReserve = 0,    -- compress slots reserved first within maxCraftsPerCycle (0 = pure priority)
    maxRequest = 65536,
    -- Refill uses your exact numbers: set craftTo == target to maintain that floor,
    -- or set craftTo higher than target for a min->max buffer. No auto-band.
    --
    -- Optional per-item INPUT RESERVE (craftFrom): keep a buffer of the SOURCE item
    -- so on-demand crafting never drains it. e.g. an ingot smelted from dust:
    --   { label = "Iron Ingot", name = "alltheores:iron_ingot", target = 2000, craftTo = 5000,
    --     craftFrom = { name = "alltheores:iron_dust", reserve = 1000, ratio = 1 } },
    -- The planner caps each craft at floor((dust - reserve) / ratio); if the whole
    -- request is held, the row shows RESERVED (keeps your dust for alloys, etc.).

    categories = {
      {
        label = "Base",
        items = {
          { label = "Glass", name = "minecraft:glass", target = 512, craftTo = 1024 },
          { label = "Redstone", name = "minecraft:redstone", target = 1024, craftTo = 2048 },
          { label = "Iron Ingots", name = "minecraft:iron_ingot", target = 512, craftTo = 1024 },
          { label = "Gold Ingots", name = "minecraft:gold_ingot", target = 256, craftTo = 512 },
          { label = "Quartz", name = "minecraft:quartz", target = 256, craftTo = 512 },
          { label = "Ender Pearls", name = "minecraft:ender_pearl", target = 128, craftTo = 256 },
        },
      },
      {
        label = "Mekanism",
        items = {
          { label = "Infused Alloy", name = "mekanism:alloy_infused", target = 128, craftTo = 256 },
          { label = "Reinforced Alloy", name = "mekanism:alloy_reinforced", target = 64, craftTo = 128 },
          { label = "Atomic Alloy", name = "mekanism:alloy_atomic", target = 32, craftTo = 64 },
          { label = "Basic Circuit", name = "mekanism:basic_control_circuit", target = 64, craftTo = 128 },
          { label = "Advanced Circuit", name = "mekanism:advanced_control_circuit", target = 32, craftTo = 64 },
          { label = "Elite Circuit", name = "mekanism:elite_control_circuit", target = 16, craftTo = 32 },
          { label = "Ultimate Circuit", name = "mekanism:ultimate_control_circuit", target = 8, craftTo = 16 },
          { label = "Steel Casing", name = "mekanism:steel_casing", target = 16, craftTo = 32 },
        },
      },
      {
        label = "Modern Industrialization",
        items = {
          -- Verify exact IDs in JEI. MI item IDs vary by material and part.
          { label = "Steel Plate", name = "modern_industrialization:steel_plate", target = 128, craftTo = 256 },
          { label = "Copper Wire", name = "modern_industrialization:copper_wire", target = 128, craftTo = 256 },
          { label = "Basic Machine Hull", name = "modern_industrialization:basic_machine_hull", target = 16, craftTo = 32 },
        },
      },
      {
        label = "Mystical Agriculture",
        items = {
          { label = "Inferium Essence", name = "mysticalagriculture:inferium_essence", target = 4096, craftTo = 8192 },
          { label = "Prudentium Essence", name = "mysticalagriculture:prudentium_essence", target = 512, craftTo = 1024 },
          { label = "Tertium Essence", name = "mysticalagriculture:tertium_essence", target = 256, craftTo = 512 },
          { label = "Imperium Essence", name = "mysticalagriculture:imperium_essence", target = 128, craftTo = 256 },
          { label = "Supremium Essence", name = "mysticalagriculture:supremium_essence", target = 64, craftTo = 128 },
        },
      },
      {
        label = "Refined Storage",
        items = {
          { label = "Quartz Enriched Iron", name = "refinedstorage:quartz_enriched_iron", target = 256, craftTo = 512 },
          { label = "Basic Processor", name = "refinedstorage:processor", target = 64, craftTo = 128 },
        },
      },
    },
  },
}
