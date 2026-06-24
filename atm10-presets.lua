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
-- STARTER, NOT FINAL. Built from a PARTIAL base recon (Codex, 2026-06-23):
--   * Only confirmed registry IDs are used (alltheores:* metals/alloys,
--     modern_industrialization:*, enderio:* alloys, mysticalagriculture:*).
--   * The recon was truncated above "Zinc", so base metals (iron/copper/gold/
--     tin/lead/silver/nickel/aluminum/osmium/...) are NOT here yet, nor are
--     block IDs, MI components, or Mekanism alloys. Expand as Codex sends more.
--   * Numbers are starting points to tune in-game, not gospel.
--   * Nothing autocrafts until the RS pattern TREES exist for each item; until
--     then these act as monitor targets (run in manual/monitor mode).
do
  local items = {}
  local function add(x) items[#items + 1] = x end
  local function buf(name, label, target) add({ name = name, label = label, target = target, craftTo = target }) end

  -- Normal metals: keep a big dust band (smelt the surplus up to ingots) and keep
  -- 100k of the ingot. Zinc is the only normal metal in the partial recon; the
  -- same 264k-dust / 100k-ingot pattern applies to iron/copper/gold/etc once Codex
  -- sends their IDs (add an ingot->block compress when block ids land).
  add({ name = "alltheores:zinc_dust", label = "Zinc Dust", target = 264000, craftTo = 264000,
    ceiling = 350000, into = { name = "alltheores:zinc_ingot", label = "Zinc Ingot" }, ratio = 1 })
  add({ name = "alltheores:zinc_ingot", label = "Zinc Ingot", target = 100000, craftTo = 100000 })

  -- Steel: keep 100k (ingot-only in recon).
  buf("alltheores:steel_ingot", "Steel", 100000)

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
