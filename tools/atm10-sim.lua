#!/usr/bin/env lua
-- Host-side scenario runner for the local ATM10 manager simulator.
--
-- Examples:
--   lua tools/atm10-sim.lua list
--   lua tools/atm10-sim.lua approval-aluminum
--   lua tools/atm10-sim.lua approval-aluminum alltheores:aluminum_ingot

package.path = "./tests/?.lua;./lib/?.lua;" .. package.path

local sim = require("sim.manager_sim")

local function sortedKeys(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function dumpValue(value, indent)
  indent = indent or ""
  if type(value) ~= "table" then
    print(indent .. tostring(value))
    return
  end
  for _, key in ipairs(sortedKeys(value)) do
    local v = value[key]
    if type(v) == "table" then
      print(indent .. tostring(key) .. ":")
      dumpValue(v, indent .. "  ")
    else
      print(indent .. tostring(key) .. ": " .. tostring(v))
    end
  end
end

local scenarios = {}

scenarios["approval-aluminum"] = function(target)
  target = target or "alltheores:aluminum_ingot"
  local bridge = sim.bridge({
    items = {
      { name = "alltheores:aluminum_ingot", amount = 1000, isCraftable = true },
      { name = "alltheores:aluminum_dust", amount = 5000, isCraftable = false },
      { name = "alltheores:tiny_aluminum_dust", amount = 12000, isCraftable = false },
      { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
    },
  })
  local runner = sim.new({
    bridge = bridge,
    managedStore = {
      items = {
        ["alltheores:aluminum_ingot"] = {
          name = "alltheores:aluminum_ingot",
          label = "Aluminum Ingot",
          target = 5000,
          craftTo = 5000,
        },
        ["alltheores:aluminum_dust"] = {
          name = "alltheores:aluminum_dust",
          label = "Aluminum Dust",
          target = 0,
          craftTo = 1,
          ceiling = 1000,
          into = { name = "alltheores:aluminum_ingot", label = "Aluminum Ingot" },
          ratio = 1,
        },
      },
      settings = { modeOverride = "manual" },
    },
    approveRequest = { target = target, requestedAt = 1 },
    events = { { "timer", 1 } },
  })

  local result = runner:run()
  local reachedSentinel = result.ok == false and tostring(result.err):find(result.sentinel, 1, true) ~= nil
  print("scenario: approval-aluminum")
  print("target: " .. tostring(target))
  print("cycleStoppedAtSentinel: " .. tostring(reachedSentinel))
  if not reachedSentinel then print("error: " .. tostring(result.err)) end

  print("")
  print("approveResult:")
  dumpValue(runner:getSerializedFile(".atm10-approve-result") or {})

  print("")
  print("queueEntries:")
  local queue = runner:getSerializedFile(".atm10-craft-queue")
  dumpValue((queue and queue.entries) or {})

  print("")
  print("crafted:")
  dumpValue(result.crafted)

  local approveResult = runner:getSerializedFile(".atm10-approve-result")
  local queueEntry = queue and queue.entries and queue.entries["alltheores:aluminum_ingot"]
  return reachedSentinel
    and type(approveResult) == "table"
    and approveResult.ok == true
    and type(queueEntry) == "table"
    and queueEntry.key == "alltheores:aluminum_ingot"
end

local function usage()
  print("Usage:")
  print("  lua tools/atm10-sim.lua list")
  print("  lua tools/atm10-sim.lua <scenario> [args...]")
  print("")
  print("Scenarios:")
  for _, name in ipairs(sortedKeys(scenarios)) do print("  " .. name) end
end

local scenario = arg[1] or "list"
if scenario == "list" or scenario == "help" or scenario == "--help" then
  usage()
  os.exit(0)
end

local fn = scenarios[scenario]
if not fn then
  usage()
  os.exit(2)
end

local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
local ok = fn(table.unpack(args))
os.exit(ok and 0 or 1)
