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

  -- Minimum seconds between full viewer-snapshot broadcasts (the whole-grid
  -- sort feeding remote displays). Line-control packets are unaffected: they
  -- go every scan. Default 15.
  -- viewerSeconds = 15,

  -- Production lines (docs/DECISIONS.md #4): script-controlled continuous
  -- machine lines. The manager decides on/off per line each scan (hysteresis:
  -- ON below `low`, stays on until `high`) and broadcasts it; an atm10-line
  -- actuator computer near the machines turns that into a redstone signal that
  -- gates the line's RS Exporter (exporter redstone mode: active-with-signal).
  -- `floorItem`/`floorMin` = feedstock reserve the line must never eat below.
  -- Start the actuator with its manager ID, e.g.:
  --   atm10-line --manager 42 aluminum:back copper:left
  -- (42 is the manager computer's ID; put atm10-control.lua beside atm10-line.)
  -- lines = {
  --   { name = "aluminum", item = "alltheores:aluminum_ingot",
  --     low = 100000, high = 110000,
  --     floorItem = "alltheores:aluminum_dust", floorMin = 500000 },
  -- },

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
    maxCraftsPerCycle = 2,
    overflowReserve = 0,    -- compress slots reserved first within maxCraftsPerCycle (0 = pure priority)
    maxRequest = 65536,
    maxBridgeRequest = 32,  -- max count sent to one RS Bridge craftItem call
    -- Drain-aware batch sizing (DECISIONS #6): opt-in ceiling that lets ONE turn's
    -- request grow above maxRequest for items measured to drain faster than the base
    -- batch replenishes over a cooldown (live: gold starved at 4096/turn). Sizing =
    -- maxRequest + one cooldown of measured drain, bounded here. Unset/nil = off
    -- (base cap only); a per-item `maxBatch` overrides this global for that item.
    -- maxBatch = 32768,
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
          -- Watch-only buffers: many MI recipes need machines/assemblers or have
          -- better non-RS routes, so the manager must not request RS crafts for them.
          { label = "Steel Plate", name = "modern_industrialization:steel_plate", target = 128, craftTo = 256,
            craftMode = "watch", blockReason = "MI machine route; do not RS autocraft" },
          { label = "Copper Wire", name = "modern_industrialization:copper_wire", target = 128, craftTo = 256,
            craftMode = "watch", blockReason = "MI machine route; do not RS autocraft" },
          { label = "Basic Machine Hull", name = "modern_industrialization:basic_machine_hull", target = 16, craftTo = 32,
            craftMode = "watch", blockReason = "MI assembler route; do not RS autocraft" },
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

      -- ============================================================================
      -- DUST / SMELTER TIER (paste-ready) -- operator's late-game ore-balancer spec
      -- ============================================================================
      -- THIS WHOLE BLOCK IS DORMANT UNTIL THE AUTOCRAFTER + PROCESSING PATTERNS EXIST.
      -- It needs, to actually move anything:
      --   1. The autocrafter wired (allowAutocraft = true, mode manual/auto, approve).
      --   2. dust -> ingot PROCESSING PATTERNS spawned in RS for every metal below
      --      (a smelter recipe RS can fire). Without them every row reads NOT
      --      CRAFTABLE and the balancer plans nothing -- harmless, just inert.
      --   3. The reserve/mostly-dust/tiny-dust items STRIPPED FROM THE EXPORTER
      --      FILTERS so the manager (not blanket exporters) governs them. Items the
      --      exporters still blanket-smelt (steel/bronze/brass/invar/electrum/etc.)
      --      must NOT be listed here -- they have NO manager config by design.
      --
      -- THE MODEL (three tiers, all built from existing managed-quota fields):
      --   * RESERVE metals  = DUST OVERFLOW. Entry sits on the DUST: keep N dust,
      --     smelt the SURPLUS above N into the ingot. ceiling = the reserve N,
      --     into = { the ingot }, ratio = 1. target is small (dust is not
      --     refillable -- nothing crafts INTO dust here), so it never tries to make
      --     dust; it only compresses the overflow downward into ingots.
      --   * MOSTLY-DUST metals = INGOT FLOOR. Entry sits on the INGOT: keep ~2.5k
      --     ingots, the rest of the metal stays as dust. target/craftTo = 2500 and
      --     craftFrom = { the dust, reserve = 0, ratio = 1 } -- smelts dust ONLY up
      --     to the 2.5k ingot floor; any surplus stays dust.
      --   * TINY dusts = WATCH-ONLY floor (target only, no craftTo/ceiling). They
      --     cannot refill until dust->tiny CRAFTING patterns exist; for now they are
      --     just a keep-N watch so a drain is visible on the Plan page.
      --
      -- NOT IN THIS BLOCK (intentional):
      --   * SMELT-IMMEDIATELY alloys (steel, bronze, brass, invar, electrum, battery
      --     alloy, other alloys): operator's exporters blanket-smelt these -> no
      --     manager config.
      --   * MI metals: handled by Modern Industrialization, NOT managed here (the one
      --     exception, battery alloy, falls under smelt-immediately above).
      --
      -- ID VERIFICATION (against lib/atm10-presets.lua zoozo-late-game chains):
      --   VERIFIED dust+ingot pairs: copper, iron, tin, aluminum, zinc, osmium, gold,
      --   lead, nickel, silver. Ingots minecraft: for iron/gold/copper, alltheores:
      --   for the rest. The lines below tagged "VERIFY-JEI" are IDs the presets file
      --   did NOT contain -- the operator MUST confirm them in JEI before relying on
      --   them (see the FLAGGED list in the handoff). Do not assume they are correct.
      {
        label = "Dust: reserve metals (dust overflow -> ingot)",
        items = {
          -- Keep `ceiling` dust; smelt everything above it into the ingot (ratio 1).
          -- target = 1 (dust isn't refillable here; keep tiny so nothing crafts dust).
          { label = "Copper Dust",   name = "alltheores:copper_dust",   target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "minecraft:copper_ingot",    label = "Copper Ingot"   } },
          { label = "Iron Dust",     name = "alltheores:iron_dust",     target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "minecraft:iron_ingot",      label = "Iron Ingot"     } },
          { label = "Tin Dust",      name = "alltheores:tin_dust",      target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "alltheores:tin_ingot",      label = "Tin Ingot"      } },
          { label = "Aluminum Dust", name = "alltheores:aluminum_dust", target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "alltheores:aluminum_ingot", label = "Aluminum Ingot" } },
          { label = "Zinc Dust",     name = "alltheores:zinc_dust",     target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "alltheores:zinc_ingot",     label = "Zinc Ingot"     } },
          { label = "Osmium Dust",   name = "alltheores:osmium_dust",   target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "alltheores:osmium_ingot",   label = "Osmium Ingot"   } },
          { label = "Gold Dust",     name = "alltheores:gold_dust",     target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "minecraft:gold_ingot",      label = "Gold Ingot"     } },
          { label = "Lead Dust",     name = "alltheores:lead_dust",     target = 1, craftTo = 1, ceiling = 150000, ratio = 1, into = { name = "alltheores:lead_ingot",     label = "Lead Ingot"     } },
          { label = "Nickel Dust",   name = "alltheores:nickel_dust",   target = 1, craftTo = 1, ceiling = 120000, ratio = 1, into = { name = "alltheores:nickel_ingot",   label = "Nickel Ingot"   } },
          -- VERIFY-JEI: uranium dust ID NOT in presets (only the ingot is). Confirm in JEI.
          { label = "Uranium Dust",  name = "alltheores:uranium_dust",  target = 1, craftTo = 1, ceiling = 5000,   ratio = 1, into = { name = "alltheores:uranium_ingot",  label = "Uranium Ingot"  } }, -- VERIFY-JEI dust id
        },
      },
      {
        label = "Dust: mostly-dust metals (ingot floor 2500 <- dust)",
        items = {
          -- Keep ~2.5k ingots; smelt dust up to that floor only, surplus stays dust.
          { label = "Silver Ingot",   name = "alltheores:silver_ingot",   target = 2500, craftTo = 2500, craftFrom = { name = "alltheores:silver_dust",   reserve = 0, ratio = 1 } },
          -- VERIFY-JEI: platinum + iridium DUST ids NOT in presets (only ingots are). Confirm in JEI.
          { label = "Platinum Ingot", name = "alltheores:platinum_ingot", target = 2500, craftTo = 2500, craftFrom = { name = "alltheores:platinum_dust", reserve = 0, ratio = 1 } }, -- VERIFY-JEI dust id
          { label = "Iridium Ingot",  name = "alltheores:iridium_ingot",  target = 2500, craftTo = 2500, craftFrom = { name = "alltheores:iridium_dust",  reserve = 0, ratio = 1 } }, -- VERIFY-JEI dust id
        },
      },
      {
        -- WATCH-ONLY for now: tiny dusts have NO dust->tiny crafting pattern yet, so
        -- target alone (no craftTo) just surfaces a drain on the Plan page. Add a
        -- craftTo + craftFrom later once the dust->tiny pattern exists.
        -- VERIFY-JEI: EVERY id below is a naming-convention GUESS -- no tiny/nugget id
        -- appears anywhere in the repo. The operator MUST confirm each in JEI.
        label = "Dust: tiny dusts (watch-only, VERIFY-JEI all ids)",
        items = {
          { label = "Tiny Copper Dust",   name = "alltheores:copper_tiny_dust",   target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Iron Dust",     name = "alltheores:iron_tiny_dust",     target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Tin Dust",      name = "alltheores:tin_tiny_dust",      target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Aluminum Dust", name = "alltheores:aluminum_tiny_dust", target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Zinc Dust",     name = "alltheores:zinc_tiny_dust",     target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Osmium Dust",   name = "alltheores:osmium_tiny_dust",   target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Gold Dust",     name = "alltheores:gold_tiny_dust",     target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Lead Dust",     name = "alltheores:lead_tiny_dust",     target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Nickel Dust",   name = "alltheores:nickel_tiny_dust",   target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Silver Dust",   name = "alltheores:silver_tiny_dust",   target = 10000 }, -- VERIFY-JEI
          { label = "Tiny Antimony Dust", name = "modern_industrialization:antimony_tiny_dust", target = 10000 }, -- VERIFY-JEI
        },
      },
    },
  },
}
