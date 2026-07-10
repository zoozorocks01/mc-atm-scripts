# ATM10 autocrafting expansion kit — 2026-07-08

## A. Six dust->ingot smelter patterns (clone of the proven aluminum route)
Drop ALL of these into the DEDICATED crafter on the Ultimate Smelting Factory
(the one holding the aluminum pattern) — one crafter, one smelter, seven supply lines.
Uranium/nickel/zinc already exist in the support crafter at 1149 75 2642 — skip those.

### Copper (alltheores:copper_dust -> minecraft:copper_ingot)
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"processing",id:[I;8110201,8110202,8110203,8110204]},refinedstorage:processing_pattern_state={outputs:[{resource:{amount:1L,resource:{type:"refinedstorage:item",item:"minecraft:copper_ingot",components:{}}}}],ingredients:[{input:{input:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:copper_dust",components:{}}},allowedAlternativeIds:[]}}]}] 1

### Gold (alltheores:gold_dust -> minecraft:gold_ingot)
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"processing",id:[I;8110211,8110212,8110213,8110214]},refinedstorage:processing_pattern_state={outputs:[{resource:{amount:1L,resource:{type:"refinedstorage:item",item:"minecraft:gold_ingot",components:{}}}}],ingredients:[{input:{input:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:gold_dust",components:{}}},allowedAlternativeIds:[]}}]}] 1

### Iron (alltheores:iron_dust -> minecraft:iron_ingot)
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"processing",id:[I;8110221,8110222,8110223,8110224]},refinedstorage:processing_pattern_state={outputs:[{resource:{amount:1L,resource:{type:"refinedstorage:item",item:"minecraft:iron_ingot",components:{}}}}],ingredients:[{input:{input:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:iron_dust",components:{}}},allowedAlternativeIds:[]}}]}] 1

### Lead (alltheores:lead_dust -> alltheores:lead_ingot)
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"processing",id:[I;8110231,8110232,8110233,8110234]},refinedstorage:processing_pattern_state={outputs:[{resource:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:lead_ingot",components:{}}}}],ingredients:[{input:{input:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:lead_dust",components:{}}},allowedAlternativeIds:[]}}]}] 1

### Osmium (alltheores:osmium_dust -> alltheores:osmium_ingot)
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"processing",id:[I;8110241,8110242,8110243,8110244]},refinedstorage:processing_pattern_state={outputs:[{resource:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:osmium_ingot",components:{}}}}],ingredients:[{input:{input:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:osmium_dust",components:{}}},allowedAlternativeIds:[]}}]}] 1

### Tin (alltheores:tin_dust -> alltheores:tin_ingot)
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"processing",id:[I;8110251,8110252,8110253,8110254]},refinedstorage:processing_pattern_state={outputs:[{resource:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:tin_ingot",components:{}}}}],ingredients:[{input:{input:{amount:1L,resource:{type:"refinedstorage:item",item:"alltheores:tin_dust",components:{}}},allowedAlternativeIds:[]}}]}] 1

## B. Seven block->ingot buffer patterns (from the worklist, ready-made)
These go in any cabled crafter (your block-pattern bank is perfect).
Commands are in computer 6's .atm10-patterns-needed.txt lines 195-215 —
Brass, Bronze, Dark Steel, Electrum, Enderium, Netherite, Steel.

## After slotting everything
1. Pop each pattern out and back IN once if its crafter was recabled (re-index).
2. Re-run atm10-patterns on computer 6 (Ctrl+T first, `startup` after!) to refresh the worklist.
3. Tell Claude — one bounded approve per new metal verifies each route live.