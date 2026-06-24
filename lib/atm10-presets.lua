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
      { name = "mekanism:steel_ingot", label = "Steel Ingot", target = 256, craftTo = 512 },
      { name = "mekanism:bronze_ingot", label = "Bronze Ingot", target = 128, craftTo = 256 },
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
  -- full chain: dust band (264k, compress surplus to ingot at 350k) -> ingot
  -- (100k, compress surplus to block at 150k, 9:1) -> block (10k floor).
  local function chain(dust, ingot, block, label)
    add({ name = dust, label = label .. " Dust", target = 264000, craftTo = 264000,
      ceiling = 350000, into = { name = ingot, label = label .. " Ingot" }, ratio = 1 })
    add({ name = ingot, label = label .. " Ingot", target = 100000, craftTo = 100000,
      ceiling = 150000, into = { name = block, label = label .. " Block" }, ratio = 9 })
    add({ name = block, label = label .. " Block", target = 10000, craftTo = 10000 })
  end

  -- Normal metals: full dust->ingot->block chain (IDs from base recon; iron/gold/
  -- copper/netherite use minecraft: ingot+block, the rest are alltheores:).
  chain("alltheores:iron_dust", "minecraft:iron_ingot", "minecraft:iron_block", "Iron")
  chain("alltheores:gold_dust", "minecraft:gold_ingot", "minecraft:gold_block", "Gold")
  chain("alltheores:copper_dust", "minecraft:copper_ingot", "minecraft:copper_block", "Copper")
  chain("alltheores:tin_dust", "alltheores:tin_ingot", "alltheores:tin_block", "Tin")
  chain("alltheores:lead_dust", "alltheores:lead_ingot", "alltheores:lead_block", "Lead")
  chain("alltheores:silver_dust", "alltheores:silver_ingot", "alltheores:silver_block", "Silver")
  chain("alltheores:nickel_dust", "alltheores:nickel_ingot", "alltheores:nickel_block", "Nickel")
  chain("alltheores:aluminum_dust", "alltheores:aluminum_ingot", "alltheores:aluminum_block", "Aluminum")
  chain("alltheores:osmium_dust", "alltheores:osmium_ingot", "alltheores:osmium_block", "Osmium")
  chain("alltheores:zinc_dust", "alltheores:zinc_ingot", "alltheores:zinc_block", "Zinc")
  -- Steel has dust/block too; Zach wants it on the metal chain (264k dust / 100k ingot).
  chain("alltheores:steel_dust", "alltheores:steel_ingot", "alltheores:steel_block", "Steel")

  -- Rarer/special metals: modest ingot buffers (NOT the 264k metal chain).
  buf("alltheores:platinum_ingot", "Platinum", 5000)
  buf("alltheores:iridium_ingot", "Iridium", 5000)
  buf("alltheores:uranium_ingot", "Uranium", 5000)
  buf("minecraft:netherite_ingot", "Netherite", 5000)

  -- Non-Mekanism alloys: keep >= 35k. Exceptions: enderium + stainless steel = 10k.
  buf("alltheores:bronze_ingot", "Bronze", 35000)
  buf("alltheores:brass_ingot", "Brass", 35000)
  buf("alltheores:invar_ingot", "Invar", 35000)
  buf("alltheores:electrum_ingot", "Electrum", 35000)
  buf("alltheores:enderium_ingot", "Enderium", 10000)
  buf("modern_industrialization:stainless_steel_ingot", "Stainless Steel", 10000)
  buf("modern_industrialization:battery_alloy_ingot", "Battery Alloy", 35000)
  buf("modern_industrialization:cupronickel_ingot", "Cupronickel", 35000)
  buf("modern_industrialization:kanthal_ingot", "Kanthal", 35000)
  buf("enderio:conductive_alloy_ingot", "Conductive Alloy", 35000)
  buf("enderio:redstone_alloy_ingot", "Redstone Alloy", 35000)
  buf("enderio:pulsating_alloy_ingot", "Pulsating Alloy", 35000)
  buf("enderio:vibrant_alloy_ingot", "Vibrant Alloy", 35000)
  buf("enderio:dark_steel_ingot", "Dark Steel", 35000)

  -- Modern Industrialization components + metals. ~5k late-game baseline (the two
  -- highest-volume ones a bit higher). MI multiblock recipes generally are NOT
  -- RS-autocraftable, so these are buffers/targets, not autocraft.
  buf("modern_industrialization:rubber_sheet", "Rubber Sheet", 10000)
  buf("modern_industrialization:motor", "Motor", 10000)
  buf("modern_industrialization:advanced_motor", "Advanced Motor", 5000)
  buf("modern_industrialization:analog_circuit", "Analog Circuit", 5000)
  buf("modern_industrialization:electronic_circuit", "Electronic Circuit", 5000)
  buf("modern_industrialization:digital_circuit", "Digital Circuit", 5000)
  buf("modern_industrialization:antimony_ingot", "Antimony", 5000)
  buf("modern_industrialization:tungsten_ingot", "Tungsten", 5000)
  buf("modern_industrialization:titanium_ingot", "Titanium", 5000)

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
    settings = { smartMode = true },
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
