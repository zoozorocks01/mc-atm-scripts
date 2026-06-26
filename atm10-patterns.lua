-- atm10-patterns.lua : CRAFT-4 patterns worklist. READ-ONLY.
--
-- Run on the manager computer (the one with the RS Bridge): `atm10-patterns`.
-- Lists every stock quota (your inventory-config categories + tapped store) that the
-- RS Bridge cannot craft yet, grouped by category -- so you know exactly which
-- patterns to encode and which Crafters to place. Writes the list to a file you can
-- read with `edit`. NEVER crafts/exports/moves anything; only reads getCraftableItems.

local managed = require("atm10-managed")

local OUT_FILE = ".atm10-patterns-needed.txt"
local CONFIG_FILE = "inventory-config"
local MANAGED_FILE = ".atm10-managed"

local lines = {}
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

-- The set of names RS reports as craftable (the reliable post-probe signal).
local function craftableSet(bridge)
  local set, n = {}, 0
  if bridge and type(bridge.getCraftableItems) == "function" then
    local ok, list = pcall(bridge.getCraftableItems)
    if ok and type(list) == "table" then
      for _, it in ipairs(list) do
        if type(it) == "table" and it.name then set[it.name] = true; n = n + 1 end
      end
    end
  end
  return set, n
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
end

out("=== ATM10 patterns worklist (READ-ONLY) ===")
local bridge = findBridge()
if not bridge then
  out("NO RS BRIDGE on this computer. Run `atm10-patterns` on the manager (the computer")
  out("wired to the RS Bridge).")
  save()
  return
end

local set, nCraft = craftableSet(bridge)
out("RS reports " .. nCraft .. " craftable items (patterns RS can currently see).")

local items = gatherItems()
local need = managed.patternsNeeded(items, function(name) return set[name] == true end)
out("Quotas needing a pattern: " .. #need .. " of " .. #items)
out("")

local cat = nil
for _, it in ipairs(need) do
  if it.category ~= cat then cat = it.category; out("-- " .. tostring(cat) .. " --") end
  out("  " .. it.label .. "   (" .. it.name .. ")")
end

out("")
out("Build a pattern + Crafter for each, then re-run -- the list shrinks as patterns appear.")
out("NOTE: RS craftability introspection can be incomplete, so an item here MIGHT already")
out("craft (verify in-game). Items genuinely missing a pattern are the real targets.")
save()
