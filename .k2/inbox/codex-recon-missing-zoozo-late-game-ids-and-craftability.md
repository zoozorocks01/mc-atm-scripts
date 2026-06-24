---
title: Codex recon: missing zoozo-late-game IDs and craftability
priority: normal
created: 2026-06-24T00:17:05Z
source: manual
from: self
---

Codex recon update, from live server computer 6 exports. Sources read-only: zoozo-live-rs-meta.txt, zoozo-live-rs.tsv, zoozo-rs-craftcheck.tsv under the ATM10 world computercraft/computer/6. Bridge is connected/online, stored_rows=5883, but craftable_rows=0 and craftable_only_rows=0. zoozo-rs-craftcheck also returned isCraftable=false for every sampled target. Treat RS autocraftability as currently unavailable/unconfirmed, not as proof recipes cannot craft.

Base/normal metals, live RS amount snapshot:
material | dust | ingot | block
Iron | alltheores:iron_dust x0 (exists) | minecraft:iron_ingot x726716 | minecraft:iron_block x1192
Gold | alltheores:gold_dust x918591 | minecraft:gold_ingot x860911 | minecraft:gold_block x6450
Copper | alltheores:copper_dust x9 | minecraft:copper_ingot x17665 | minecraft:copper_block x1180
Tin | alltheores:tin_dust x1577450 | alltheores:tin_ingot x1386546 | alltheores:tin_block x8064
Lead | alltheores:lead_dust x140064 | alltheores:lead_ingot x58387 | alltheores:lead_block x0 (exists)
Silver | alltheores:silver_dust x2751 | alltheores:silver_ingot x12552 | alltheores:silver_block x0 (exists)
Nickel | alltheores:nickel_dust x346626 | alltheores:nickel_ingot x42610 | alltheores:nickel_block x0 (exists)
Aluminum | alltheores:aluminum_dust x334642 | alltheores:aluminum_ingot x386156 | alltheores:aluminum_block x0 (exists)
Osmium | alltheores:osmium_dust x881832 | alltheores:osmium_ingot x266533 | alltheores:osmium_block x5
Uranium | alltheores:uranium_dust x0 (exists) | alltheores:uranium_ingot x9595 | alltheores:uranium_block x10
Zinc | alltheores:zinc_dust x17850 | alltheores:zinc_ingot x1886 | alltheores:zinc_block x0 (exists)
Platinum | alltheores:platinum_dust x314 | alltheores:platinum_ingot x2992 | alltheores:platinum_block x0 (exists)
Iridium | alltheores:iridium_dust x924 | alltheores:iridium_ingot x23925 | alltheores:iridium_block x0 (exists)
Netherite | alltheores:netherite_dust x1526 | minecraft:netherite_ingot x25244 | minecraft:netherite_block x31

Alltheores alloy/processed metals: steel_dust/block exist, bronze_dust/block exist, brass_dust/block exist, invar_dust/block exist, electrum_dust/block exist, enderium_dust/block exist. Live ingots/blocks: steel_ingot x134459, steel_block x128; bronze_ingot x57137, bronze_block x0; brass_ingot x16105, brass_block x0; invar_ingot x20375, invar_block x0; electrum_ingot x12157, electrum_block x0; enderium_ingot x2, enderium_block x0.

EnderIO alloys live: enderio:conductive_alloy_ingot x6, redstone_alloy_ingot x50, pulsating_alloy_ingot x7, vibrant_alloy_ingot x1, dark_steel_ingot x144.

MI components/materials live: modern_industrialization:rubber_sheet x687871, motor x194793, advanced_motor x17, analog_circuit x79983, electronic_circuit x83, digital_circuit x1, processing_unit x0 (exists), battery_alloy_ingot x39403, stainless_steel_ingot x11811, cupronickel_ingot x160, kanthal_ingot x77, antimony_ingot x2, tungsten_ingot x3746, titanium_ingot x224. MI jar also confirms processing_unit_board, quantum_circuit, circuit boards if you want later tiers.

Mekanism live: mekanism:alloy_infused x9952, alloy_reinforced x1916, alloy_atomic x372, basic_control_circuit x1036, advanced_control_circuit x38, elite_control_circuit x33, steel_casing x49. No ultimate_control_circuit row in RS export.

Essence cap detail: Mystical Agriculture recipe data confirms prudentium_essence = 4x inferium_essence + infusion crystal; prudentium uncraft gives 4 inferium. Live counts: inferium x2110869, prudentium x23921, tertium x8169, imperium x289, supremium x883. If Zach wants inferium uncapped, do not add an overflow ceiling for inferium. If you do cap later, ratio should be 4 into mysticalagriculture:prudentium_essence.

I saw the newer quota preference on your screen too: Zach wants range semantics, 100K steel, about 264K dust for steel/all normal metals, at least 35K non-Mekanism alloys, Enderium 10K, and likely no hard inferium max. Existing target/craftTo already models lower/upper refill range; overflow ceiling remains the max/compress line. Suggested safe next step: update zoozo-late-game using the confirmed IDs above, keep mode monitor/manual while craftable_rows=0, and avoid treating any item as RS-autocraftable until craftItem/getCraftableItems is verified in-game.
