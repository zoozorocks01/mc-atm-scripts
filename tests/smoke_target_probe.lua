-- Off-CC runtime smoke for atm10-target-probe.lua.
-- Verifies the focused item probe aggregates getItems rows, checks read-only
-- craftability methods, writes the report, and never calls mutating bridge APIs.

local realExit = os.exit
local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

local files = {}
_G.fs = {
  open = function(path, mode)
    if mode == "r" then
      if not files[path] then return nil end
      return { readAll = function() return files[path] end, close = function() end }
    end
    return { write = function(text) files[path] = tostring(text or "") end, close = function() end }
  end,
}

local mutatingCalls = 0
local bridge = {
  getItems = function()
    return {
      { name = "minecraft:gold_ingot", count = 90000, displayName = "Gold Ingot", isCraftable = true },
      { name = "minecraft:gold_ingot", count = 473, displayName = "Gold Ingot", isCraftable = false },
      { name = "alltheores:gold_dust", amount = 250000, displayName = "Gold Dust", isCraftable = false },
      { name = "alltheores:steel_block", count = 128, displayName = "Steel Block", isCraftable = true },
      { name = "minecraft:dirt", count = 1, displayName = "Dirt", isCraftable = false },
    }
  end,
  getItem = function(arg)
    if type(arg) == "table" and arg.name == "minecraft:gold_block" then
      return { name = "minecraft:gold_block", count = 42, displayName = "Block of Gold" }
    end
    return nil
  end,
  getCraftableItems = function()
    return {
      { name = "minecraft:gold_ingot", count = 1, displayName = "Gold Ingot" },
      { name = "minecraft:gold_block", count = 1, displayName = "Block of Gold" },
      { name = "alltheores:steel_block", count = 1, displayName = "Steel Block" },
    }
  end,
  getCraftingTasks = function()
    return { { id = 9, item = { name = "minecraft:gold_ingot" } } }
  end,
  getPatterns = function()
    return {
      { output = { name = "minecraft:gold_ingot" }, input = { name = "alltheores:gold_dust" }, kind = "smelt" },
      { output = { name = "minecraft:gold_block" }, input = { name = "minecraft:gold_ingot" }, kind = "compress" },
      { output = { name = "minecraft:diamond" }, input = { name = "minecraft:coal" }, kind = "other" },
    }
  end,
  isCraftable = function(arg)
    return type(arg) == "table" and (arg.name == "minecraft:gold_ingot" or arg.name == "minecraft:gold_block")
  end,
  isCrafting = function(arg)
    return type(arg) == "table" and arg.name == "minecraft:gold_ingot"
  end,
  craftItem = function() mutatingCalls = mutatingCalls + 1; error("must not craft", 0) end,
  exportItem = function() mutatingCalls = mutatingCalls + 1; error("must not export", 0) end,
  importItem = function() mutatingCalls = mutatingCalls + 1; error("must not import", 0) end,
}

_G.peripheral = {
  getNames = function() return { "bottom" } end,
  getType = function(name) return name == "bottom" and "rs_bridge" or "unknown" end,
  wrap = function(name) return name == "bottom" and bridge or nil end,
}

local realOs = os
_G.os = {
  exit = realExit,
  epoch = function() return 123456789 end,
}

print("smoke-target-probe: running atm10-target-probe.lua against fake RS Bridge")
local ok, err = pcall(function() dofile("atm10-target-probe.lua") end)
check(ok == true, "target probe completed without error: " .. tostring(err))

local report = files[".atm10-target-probe.txt"] or ""
check(report:find("getItemsRows: 5", 1, true) ~= nil, "probe reports getItems row count")
check(report:find("getCraftableItemsRows: 3", 1, true) ~= nil, "probe reports getCraftableItems row count")
check(report:find("getCraftingTasksRows: 1", 1, true) ~= nil, "probe reports task row count")
check(report:find("getPatternsRows: 3", 1, true) ~= nil, "probe reports pattern row count")
check(report:find("minecraft:gold_ingot\t90473\t2\t1\ttrue", 1, true) ~= nil,
  "probe aggregates duplicate gold ingot rows")
check(report:find("alltheores:gold_dust\t250000\t1\t0\tfalse", 1, true) ~= nil,
  "probe reports gold dust amount")
check(report:find("minecraft:gold_block\t0\t0\t1\tfalse\ttable:42\ttrue", 1, true) ~= nil,
  "probe includes getItem and isCraftable signals")
check(report:find("pattern[1] matches alltheores:gold_dust, minecraft:gold_ingot", 1, true) ~= nil,
  "probe reports pattern route names that mention targets")
check(report:find("pattern[2] matches minecraft:gold_block, minecraft:gold_ingot", 1, true) ~= nil,
  "probe reports multiple matching pattern routes")
check(mutatingCalls == 0, "probe never calls mutating bridge methods")
check(report:find("Safety: craftItem/exportItem/importItem were not called.", 1, true) ~= nil,
  "probe writes explicit safety line")

_G.os = realOs
print((failures == 0) and "SMOKE-TARGET-PROBE OK" or ("SMOKE-TARGET-PROBE FAILED (" .. failures .. ")"))
realExit(failures == 0 and 0 or 1)
