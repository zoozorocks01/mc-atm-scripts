-- Zoozo's stock-quota presets: curated bundles of {name, target, craftTo} for
-- each game stage. Applying a preset merges its items into the managed-quota
-- store (atm10-managed); existing quotas for the same item are overwritten, other
-- quotas are left alone. Pure logic, unit-tested off-CC.
--
-- IMPORTANT: registry names below are best-effort ATM10 (All The Mods 10) IDs.
-- An ID that does not exist in your pack is harmless — it just shows up as
-- NOT CRAFTABLE on the Plan page. Fix any such item by tapping the real one on
-- the Browse page (which shows the true registry name) and SAVE.
-- Lines marked "VERIFY" are the ones most likely to differ between versions.
local managed = require("atm10-managed")

local presets = {}

-- Ordered so the UI lists them early -> late.
presets.all = {
  {
    id = "early",
    label = "Early Game",
    description = "Basics + first Mekanism processing",
    items = {
      { name = "minecraft:iron_ingot", label = "Iron Ingot", target = 512, craftTo = 1024 },
      { name = "minecraft:gold_ingot", label = "Gold Ingot", target = 256, craftTo = 512 },
      { name = "minecraft:copper_ingot", label = "Copper Ingot", target = 256, craftTo = 512 },
      { name = "minecraft:redstone", label = "Redstone", target = 1024, craftTo = 2048 },
      { name = "minecraft:glass", label = "Glass", target = 512, craftTo = 1024 },
      { name = "alltheores:steel_ingot", label = "Steel Ingot", target = 256, craftTo = 512 },
      { name = "alltheores:bronze_ingot", label = "Bronze Ingot", target = 128, craftTo = 256 },
      { name = "mekanism:enriched_iron", label = "Enriched Iron", target = 128, craftTo = 256 },
      { name = "mekanism:alloy_infused", label = "Infused Alloy", target = 128, craftTo = 256 },
      { name = "mysticalagriculture:inferium_essence", label = "Inferium Essence", target = 1024, craftTo = 4096 },
    },
  },
  {
    id = "mid",
    label = "Mid Game",
    description = "Alloys, circuits, Mystical Agriculture tiers",
    items = {
      { name = "mekanism:alloy_reinforced", label = "Reinforced Alloy", target = 128, craftTo = 256 },
      { name = "mekanism:basic_control_circuit", label = "Basic Circuit", target = 128, craftTo = 256 },
      { name = "mekanism:advanced_control_circuit", label = "Advanced Circuit", target = 64, craftTo = 128 },
      { name = "mysticalagriculture:prudentium_essence", label = "Prudentium Essence", target = 512, craftTo = 2048 },
      { name = "mysticalagriculture:tertium_essence", label = "Tertium Essence", target = 256, craftTo = 1024 },
      { name = "mysticalagriculture:prosperity_ingot", label = "Prosperity Ingot", target = 256, craftTo = 512 },
      { name = "allthemodium:allthemodium_ingot", label = "Allthemodium Ingot", target = 64, craftTo = 256 },
      { name = "minecraft:netherite_ingot", label = "Netherite Ingot", target = 32, craftTo = 64 },
    },
  },
  {
    id = "late",
    label = "Late Game",
    description = "ATM metals, atomic alloys, top circuits",
    items = {
      { name = "allthemodium:vibranium_ingot", label = "Vibranium Ingot", target = 64, craftTo = 256 },
      { name = "allthemodium:unobtainium_ingot", label = "Unobtainium Ingot", target = 32, craftTo = 128 },
      { name = "mekanism:alloy_atomic", label = "Atomic Alloy", target = 128, craftTo = 256 },
      { name = "mekanism:elite_control_circuit", label = "Elite Circuit", target = 32, craftTo = 64 },
      { name = "mekanism:ultimate_control_circuit", label = "Ultimate Circuit", target = 16, craftTo = 64 },
      { name = "mysticalagriculture:imperium_essence", label = "Imperium Essence", target = 256, craftTo = 1024 },
      { name = "mysticalagriculture:supremium_essence", label = "Supremium Essence", target = 128, craftTo = 512 },
      { name = "mysticalagriculture:soulium_ingot", label = "Soulium Ingot", target = 64, craftTo = 128 },
    },
  },
  {
    id = "mega",
    label = "Mega Late",
    description = "Endgame alloys + star components",
    items = {
      -- VERIFY: ATM alloy/star IDs vary by version; tap the real items if these read NOT CRAFTABLE.
      { name = "allthemodium:vibranium_allthemodium_alloy_ingot", label = "Vib-Allthemodium Alloy", target = 32, craftTo = 128 },
      { name = "allthemodium:unobtainium_vibranium_alloy_ingot", label = "Unob-Vib Alloy", target = 16, craftTo = 64 },
      { name = "allthemodium:atm_star", label = "ATM Star", target = 4, craftTo = 16 }, -- VERIFY
      { name = "minecraft:nether_star", label = "Nether Star", target = 16, craftTo = 64 },
      { name = "mysticalagriculture:supremium_essence", label = "Supremium Essence", target = 512, craftTo = 2048 },
    },
  },
}

