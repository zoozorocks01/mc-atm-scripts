# Automation Plan — automated vs manual, per resource

The complete classification of resources: **automated** (on the autocrafter) or
**manual** (left off by design), with the specific registry id(s) and the reason,
grouped by category, plus dependencies and rollout order.

> ⚠️ **DEPLOYED != DOCUMENTED — read this first (round-2 recon, 2026-06-26;
> throttle spot-check updated 2026-07-01).**
> This doc describes the **INTENDED late-game end-state** (the banded balancer). It
> is **NOT what is running on computer 6 today.** The deployed `inventory-config.lua`
> (computer 6's real file) is a **small hand-written set**: ~13 quota items across
> Base / Mekanism / MystAgri / MI. A 2026-07-01 read-only spot check found
> `mode = "dry-run"`, `stockKeeper` on, `cooldownSeconds = 300`,
> `maxCraftsPerCycle = 2`, and `maxRequest = 4096`; no explicit
> `maxBridgeRequest` is present, so the code default of `32` applies. It has **NO
> compress chains, NO 264k dust bands, NO ceiling/into/ratio overflow rules, and no
> metals beyond iron/gold/quartz/redstone.**
> The banded balancer below lives ONLY in the **`zoozo-late-game` preset**
> (`lib/atm10-presets.lua`), which must be **explicitly applied from the console**
> (applying it also flips `smartMode` on). It has **not** been applied. So: late-game
> banding is **DESIGNED + preset-ready but NOT deployed**. Deploying = apply
> `zoozo-late-game`. (Round-2 finding #1.)

> ⚠️ **Recon freshness.** The round-2 recon attempted SSH to `zjn-home-two` and
> **failed: the 1Password ED25519 agent was locked** ("communication with agent
> failed; Permission denied"). Per the hard rules SSH is best-effort, so that pass
> fell back to **repo files** (which mirror computer 6's deployed scripts)
> cross-checked against the `base-recon-findings` memory (point-in-time
> 2026-06-24/25) and the K2 inbox. The 2026-07-01 read-only spot check updated only
> the live config throttle/mode values above. Other live-state claims below —
> `.atm10-managed` quota counts, what's mid-craft, craft-results rows — are still
> from the earlier snapshot, NOT a fresh read. A fresh read-only pass (cat the
> `.atm10-*` files under `computercraft/computer/6/` plus tail the latest server
> log) should confirm which preset/quotas are actually loaded and what's mid-craft.
> **Items needing the live grid/ledger are flagged `in-game-pending`.**

> **Three disagreeing quota sources of truth** (round-2 finding #2). Quotas are
> specified in three places that disagree — name the precedence before editing any:
> 1. **Deployed** `inventory-config.lua` — ~13 items, manual, no control fields. *This
>    is what is actually running.*
> 2. **Example** `inventory-config-example.lua` — ~33 items, adds Refined Storage + a
>    full Mekanism circuit ladder + the control-center fields (all OFF/nil). A template.
> 3. **Preset** `zoozo-late-game` in `lib/atm10-presets.lua` — ~80 banded items. *This
>    is the late-game TARGET, applied on top of a minimal config.*
>
> Canonical intent: the **preset is the late-game target**; the deployed file is an
> early hand-written subset. Do not silently mistake the deployed file for this spec.

> Source for the *intended* classification: `lib/atm10-presets.lua` (zoozo-late-game)
> cross-checked against the `base-recon-findings` memory, `docs/RS_PATTERN_SPAWNING.md`,
> and `docs/MACHINE_INTEGRATION_PLAN.md`. The earlier `.atm10-managed`/`.atm10-craft-
> results`/`.atm10-patterns-needed.txt` counts (RS ~29 craftable) are from the
> 2026-06-24/25 snapshot, not re-verified this pass (`in-game-pending`).

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

The metal **compress chains** are the *designed* core: `dust (264k band) → ingot
(100k band) → block`, overflow-only direction = compress surplus into dense blocks.
At the 2026-06-24 snapshot 13 items were mid-craft (`in-game-pending` — not
re-verified this pass).

> ⚠️ **The 264k dust FLOOR is a refill target the chain CANNOT currently satisfy**
> (round-2 finding #6). The `chain()` helper sets every metal `*_dust` to
> `target = craftTo = 264000`, i.e. it asks the planner to **refill** dust up to 264k.
> But `dust → ingot` is the *reverse* direction (a smelt/PROCESSING recipe, §below),
> and per `RS_PATTERN_SPAWNING.md` processing patterns are **not yet hand-authorable**
> (gated on one in-world reference pattern, operator Q1). There is **no grid recipe
> that produces dust**, so a 264k dust floor with no processing pattern makes the
> planner **perpetually try and fail** to refill dust it cannot craft. Until the
> reference processing pattern exists, the dust rows should be **floors-to-WATCH /
> compress-SOURCE only (no `craftTo` refill)**. The only proven autocraft direction is
> the **block** step (the 9:1 grid pattern). Reconcile each metal's dust step against
> `.atm10-craft-results` live (`in-game-pending`).

> ⚠️ **Namespace conflict across presets** (round-2 finding #3). The early/mid generic
> presets use `mekanism:steel_ingot`, `mekanism:bronze_ingot`, `mekanism:enriched_iron`,
> `mysticalagriculture:prosperity_ingot`, `mysticalagriculture:soulium_ingot` — but
> recon (and the `zoozo-late-game` chain itself, `alltheores:steel_ingot`) say
> steel/bronze and the alloys are **`alltheores:*`**. The same metal is quota'd under
> two namespaces across presets. The `mekanism:`/`mysticalagriculture:` ingot forms
> will read **NOT CRAFTABLE / UNKNOWN** against the live `getItems` grid and never
> craft. **`alltheores:` is the recon-confirmed form.** Reconcile against the live grid
> (`in-game-pending`) before relying on the early/mid presets.

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

> **Preset behavior:** `lib/atm10-presets.lua` marks these MI components and
> MI-route alloys as `craftMode = "watch"` with an explicit machine/assembler
> reason. They remain visible as buffer targets but the planner blocks RS craft
> requests for them, so they do not look like generic missing-pattern failures.

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

0. **Deploy the late-game config (the actual first action, not yet done).** The
   banded balancer above is preset-ready but **not running** — the live config is the
   ~13-item hand-written set. Stage 0 is: on the console, **apply the `zoozo-late-game`
   preset** (which flips `smartMode` on), THEN apply the dust-floor fix (finding #6:
   dust rows = watch/compress-source, no `craftTo` refill) and the namespace
   reconciliation (finding #3: `alltheores:` forms). Until this is done, "metals
   AUTOMATED" describes the preset, not the live system. The Ultra Autocrafter
   reference is at world coords **~1128, 72, 2660** (from recon memory;
   `in-game-pending` to re-confirm location + which patterns it hosts).
1. **Metals AUTOMATED (the proven core once deployed).** Compress chains. Confirm every
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
