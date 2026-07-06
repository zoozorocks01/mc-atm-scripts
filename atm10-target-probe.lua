-- atm10-target-probe.lua : READ-ONLY per-item RS inventory/craftability probe.
--
-- Run on the manager computer (`atm10-target-probe`). It reports exact current
-- getItems totals for a focused list of suspect ingot/block/dust IDs and writes
-- .atm10-target-probe.txt. It never crafts, imports, exports, or moves items.

local OUT_FILE = ".atm10-target-probe.txt"

local DEFAULT_TARGETS = {
  "minecraft:gold_ingot",
  "minecraft:gold_block",
  "alltheores:gold_dust",
  "alltheores:gold_tiny_dust",
  "minecraft:iron_ingot",
  "minecraft:iron_block",
  "alltheores:iron_dust",
  "alltheores:iron_tiny_dust",
  "minecraft:copper_ingot",
  "minecraft:copper_block",
  "alltheores:copper_dust",
  "alltheores:copper_tiny_dust",
  "alltheores:steel_ingot",
  "alltheores:steel_block",
  "alltheores:steel_dust",
  "alltheores:tin_ingot",
  "alltheores:tin_block",
  "alltheores:tin_dust",
  "alltheores:zinc_ingot",
  "alltheores:zinc_block",
  "alltheores:zinc_dust",
}

local lines = {}
local function out(s)
  s = (s == nil) and "" or tostring(s)
  lines[#lines + 1] = s
  print(s)
end

local function save()
  local f = fs.open(OUT_FILE, "w")
  if f then
    f.write(table.concat(lines, "\n"))
    f.close()
    print("")
    print("Report saved to " .. OUT_FILE)
  end
end

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

local function tryCall(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return false, "(absent)" end
  return pcall(obj[method], ...)
end

local function amountOf(item)
  if type(item) ~= "table" then return 0 end
  return tonumber(item.amount or item.count or item.quantity or item.qty or 0) or 0
end

local function valueText(ok, value)
  if not ok then return "ERROR:" .. tostring(value) end
  if value == nil then return "nil" end
  if type(value) == "table" then return "table:" .. tostring(amountOf(value)) end
  return tostring(value)
end

local function displayName(item)
  if type(item) ~= "table" then return "" end
  return tostring(item.displayName or item.name or "")
end

local function rawCount(list)
  if type(list) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(list) do n = n + 1 end
  return n
end

local function rawdesc(value, limit)
  limit = tonumber(limit) or 240
  local text
  if type(value) == "table" and textutils and textutils.serialize then
    local ok, encoded = pcall(textutils.serialize, value)
    if ok then text = encoded end
  end
  text = text or tostring(value)
  text = text:gsub("\n", " "):gsub("%s+", " ")
  if #text > limit then text = text:sub(1, limit - 3) .. "..." end
  return text
end

local function namesInPattern(pattern, wanted)
  local matched = {}
  local function visit(value, depth)
    if depth > 7 then return end
    local tv = type(value)
    if tv == "string" then
      if wanted[value] then matched[value] = true end
    elseif tv == "table" then
      for k, v in pairs(value) do
        visit(k, depth + 1)
        visit(v, depth + 1)
      end
    end
  end
  visit(pattern, 0)
  local names = {}
  for name in pairs(matched) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function aggregate(items, wanted)
  local byName = {}
  if type(items) ~= "table" then return byName end
  for _, item in pairs(items) do
    if type(item) == "table" and wanted[item.name] then
      local rec = byName[item.name]
      if not rec then
        rec = { rows = 0, amount = 0, itemCraftable = false, label = displayName(item) }
        byName[item.name] = rec
      end
      rec.rows = rec.rows + 1
      rec.amount = rec.amount + amountOf(item)
      if item.isCraftable == true then rec.itemCraftable = true end
      if rec.label == "" then rec.label = displayName(item) end
    end
  end
  return byName
end

local function targetsFromArgs(args)
  if type(args) ~= "table" or #args == 0 then return DEFAULT_TARGETS end
  local result = {}
  for _, arg in ipairs(args) do
    if type(arg) == "string" and arg ~= "" then result[#result + 1] = arg end
  end
  if #result == 0 then return DEFAULT_TARGETS end
  return result
end

local args = { ... }
local targets = targetsFromArgs(args)
local wanted = {}
for _, name in ipairs(targets) do wanted[name] = true end

out("=== ATM10 target item probe (READ-ONLY) ===")
if os.epoch then out("at_ms: " .. tostring(os.epoch("utc"))) end

local bridge, btype, bname = findBridge()
if not bridge then
  out("NO BRIDGE FOUND. Attached peripherals:")
  for _, name in ipairs(peripheral.getNames()) do
    out("  " .. name .. " -> " .. tostring(peripheral.getType(name)))
  end
  save()
  return
end

out("bridge: " .. tostring(bname) .. " (type " .. tostring(btype) .. ")")
out("targets: " .. tostring(#targets))

local okItems, items = tryCall(bridge, "getItems")
out("getItemsRows: " .. (okItems and tostring(rawCount(items)) or valueText(okItems, items)))
local stored = aggregate(okItems and items or {}, wanted)

local okCraftable, craftableItems = tryCall(bridge, "getCraftableItems")
out("getCraftableItemsRows: " .. (okCraftable and tostring(rawCount(craftableItems)) or valueText(okCraftable, craftableItems)))
local craftable = aggregate(okCraftable and craftableItems or {}, wanted)

local okTasks, tasks = tryCall(bridge, "getCraftingTasks")
out("getCraftingTasksRows: " .. (okTasks and tostring(rawCount(tasks)) or valueText(okTasks, tasks)))

local okPatterns, patterns = tryCall(bridge, "getPatterns")
out("getPatternsRows: " .. (okPatterns and tostring(rawCount(patterns)) or valueText(okPatterns, patterns)))

out("")
out("name\tstored\tstoredRows\tcraftableRows\titemCraftableFlag\tgetItem\tisCraftable\tisCrafting\tdisplayName")
for _, name in ipairs(targets) do
  local s = stored[name] or { rows = 0, amount = 0, itemCraftable = false, label = "" }
  local c = craftable[name] or { rows = 0 }
  local okGetItem, gotItem = tryCall(bridge, "getItem", { name = name })
  local okIsCraftable, isCraftable = tryCall(bridge, "isCraftable", { name = name })
  local okIsCrafting, isCrafting = tryCall(bridge, "isCrafting", { name = name })
  out(table.concat({
    name,
    tostring(s.amount),
    tostring(s.rows),
    tostring(c.rows),
    tostring(s.itemCraftable),
    valueText(okGetItem, gotItem),
    valueText(okIsCraftable, isCraftable),
    valueText(okIsCrafting, isCrafting),
    s.label,
  }, "\t"))
end

out("")
out("-- pattern matches (read-only getPatterns) --")
if okPatterns and type(patterns) == "table" then
  local matches = 0
  for idx, pattern in pairs(patterns) do
    local names = namesInPattern(pattern, wanted)
    if #names > 0 then
      matches = matches + 1
      out("pattern[" .. tostring(idx) .. "] matches " .. table.concat(names, ", ") .. " :: " .. rawdesc(pattern, 320))
      if matches >= 40 then
        out("pattern match output truncated at 40 rows")
        break
      end
    end
  end
  if matches == 0 then out("no target names found in getPatterns output") end
else
  out("getPatterns unavailable: " .. valueText(okPatterns, patterns))
end

out("")
out("Safety: craftItem/exportItem/importItem were not called.")
save()
