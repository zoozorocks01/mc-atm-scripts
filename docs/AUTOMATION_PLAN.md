# Automation Plan — automated vs manual, per resource

The complete classification of the operator's ~79 quotas: **automated** (on the
autocrafter) or **manual** (left off by design), with the specific registry id(s)
and the reason, grouped by category, plus dependencies and rollout order.

> Source: the live-recon classification (computer 6: `.atm10-managed` ~70 quotas,
> `.atm10-craft-results`, `.atm10-patterns-needed.txt` — RS has 29 craftable, 63
> still need patterns) cross-checked against `lib/atm10-presets.lua` (zoozo-late-game),
> `docs/RS_PATTERN_SPAWNING.md`, and `docs/MACHINE_INTEGRATION_PLAN.md`.

> **Ground truth on craftability:** CC-side `getCraftableItems`/`isCraftable` read
> blind (every `getItems` row shows `isCraftable=false`, `getCraftableItems`=29) yet
> the queue is actively crafting items NOT in that 29-set. The ONLY trustworthy
> signals are: (a) presence in the `getItems` grid, and (b) `ok=true` rows in
> `.atm10-craft-results`. "Automated" below means *a pattern exists and a real craft
> has succeeded*, not that `isCraftable` returns true.

---

## Status key

| Tier | Meaning |
|---|---|
| **AUTOMATED** | Pattern exists, real craft confirmed (`ok=true`), keep on the system. |
| **BLOCKED** | Want automated; needs a pattern/machine first. On the `atm10-patterns` worklist. |
| **MANUAL** | Left off the autocrafter by design (passive/abundant/raw/display-only). |

The three buckets map to: AUTOMATED = nothing to do but watch; BLOCKED = the
CRAFT-3/CRAFT-4 + Machine-Integration tracks; MANUAL = config carries them as
low-stock warnings or `listedItems` only, never as craft quotas.

---

## 1. Base (minecraft) — mostly MANUAL/passive

| Resource | Registry id(s) | Tier | Why |
|---|---|---|---|
| Glass | `minecraft:glass` | MANUAL | Abundant/passive; trivial 1-step smelt; autocrafting adds queue noise for no value. Config keeps it as a low-stock warning only. |
| Redstone | `minecraft:redstone` | MANUAL | High-throughput passive; mined/farmed, not worth a craft slot. Low-stock warning only. |
| Quartz | `minecraft:quartz` | MANUAL | Passive world-gen feedstock. Low-stock warning only. |
| Ender pearl | `minecraft:ender_pearl` | MANUAL | Mob drop / farm output, not a crafting recipe. Low-stock warning only. |
| Iron ingot/block | `minecraft:iron_ingot`, `minecraft:iron_block` | AUTOMATED | Compress chain (see Metals). `iron` dust via `minecraft:`+`alltheores:` dusts. |
| Gold ingot/block | `minecraft:gold_ingot`, `minecraft:gold_block` | AUTOMATED | Compress chain (see Metals). |
| Copper ingot/block | `minecraft:copper_ingot`, `minecraft:copper_block` | AUTOMATED | Compress chain (see Metals). |

Rationale: the *raw* basics (glass/redstone/quartz/ender_pearl) are cheap and
passive — left manual on purpose. The three vanilla metals ride the metal compress
chains because they share the same 9:1 / dust→ingot recipes.

---

## 2. Metals — AUTOMATED (the workhorse) + a few BLOCKED

The metal **compress chains** are the proven core: `dust (264k band) → ingot (100k
band) → block`, overflow-only direction = compress surplus into dense blocks. 13
items were mid-craft at recon time; all relevant rows are `ok=true`.

### AUTOMATED — proven live (alltheores + vanilla)

Each metal: `*_dust → *_ingot → *_block` (and tiny-dust where present).

| Metal | dust / ingot / block ids | Tier |
|---|---|---|
| Tin | `alltheores:tin_dust` / `alltheores:tin_ingot` / `alltheores:tin_block` | AUTOMATED |
| Lead | `alltheores:lead_dust` / `alltheores:lead_ingot` / `alltheores:lead_block` | AUTOMATED |
| Silver | `alltheores:silver_dust` / `alltheores:silver_ingot` / `alltheores:silver_block` | AUTOMATED |
| Nickel | `alltheores:nickel_dust` / `alltheores:nickel_ingot` / `alltheores:nickel_block` | AUTOMATED |
| Aluminum | `alltheores:aluminum_dust` / `alltheores:aluminum_ingot` / `alltheores:aluminum_block` | AUTOMATED |
| Osmium | `alltheores:osmium_dust` / `alltheores:osmium_ingot` / `alltheores:osmium_block` | AUTOMATED |
| Zinc | `alltheores:zinc_dust` / `alltheores:zinc_ingot` / `alltheores:zinc_block` | AUTOMATED |
| Steel | `alltheores:steel_dust` / `alltheores:steel_ingot` / `alltheores:steel_block` | AUTOMATED |
| Iron | `minecraft:iron_ingot` / `minecraft:iron_block` (+ `alltheores`/`minecraft` dust) | AUTOMATED |
| Gold | `minecraft:gold_ingot` / `minecraft:gold_block` (+ dust) | AUTOMATED |
| Copper | `minecraft:copper_ingot` / `minecraft:copper_block` (+ dust) | AUTOMATED |

