-- atm10-bridge-probe.lua : READ-ONLY Refined Storage / RS Bridge API probe.
--
-- Run on the manager computer (`atm10-bridge-probe`). Reports the EXACT methods +
-- return shapes the Advanced Peripherals RS Bridge exposes on THIS pack, so the
-- autocraft scripts can stop guessing the craftItem / exportItem / isItemCrafting /
-- getItems signatures.
--
-- SAFETY: this NEVER crafts, exports, imports, or moves anything. It only calls
-- methods known to be read-only (isConnected / isOnline / getItems /
-- getCraftableItems / storage + energy getters). Mutating methods (craftItem /
-- exportItem / importItem) are reported as present/absent ONLY -- never invoked.

local OUT_FILE = ".atm10-bridge-probe.txt"
local lines = {}
local function out(s)
  s = (s == nil) and "" or tostring(s)
  lines[#lines + 1] = s
  print(s)
end

-- Find the bridge by scanning every attached peripheral (reliable: also gives us
-- the network name so we can use peripheral.getMethods()).
local function findBridge()
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t == "rs_bridge" or t == "rsBridge" or t == "me_bridge"
        or (type(t) == "string" and t:lower():find("bridge")) then
      return peripheral.wrap(name), t, name
    end
  end
  return nil
end

local function typedesc(v)
  local t = type(v)
  if t == "table" then
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return "table(" .. n .. " keys)"
  end
  if t == "string" then return 'string "' .. v .. '"' end
  return t .. " " .. tostring(v)
end

-- describe a record's field names + value types (so we learn the item table shape)
local function shape(rec)
  if type(rec) ~= "table" then return tostring(rec) end
  local keys = {}
  for k, v in pairs(rec) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end
  table.sort(keys)
  return "{ " .. table.concat(keys, ", ") .. " }"
end

local function tryCall(bridge, method, ...)
  if type(bridge[method]) ~= "function" then return false, "(absent)" end
  return pcall(bridge[method], ...)
end

local function save()
  local f = fs.open(OUT_FILE, "w")
  if f then f.write(table.concat(lines, "\n")); f.close(); print(""); print("Report saved to " .. OUT_FILE) end
end

out("=== ATM10 RS Bridge probe (READ-ONLY) ===")
local bridge, btype, bname = findBridge()
if not bridge then
  out("NO BRIDGE FOUND. Attach an RS Bridge (Advanced Peripherals) to this computer.")
  out("Attached peripherals:")
  for _, name in ipairs(peripheral.getNames()) do
    out("  " .. name .. "  ->  " .. tostring(peripheral.getType(name)))
  end
  save()
  return
end
out("bridge: " .. tostring(bname) .. "  (type " .. tostring(btype) .. ")")

-- 1) every method the bridge exposes (canonical list, falls back to key scan)
out("")
out("--- methods exposed ---")
local methods = (peripheral.getMethods and peripheral.getMethods(bname)) or nil
if type(methods) ~= "table" then
  methods = {}
  for k, v in pairs(bridge) do if type(v) == "function" then methods[#methods + 1] = k end end
end
table.sort(methods)
out(table.concat(methods, ", "))

-- 2) presence of the methods the autocraft scripts care about
out("")
out("--- key methods present? ---")
local WANT = {
  "getItems", "getItem", "getItemDetail", "isItemCraftable", "isCraftable",
  "isItemCrafting", "isCrafting", "getCraftableItems", "craftItem",
  "getCraftingTasks", "getTasks", "listCraftingTasks", "getCraftingTask",
  "exportItem", "exportItemToPeripheral", "importItem", "importItemFromPeripheral",
  "isConnected", "isOnline", "getStoredEnergy", "getEnergyStorage",
  "getUsedItemStorage", "getTotalItemStorage", "getMaxItemDiskStorage",
}
for _, m in ipairs(WANT) do
  out(string.format("  %-26s %s", m, type(bridge[m]) == "function" and "YES" or "no"))
end

