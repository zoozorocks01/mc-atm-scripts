# Spawning Refined Storage patterns into the autocrafter (proven method)

How to create RS crafting patterns and get them into the player's autocrafter so
items flip `NO RECIPE` → `WOULD CRAFT` on the manager's PLAN page. **This method is
verified working in-world** (ATM10, MC 1.21.1, `refinedstorage-neoforge-2.0.6`):
the 11 metal-block patterns were spawned this way and the autocraft loop went live.

This is the tooling target for **CRAFT-4** in `IMPROVEMENT_PLAN.md` (patterns
worklist + ID export). Read this before building that.

---

## TL;DR — the flow that works

1. **Construct** a `refinedstorage:pattern` item with two data components:
   `pattern_state` (type + a 4-int id) and `crafting_pattern_state` (the 3×3 input grid).
2. **`/give`** that item to the player (paste in chat as op, or via server console).
3. **Player inserts it into the autocrafter by hand** (shift-click / hopper).
   RS derives the *output* from the recipe — you only specify the inputs.

That's it. RS reads the recipe grid and figures out what it makes.

---

## ⛔ What does NOT work (learned the hard way)

- **Writing the pattern NBT directly into the autocrafter block entity** (`/data
  modify block ...`) does **not** stick. The block entity re-serializes on save and
  clobbers the injected pattern. You must insert the *item* through normal
  insertion (hand/hopper). The crafter registers it on insert.
- **The chunk must be loaded** when you insert (and ideally force-loaded — see
  `README.md` stability section; an unloaded CC chunk also causes the AP crash).
- **Don't guess processing-pattern NBT** — crafting patterns and processing
  patterns are different formats (see "Processing patterns" below).

---

## The exact item structure (crafting pattern)

```
refinedstorage:pattern[
  refinedstorage:pattern_state={type:"crafting",id:[I;3001,9003,15005,21007]},
  refinedstorage:crafting_pattern_state={
    input:{
      input:{height:3,width:3,items:[ {id:"<ingot>",count:1} × 9 ]},
      left:0, top:0
    },
    fuzzyMode:0b
  }
]
```

- `pattern_state.type` = `"crafting"` for a normal recipe-grid pattern.
- `pattern_state.id` = `[I; a,b,c,d]` — four signed ints, an internal handle. They
  just need to be present and **distinct per pattern** (collisions risk confusion).
  Scheme used for the blocks: `3000+n, 9000+3n, 15000+5n, 21000+7n` for pattern n.
  RS does **not** use the id to pick the output — the recipe grid does.
- `crafting_pattern_state.input.input.items` = the 3×3 grid, **row-major, 9 entries**
  (a shapeless/shaped recipe both fill all 9 for a block; for shaped recipes place
  items in the correct cells and use `minecraft:air`/omit for empties as the recipe
  needs). `count:1` per slot. `height`/`width` = 3.
- `fuzzyMode:0b` = exact-match inputs.
- No output is specified — RS resolves it from the matched recipe.

### Verified example — `lead_block` (9 lead ingot → 1 lead block)

```
/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"crafting",id:[I;3001,9003,15005,21007]},refinedstorage:crafting_pattern_state={input:{input:{height:3,width:3,items:[{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1}]},left:0,top:0},fuzzyMode:0b}] 1
```

Full set of 11 metal blocks: `~/Downloads/atm10-block-patterns_give-commands_20260625.md`.

---

## Two ways to deliver the `/give`

1. **Player pastes in chat in-game** (as op): copy the `/give @s ...` line into the
   chat/command bar. Simplest; no server access needed.
2. **Server console** (how the agent did it remotely): SSH to the server box and
   inject into the screen session, e.g.
   `screen -S atm10-intel-main-25566 -p 0 -X stuff "give Zoozorocks refinedstorage:pattern[...]$(printf '\r')"`.
   Note: server SSH signs **only** via the 1Password agent — if it fails, the user
   must unlock 1Password (see the team memory note on SSH access). `git push` is
   HTTPS and unaffected.

After inserting all patterns, confirm on the manager PLAN page that the items show
`WOULD CRAFT` (or are auto-approved/crafting in `auto`/after APPROVE ALL).

---

## ⚠️ Processing patterns (dust → ingot, alloys) are DIFFERENT

The above is for **crafting-table** recipes. Machine recipes (e.g. copper dust →
copper ingot in a furnace/smelter, or alloy-smelter/infuser alloys) use a
**processing** pattern with explicit `inputs` + `outputs` (not a recipe grid), and
the `type` is not `"crafting"`. **Do not hand-author these from guesswork** — the
exact component shape varies. Proven approach:

1. Have the operator make **one** processing pattern in-world (e.g. copper dust →
   copper ingot) using an RS Pattern Grid / the autocrafter UI.
2. Read its exact NBT (give it to an op and inspect, or `/data get` the held item),
   capture the real `pattern_state.type` + the inputs/outputs structure.
3. Clone that structure for the other materials (swap the item ids).

This was the planned next step and is still **in-game-gated** until that one
reference pattern exists.

---

## Why this matters for the codebase

`getCraftableItems` / the RS craftability export read blind in some states
(craftable rows can report 0 even when crafting works), so the manager can't
always *see* which patterns exist. **CRAFT-3** (validate quota IDs: UNKNOWN vs
NO-PATTERN) and **CRAFT-4** (a shrinking pattern-setup worklist + registry-ID
export) in `IMPROVEMENT_PLAN.md` are the tooling to turn this manual `/give`
process into a guided checklist. This doc is the ground truth for the *format* that
tooling should emit.