**Dependency:** the block direction uses crafting-grid patterns (the 11 spawned per
`RS_PATTERN_SPAWNING.md`). The `dust→ingot` direction is a **smelt/machine
(processing) recipe** — where RS already has it, the chain runs end to end; where it
does not, the dust→ingot step is BLOCKED on a processing pattern (Machine
Integration Track A). Confirm per-metal against `.atm10-craft-results`.

### BLOCKED — rare metals (modest 5k buffers)

| Metal | ids | Tier | Blocker |
|---|---|---|---|
| Platinum | `alltheores:platinum_dust` / `alltheores:platinum_ingot` | BLOCKED | dust→ingot processing pattern (else manual). |
| Iridium | `alltheores:iridium_dust` / `alltheores:iridium_ingot` | BLOCKED | same. |
| Uranium | `alltheores:uranium_dust` / `alltheores:uranium_ingot` | BLOCKED | same. |
| Netherite | `minecraft:netherite_ingot` | BLOCKED | multi-step (scrap→alloy); modest buffer or leave manual. |

---

## 3. Mystical Agriculture — AUTOMATED (essences + tiers)

| Resource | Registry id(s) | Tier | Why |
|---|---|---|---|
| Inferium ingot/gemstone | `mysticalagriculture:inferium_ingot`, `..._gemstone` | AUTOMATED | In the 29-craftable set; patterns present. |
| Prudentium ingot/gemstone | `mysticalagriculture:prudentium_ingot`, `..._gemstone` | AUTOMATED | In the 29-set. |
| Tertium ingot/gemstone | `mysticalagriculture:tertium_ingot`, `..._gemstone` | AUTOMATED | In the 29-set. |
| Imperium ingot/gemstone | `mysticalagriculture:imperium_ingot`, `..._gemstone` | AUTOMATED | In the 29-set. |
| Supremium ingot/gemstone | `mysticalagriculture:supremium_ingot`, `..._gemstone` | AUTOMATED | In the 29-set. |
| Essences (5 tiers) | `mysticalagriculture:{inferium,prudentium,tertium,imperium,supremium}_essence` | AUTOMATED* | Pure crafting-grid recipe (essence = 4× lower tier). Automatable once each tier's grid pattern is spawned. |

*Essence tiers are a clean upgrade chain: each is 4× the tier below, so a single
crafting pattern per tier (CRAFT-4 can clone them) makes the whole ladder automated.

**MANUAL exception:** the base `mysticalagriculture:inferium_essence` pool is left
**uncapped** (~2.1M) — fine to pool from farms, do NOT compress.

---

## 4. EnderIO alloys — one AUTOMATED, rest BLOCKED

| Resource | Registry id(s) | Tier | Blocker |
|---|---|---|---|
| Vibrant alloy | `enderio:vibrant_alloy_ingot` | AUTOMATED | In the 29-set; crafted live (first proven craft, 2026-06-24). |
| Conductive alloy | `enderio:conductive_alloy_ingot` | BLOCKED | alloy-smelter processing pattern (Track A). |
| Dark steel | `enderio:dark_steel_ingot` | BLOCKED | alloy-smelter processing pattern. |
| Pulsating alloy | `enderio:pulsating_alloy_ingot` | BLOCKED | alloy-smelter processing pattern. |
| Redstone alloy | `enderio:redstone_alloy_ingot` | BLOCKED | alloy-smelter processing pattern. |
| Enderium | `enderio:enderium_ingot` | BLOCKED | alloy-smelter processing pattern. |

---

## 5. Mekanism alloys + circuits — BLOCKED (machine processing)

All require Metallurgic Infuser / multiblock processing patterns (not crafting-grid).