-- 3) read-only probes (safe to call)
out("")
out("--- read-only sample calls ---")
local ok, v
ok, v = tryCall(bridge, "isConnected"); out("isConnected -> " .. typedesc(v))
ok, v = tryCall(bridge, "isOnline"); out("isOnline -> " .. typedesc(v))

ok, v = tryCall(bridge, "getItems")
if ok and type(v) == "table" then
  out("getItems -> table with " .. #v .. " items")
  if v[1] then
    out("  item[1] shape:  " .. shape(v[1]))
    out("  item[1] values: name=" .. tostring(v[1].name) ..
      " amount=" .. tostring(v[1].amount or v[1].count) ..
      " isCraftable=" .. tostring(v[1].isCraftable))
  end
else
  out("getItems -> " .. typedesc(v))
end

if type(bridge.getCraftableItems) == "function" then
  ok, v = tryCall(bridge, "getCraftableItems")
  if ok and type(v) == "table" then
    out("getCraftableItems -> table with " .. #v .. " items" .. (v[1] and ("; [1] " .. shape(v[1])) or ""))
  else
    out("getCraftableItems -> " .. typedesc(v))
  end
else
  out("getCraftableItems -> (method absent)")
end

-- 3b) crafting-task introspection (CRAFT-1): the exact shape of in-flight RS craft
-- tasks (made/requested/progress) is unconfirmed and gates CRAFT-2. Probe every
-- likely accessor + isItemCrafting. All read-only -- never crafts.
out("")
out("--- crafting-task introspection (read-only) ---")
local probeName = nil
do
  local okItems, items = tryCall(bridge, "getItems")
  if okItems and type(items) == "table" and items[1] then probeName = items[1].name end
end
for _, m in ipairs({ "getCraftingTasks", "getTasks", "listCraftingTasks", "getCraftingTask" }) do
  if type(bridge[m]) == "function" then
    ok, v = tryCall(bridge, m)
    if ok and type(v) == "table" then
      out(m .. " -> table with " .. #v .. " entries")
      if v[1] then
        out("  [1] shape:  " .. shape(v[1]))
        -- a task usually nests the item + amounts; dump one level deeper
        for k, val in pairs(v[1]) do
          if type(val) == "table" then out("    ." .. tostring(k) .. " shape: " .. shape(val)) end
        end
      end
    else
      out(m .. " -> " .. typedesc(v))
    end
  else
    out(m .. " -> (method absent)")
  end
end

-- isItemCrafting(name): probe with a live grid item + a known-pattern id (per base
-- recon vibrant alloy crafts), so we capture the arg form + the true/false returns.
for _, m in ipairs({ "isItemCrafting", "isCrafting" }) do
  if type(bridge[m]) == "function" then
    if probeName then
      ok, v = tryCall(bridge, m, { name = probeName })
      out(m .. '({name="' .. tostring(probeName) .. '"}) -> ' .. typedesc(v))
    end
    ok, v = tryCall(bridge, m, { name = "enderio:vibrant_alloy_ingot" })
    out(m .. '({name="enderio:vibrant_alloy_ingot"}) -> ' .. typedesc(v))
  else
    out(m .. " -> (method absent)")
  end
end

ok, v = tryCall(bridge, "getStoredEnergy"); out("getStoredEnergy -> " .. typedesc(v))

-- 4) mutating methods: report presence ONLY, never call
out("")
out("--- mutating methods (NOT called) ---")
for _, m in ipairs({ "craftItem", "exportItem", "exportItemToPeripheral", "importItem" }) do
  out(string.format("  %-26s %s", m, type(bridge[m]) == "function" and "present" or "absent"))
end
out("")
out("NOTE: craftItem / exportItem arg + return shapes can only be confirmed by an")
out("actual call. To test craftItem safely, pick an item you HAVE a pattern for and")
out("in the Lua REPL run (replace the id with your item):")
out('  local b = peripheral.find("' .. tostring(btype) .. '")')
out('  print(textutils.serialize(b.craftItem({name="minecraft:oak_planks", count=1})))')
out("then report the printed return value (boolean? table? what fields?).")

save()