-- A named PERSONAL profile (opt-in, off by default). The generic stage presets
-- above are neutral starting points anyone can use; this one is Zoozo's late-game
-- setup and is the only thing that enables smart mode when applied.
--
-- Built from Codex's base recon (2026-06-23/24), Zach's quota numbers.
--   * Numbers are Zach's lines (264k dust band, 100k ingot, 35k alloys, etc.) -
--     starting points to tune, not gospel.
--   * IMPORTANT: the live RS export shows craftable_rows=0 (isCraftable=false for
--     every item). So NOTHING autocrafts yet - run mode monitor/manual and treat
--     these as targets to watch until craftItem/getCraftableItems is verified
--     in-game and the RS pattern TREES exist.
--   * Still out: MI components (rubber/motor/circuits) and Mekanism alloys - add
--     once Zach picks numbers for them.
do
  local items = {}
  local function add(x) items[#items + 1] = x end
  local function buf(name, label, target) add({ name = name, label = label, target = target, craftTo = target }) end
  local function watch(name, label, target, reason)
    add({ name = name, label = label, target = target, craftTo = target,
      craftMode = "watch", blockReason = reason or "machine/assembler route; do not RS autocraft" })
  end
  -- METAL DUST TIERS (operator's late-game ore-balancer, 2026-06-27). DORMANT until
  -- the autocrafter + dust->ingot PROCESSING patterns exist (rows read NOT CRAFTABLE,
  -- fail-inert, until then). Strip these dusts from the smelter exporter filters so the
  -- on-demand autocrafter owns them, not the blanket exporters. Steel/bronze/brass/
  -- invar/electrum/battery-alloy are SMELT-IMMEDIATELY (blanket exporters) -> not here.

  -- RESERVE metals: keep `keep` dust (for alloys); smelt the SURPLUS above it into
  -- ingots (overflow: ceiling=keep, into=ingot, ratio 1; target/craftTo=1 -- dust isn't
  -- refillable from ingots, so no floor).
  local function reserve(dust, ingot, label, keep)
    add({ name = dust, label = label .. " Dust", target = 1, craftTo = 1,
      ceiling = keep, into = { name = ingot, label = label .. " Ingot" }, ratio = 1 })
  end
  reserve("alltheores:copper_dust",    "minecraft:copper_ingot",    "Copper",   150000)
  reserve("alltheores:iron_dust",      "minecraft:iron_ingot",      "Iron",     150000)
  reserve("alltheores:tin_dust",       "alltheores:tin_ingot",      "Tin",      150000)
  reserve("alltheores:aluminum_dust",  "alltheores:aluminum_ingot", "Aluminum", 150000)
  reserve("alltheores:zinc_dust",      "alltheores:zinc_ingot",     "Zinc",     150000)
  reserve("alltheores:osmium_dust",    "alltheores:osmium_ingot",   "Osmium",   150000)
  reserve("alltheores:gold_dust",      "minecraft:gold_ingot",      "Gold",     150000)
  reserve("alltheores:lead_dust",      "alltheores:lead_ingot",     "Lead",     150000)
  reserve("alltheores:nickel_dust",    "alltheores:nickel_ingot",   "Nickel",   120000)
  reserve("alltheores:uranium_dust",   "alltheores:uranium_ingot",  "Uranium",  5000) -- VERIFY-JEI uranium dust id

  -- MOSTLY-DUST metals: keep ~2.5k ingots, the rest stays dust (ingot floor smelts dust
  -- via craftFrom; surplus dust accumulates). silver feeds electrum; plat/iridium rare.
  local function mostly(ingot, dust, label)
    add({ name = ingot, label = label .. " Ingot", target = 2500, craftTo = 2500,
      craftFrom = { name = dust, reserve = 0, ratio = 1 } })
  end
  mostly("alltheores:silver_ingot",   "alltheores:silver_dust",   "Silver")
  mostly("alltheores:platinum_ingot", "alltheores:platinum_dust", "Platinum") -- VERIFY-JEI platinum dust id
  mostly("alltheores:iridium_ingot",  "alltheores:iridium_dust",  "Iridium")  -- VERIFY-JEI iridium dust id

  -- TINY dusts: maintain 10k, crafted from dust via the operator's 1 dust -> 9 tiny
  -- patterns. VERIFIED LIVE 2026-06-28 (atm10-patterns): the real ids are
  -- modern_industrialization:, NOT alltheores:, and ONLY MI metals have a tiny-dust
  -- form -- aluminum + antimony are confirmed craftable. The base alltheores metals
  -- (copper/iron/tin/zinc/osmium/gold/lead/nickel/silver) have NO tiny dust at all, so
  -- they are intentionally omitted (the old alltheores:*_tiny_dust rows were junk).
  add({ name = "modern_industrialization:aluminum_tiny_dust", label = "Tiny Aluminum Dust", target = 10000, craftTo = 10000 })
  add({ name = "modern_industrialization:antimony_tiny_dust", label = "Tiny Antimony Dust", target = 10000, craftTo = 10000 })

  buf("minecraft:netherite_ingot", "Netherite", 5000)

  -- Bulk materials: keep a reserve floor (refills if craftable, else a watch).
  buf("minecraft:sand", "Sand", 10000)

  -- Non-Mekanism alloys: keep >= 35k. Exceptions: enderium + stainless steel = 10k.
  buf("alltheores:bronze_ingot", "Bronze", 35000)
  buf("alltheores:brass_ingot", "Brass", 35000)
  buf("alltheores:invar_ingot", "Invar", 35000)
  buf("alltheores:electrum_ingot", "Electrum", 35000)
  buf("alltheores:enderium_ingot", "Enderium", 10000)
  watch("modern_industrialization:stainless_steel_ingot", "Stainless Steel", 10000,
    "MI/alloy machine route; do not RS autocraft")
  watch("modern_industrialization:battery_alloy_ingot", "Battery Alloy", 35000,
    "MI/alloy machine route; do not RS autocraft")
  watch("modern_industrialization:cupronickel_ingot", "Cupronickel", 35000,
    "MI/alloy machine route; do not RS autocraft")
  watch("modern_industrialization:kanthal_ingot", "Kanthal", 35000,
    "MI/alloy machine route; do not RS autocraft")
  buf("enderio:conductive_alloy_ingot", "Conductive Alloy", 35000)
  buf("enderio:redstone_alloy_ingot", "Redstone Alloy", 35000)
  buf("enderio:pulsating_alloy_ingot", "Pulsating Alloy", 35000)
  buf("enderio:vibrant_alloy_ingot", "Vibrant Alloy", 35000)
  buf("enderio:dark_steel_ingot", "Dark Steel", 35000)

  -- Modern Industrialization components + metals. ~5k late-game baseline (the two
  -- highest-volume ones a bit higher). MI multiblock recipes generally are NOT
  -- RS-autocraftable, so these are buffers/targets, not autocraft.
  watch("modern_industrialization:rubber_sheet", "Rubber Sheet", 10000)
  watch("modern_industrialization:motor", "Motor", 10000)
  watch("modern_industrialization:advanced_motor", "Advanced Motor", 5000)
  watch("modern_industrialization:analog_circuit", "Analog Circuit", 5000)
  watch("modern_industrialization:electronic_circuit", "Electronic Circuit", 5000)
  watch("modern_industrialization:digital_circuit", "Digital Circuit", 5000)
  watch("modern_industrialization:antimony_ingot", "Antimony", 5000)
  watch("modern_industrialization:tungsten_ingot", "Tungsten", 5000)
  watch("modern_industrialization:titanium_ingot", "Titanium", 5000)

  -- Mekanism alloys + casing (~5k baseline).
  buf("mekanism:alloy_infused", "Infused Alloy", 5000)
  buf("mekanism:alloy_reinforced", "Reinforced Alloy", 5000)
  buf("mekanism:alloy_atomic", "Atomic Alloy", 5000)
  buf("mekanism:steel_casing", "Steel Casing", 5000)

  -- Mystical Agriculture: inferium left UNCAPPED (base feedstock, ~2.1M, fine to
  -- pool). Higher tiers kept as floors only (no ceiling - extras are valuable).
  buf("mysticalagriculture:prudentium_essence", "Prudentium Essence", 16000)
  buf("mysticalagriculture:tertium_essence", "Tertium Essence", 8000)
  buf("mysticalagriculture:imperium_essence", "Imperium Essence", 2000)
  buf("mysticalagriculture:supremium_essence", "Supremium Essence", 1000)

  presets.all[#presets.all + 1] = {
    id = "zoozo-late-game",
    label = "Zoozo Late-Game",
    description = "Personal starter from base recon (partial) - tune in-game",
    personal = true,
    settings = { smartMode = true, compressChains = true },
    items = items,
  }
end

-- Presets as a display list (id, label, description, count, personal).
function presets.list()
  local out = {}
  for _, p in ipairs(presets.all) do
    out[#out + 1] = {
      id = p.id, label = p.label, description = p.description,
      count = #p.items, personal = p.personal == true,
    }
  end
  return out
end

-- The behavior settings a profile carries (smartMode, etc.), or an empty table.
function presets.settings(id)
  local p = presets.get(id)
  return (p and type(p.settings) == "table") and p.settings or {}
end

function presets.get(id)
  for _, p in ipairs(presets.all) do
    if p.id == id then return p end
  end
  return nil
end

-- Merge a preset's items into the managed store (overwrites those items' quotas,
-- leaves others). Returns the store and the number of quotas written.
function presets.apply(store, id, now)
  store = managed.normalize(store)
  local p = presets.get(id)
  if not p then return store, 0 end

  local count = 0
  for _, item in ipairs(p.items) do
    managed.set(store, item, now)
    count = count + 1
  end
  return store, count
end

return presets
