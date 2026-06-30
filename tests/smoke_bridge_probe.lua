-- Off-CC runtime smoke for atm10-bridge-probe.lua. The compile suite only
-- loadfile()s it; this actually runs the diagnostic against a fake RS Bridge and
-- verifies the CRAFT-1 task-introspection report is written.
--
-- Run: lua tests/smoke_bridge_probe.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local realExit = os.exit
local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

local files = {
  [".atm10-craft-queue"] = "QUEUE",
}
_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode == "r" then
      if not files[path] then return nil end
      return { readAll = function() return files[path] end, close = function() end }
    end
    return { write = function(text) files[path] = tostring(text or "") end, close = function() end }
  end,
}

local function simpleSerialize(value)
  if type(value) ~= "table" then return tostring(value) end
  local out = {}
  for k, v in pairs(value) do out[#out + 1] = tostring(k) .. "=" .. simpleSerialize(v) end
  table.sort(out)
  return "{" .. table.concat(out, ",") .. "}"
end

_G.textutils = {
  serialize = simpleSerialize,
  unserialize = function(text)
    if text == "QUEUE" then
      return { entries = {
        q1 = { name = "alltheores:zinc_ingot" },
      } }
    end
    return {}
  end,
}

local bridge = {
  isConnected = function() return true end,
  isOnline = function() return true end,
  getItems = function()
    return { { name = "minecraft:iron_ingot", amount = 64, isCraftable = true } }
  end,
  getCraftableItems = function()
    return { { name = "minecraft:iron_ingot" } }
  end,
  getCraftingTasks = function()
    return {
      {
        bridge_id = 42,
        id = "task-42",
        quantity = 64,
        completion = 0.25,
        crafted = 12,
        resource = { name = "alltheores:zinc_block", count = 64 },
      },
    }
  end,
  getCraftingTask = function(id)
    if id == nil then error("task id required", 0) end
    if id == 42 then return { id = 42, state = "crafting" } end
    return nil
  end,
  isItemCrafting = function(arg)
    return type(arg) == "table" and arg.name == "minecraft:iron_ingot"
  end,
  isCrafting = function(arg)
    return type(arg) == "string" and (arg == "minecraft:iron_ingot" or arg == "alltheores:zinc_block")
  end,
  getStoredEnergy = function() return 1000 end,
  craftItem = function() error("mutating method must not be called", 0) end,
  exportItem = function() error("mutating method must not be called", 0) end,
  importItem = function() error("mutating method must not be called", 0) end,
}

_G.peripheral = {
  getNames = function() return { "rs_bridge_0" } end,
  getType = function(name) return name == "rs_bridge_0" and "rs_bridge" or "unknown" end,
  wrap = function(name) return name == "rs_bridge_0" and bridge or nil end,
  getMethods = function()
    return {
      "isConnected", "isOnline", "getItems", "getCraftableItems",
      "getCraftingTasks", "getCraftingTask", "isItemCrafting", "isCrafting",
      "getStoredEnergy", "craftItem", "exportItem", "importItem",
    }
  end,
}

print("smoke-bridge-probe: running atm10-bridge-probe.lua against fake RS Bridge")
local ok, err = pcall(function() dofile("atm10-bridge-probe.lua") end)
check(ok == true, "bridge probe completed without error: " .. tostring(err))

local report = files[".atm10-bridge-probe.txt"] or ""
check(report:find("getCraftingTasks() -> table with 1 entries", 1, true) ~= nil,
  "probe reports task-list entry count")
check(report:find("raw sample:", 1, true) ~= nil,
  "probe writes a bounded raw task sample")
check(report:find("getCraftingTask(.bridge_id=42) -> table", 1, true) ~= nil,
  "probe retries getCraftingTask with sampled bridge_id")
check(report:find('isCrafting("alltheores:zinc_block") -> boolean true', 1, true) ~= nil,
  "probe checks task resource name in isCrafting")
check(report:find('isItemCrafting({name="minecraft:iron_ingot",count=1})', 1, true) ~= nil,
  "probe checks table+count isItemCrafting argument form")
check(report:find('isCrafting("minecraft:iron_ingot") -> boolean true', 1, true) ~= nil,
  "probe checks string isCrafting argument form")
check(report:find("activeCraftCount(probeNames=", 1, true) ~= nil
    or report:find("activeCraftCount -> unavailable", 1, true) ~= nil,
  "probe records activeCraftCount summary or explicit unavailability")

print((failures == 0) and "SMOKE-BRIDGE-PROBE OK" or ("SMOKE-BRIDGE-PROBE FAILED (" .. failures .. ")"))
realExit(failures == 0 and 0 or 1)
