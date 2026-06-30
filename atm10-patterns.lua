-- atm10-patterns.lua : CRAFT-4 patterns worklist. READ-ONLY.
--
-- Run on the manager computer (the one with the RS Bridge): `atm10-patterns`.
-- Lists every stock quota (your inventory-config categories + tapped store) that the
-- RS Bridge cannot craft yet, grouped by category -- so you know exactly which
-- patterns to encode and which Crafters to place. Writes the list to a file you can
-- read with `edit`. NEVER crafts/exports/moves anything; only reads getCraftableItems.

local managed = require("atm10-managed")
-- Optional: a missing atm10-pattern-give (e.g. not yet deployed -- update fetches a
-- newly-added manifest file only on the SECOND run) must NOT crash the tool. pcall it
-- and just skip the /give section if absent.
local okPgive, pgive = pcall(require, "atm10-pattern-give")
if not okPgive then pgive = nil end

local OUT_FILE = ".atm10-patterns-needed.txt"
local ID_FILE = ".atm10-pattern-ids.txt"
local CONFIG_FILE = "inventory-config"
local MANAGED_FILE = ".atm10-managed"

local lines = {}
local idLines = {}
local function out(s)
  s = (s == nil) and "" or tostring(s)
  lines[#lines + 1] = s
  print(s)
end

local function findBridge()
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t == "rs_bridge" or t == "rsBridge"
        or (type(t) == "string" and t:lower():find("bridge")) then
      return peripheral.wrap(name)
    end
  end
  return nil
end

-- What RS reports as craftable: a name->true set (for filtering) AND a sorted list
-- (name + display label) so we can show the patterns you already HAVE.
local function craftableInfo(bridge)
  local set, list = {}, {}
  if bridge and type(bridge.getCraftableItems) == "function" then
    local ok, items = pcall(bridge.getCraftableItems)
    if ok and type(items) == "table" then
      for _, it in ipairs(items) do
        if type(it) == "table" and it.name then
          set[it.name] = true
          list[#list + 1] = { name = it.name, label = it.displayName or it.name }
        end
      end
    end
  end
  table.sort(list, function(a, b) return tostring(a.label):lower() < tostring(b.label):lower() end)
  return set, list
end

-- Combined quota list: config categories (categorized) + tapped store (category "Tapped").
local function gatherItems()
  local items = {}
  local ok, cfg = pcall(dofile, CONFIG_FILE)
  if ok and type(cfg) == "table" and type(cfg.stockKeeper) == "table" then
    for _, cat in ipairs(cfg.stockKeeper.categories or {}) do
      for _, it in ipairs(cat.items or {}) do
        if it.name then
          items[#items + 1] = { name = it.name, label = it.label or it.name, category = cat.label or "Config" }
        end
      end
    end
  end
  if fs.exists(MANAGED_FILE) then
    local f = fs.open(MANAGED_FILE, "r")
    local text = f and f.readAll()
    if f then f.close() end
    local okm, store = pcall(textutils.unserialize, text or "")
    if okm and type(store) == "table" then
      for _, e in ipairs(managed.list(store)) do
        items[#items + 1] = { name = e.name, label = e.label or e.name, category = "Tapped" }
      end
    end
  end
  return items
end

local function save()
  local f = fs.open(OUT_FILE, "w")
  if f then f.write(table.concat(lines, "\n")); f.close(); print(""); print("Saved to " .. OUT_FILE) end
  local ids = fs.open(ID_FILE, "w")
  if ids then ids.write(table.concat(idLines, "\n")); ids.close(); print("Saved IDs to " .. ID_FILE) end
end

out("=== ATM10 patterns worklist (READ-ONLY) ===")
local bridge = findBridge()
if not bridge then
  out("NO RS BRIDGE on this computer. Run `atm10-patterns` on the manager (the computer")
  out("wired to the RS Bridge).")
  save()
  return
end

local set, have = craftableInfo(bridge)
local items = gatherItems()
local need = managed.patternsNeeded(items, function(name) return set[name] == true end)
out("RS HAS " .. #have .. " patterns. Quotas still needing one: " .. #need .. ".")
out("")

out("-- PATTERNS RS HAS (" .. #have .. ") --")
for _, it in ipairs(have) do
  out("  " .. it.label .. "   (" .. it.name .. ")")
end
out("")
out("== PATTERNS TO BUILD (" .. #need .. ", deduped) ==")

local cat = nil
for _, it in ipairs(need) do
  if it.category ~= cat then cat = it.category; out("-- " .. tostring(cat) .. " --") end
  idLines[#idLines + 1] = it.name
  out("  " .. it.label .. "   (" .. it.name .. ")")
  if pgive and pgive.hintForItem then
    local hint = pgive.hintForItem(it.name)
    if hint and hint.text then out("    hint: " .. hint.text) end
  end
end

-- Ready-to-paste /give commands for the patterns we can DERIVE (block compress /
-- ingot uncompress). Paste each in chat as op, then insert the pattern into the
-- autocrafter by hand. Items without a *_ingot/*_block suffix are NOT auto-derivable
-- (processing patterns like dust->ingot still need an in-world reference -- see
-- docs/RS_PATTERN_SPAWNING.md).
if not pgive then
  out("")
  out("(/give emission unavailable: atm10-pattern-give not deployed -- run `update` again)")
else
  local gives = pgive.emitForItems(need)
  out("")
  out("== /GIVE COMMANDS (" .. #gives .. " derivable: block compress / ingot uncompress) ==")
  if #gives == 0 then
    out("  (none of the needed items are a *_ingot/*_block we can derive a pattern for)")
  else
    for _, g in ipairs(gives) do
      out("-- " .. g.label .. " [" .. g.kind .. "]")
      out(g.command)
    end
  end
end

out("")
out("Build a pattern + Crafter for each, then re-run -- the list shrinks as patterns appear.")
out("IDs-only copy list is saved to " .. ID_FILE .. ".")
out("NOTE: RS craftability introspection can be incomplete, so an item here MIGHT already")
out("craft (verify in-game). Items genuinely missing a pattern are the real targets.")
save()