| Resource | Registry id(s) | Tier |
|---|---|---|
| Infused alloy | `mekanism:alloy_infused` | BLOCKED |
| Reinforced alloy | `mekanism:alloy_reinforced` | BLOCKED |
| Atomic alloy | `mekanism:alloy_atomic` | BLOCKED |
| Steel casing | `mekanism:steel_casing` | BLOCKED |
| Control circuit (basic) | `mekanism:basic_control_circuit` | BLOCKED |
| Control circuit (advanced) | `mekanism:advanced_control_circuit` | BLOCKED |
| Control circuit (elite) | `mekanism:elite_control_circuit` | BLOCKED |
| Control circuit (ultimate) | `mekanism:ultimate_control_circuit` | BLOCKED |

**Dependency chain:** circuits depend on the alloys (infused → advanced circuit,
etc.), and the alloys depend on their metal inputs being automated first. Order:
metals AUTOMATED → alloy processing patterns → circuit patterns.

---

## 6. Modern Industrialization — BLOCKED / MANUAL (assembler multiblock)

MI components generally are NOT RS-autocraftable (assembler/multiblock recipes).
Treated as buffers/targets pending machine integration, or left manual.

| Resource | Registry id(s) | Tier | Note |
|---|---|---|---|
| Steel plate | `modern_industrialization:steel_plate` | BLOCKED | machine processing. |
| Copper wire | `modern_industrialization:copper_wire` | BLOCKED | machine processing. |
| Machine hull | `modern_industrialization:machine_hull` | BLOCKED | assembler. |
| Motor / advanced motor | `modern_industrialization:motor`, `:advanced_motor` | BLOCKED | assembler. |
| Analog/digital/electronic circuit | `modern_industrialization:analog_circuit`, `:digital_circuit`, `:electronic_circuit` | BLOCKED | assembler. |
| Rubber sheet | `modern_industrialization:rubber_sheet` | BLOCKED | machine processing. |
| MI metals (antimony/titanium/tungsten ingot) | `modern_industrialization:{antimony,titanium,tungsten}_ingot` | BLOCKED | machine processing; else manual. |
| Other MI metals (battery_alloy/cupronickel/kanthal/stainless_steel ingot) | `modern_industrialization:{battery_alloy,cupronickel,kanthal,stainless_steel}_ingot` | BLOCKED | alloy/machine processing. |

> **Preset note (cleanup item):** `lib/atm10-presets.lua` ships these MI components +
> several alloys as `buf()` targets. After CRAFT-3 lands they will correctly read
> NOT CRAFTABLE / appear on the worklist rather than silently planning. The preset
> comments should state these are buffers pending machine integration, not
> autocraftable today (low-priority doc fix, flagged in NEXT_IMPROVEMENTS).

---

## 7. Display-only / pooled — MANUAL by design

| Resource | Registry id(s) | Tier | Why |
|---|---|---|---|
| Nether star | `minecraft:nether_star` | MANUAL (watch) | `listedItems` — display only, never craft. |
| Allthemodium ingot | `allthemodium:allthemodium_ingot` | MANUAL (watch) | `listedItems` — watch, don't craft. |
| Inferium essence (base pool) | `mysticalagriculture:inferium_essence` | MANUAL (pool) | Uncapped ~2.1M farm pool; do not compress. |
| Raw mining feedstock | ores, raw ores, mob drops, upstream dusts' source | MANUAL | Gathered by farms/mining, not crafted. |

---

## 8. Dependencies & rollout order

The automation frontier advances in this order (each stage unblocks the next):

1. **Metals AUTOMATED (done/in-progress).** Compress chains are live. Confirm every
   metal's `dust→ingot` step has a processing pattern; the few that don't are the
   first Machine-Integration Track A targets. *Tooling: CRAFT-3 (validate IDs),
   CRAFT-5 (per-category budgets so a dust flood can't starve alloys/essences).*
2. **MA essences AUTOMATED.** Spawn the 5 essence-tier crafting-grid patterns
   (clean 4:1 ladder) — pure crafting, no machine needed. *Tooling: CRAFT-4 clones
   the grid patterns.*
3. **One reference processing pattern (in-game, one-time).** Make a single
   dust→ingot processing pattern in-world, capture its NBT
   (`RS_PATTERN_SPAWNING.md` §Processing). This unblocks cloning for every machine
   recipe. **This is the single gating in-game step for the whole BLOCKED tier.**
4. **EnderIO + Mekanism alloys.** Once the processing-pattern shape is known, clone
   per alloy. Then Mekanism circuits (depend on alloys). *Track A + CRAFT-4.*
5. **MI components.** Last, and partly may stay manual (assembler multiblocks are the
   hardest to express as RS patterns). Re-run `atm10-patterns` after each batch —
   the worklist is the live tracker.

**Cross-cutting dependency:** every chunk in any craft path must be **force-loaded**
(FTB Chunks) — an unloaded chunk risks the uncatchable AP detach crash, same rule as
the manager. See `MACHINE_INTEGRATION_PLAN.md` Track A step 4.
