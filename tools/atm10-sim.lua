#!/usr/bin/env lua
-- Host-side scenario runner for the local ATM10 manager simulator.
--
-- Examples:
--   lua tools/atm10-sim.lua list
--   lua tools/atm10-sim.lua all
--   lua tools/atm10-sim.lua approval-aluminum alltheores:aluminum_ingot

package.path = "./tests/?.lua;./lib/?.lua;" .. package.path

local scenarios = require("sim.scenarios")

local function sortedKeys(tbl)
  local keys = {}
  for k in pairs(tbl or {}) do keys[#keys + 1] = k end
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

local function serialized(report, path)
  return report and report.runner and report.runner:getSerializedFile(path) or nil
end

local function printChecks(report)
  for _, c in ipairs(report.checks or {}) do
    print(string.format("  %s %s", c.ok and "ok:" or "FAIL:", c.msg))
  end
end

local function printReport(report)
  print("scenario: " .. tostring(report.name))
  if report.description then print("description: " .. report.description) end
  print("target: " .. tostring(report.target or ""))
  print("ok: " .. tostring(report.ok == true))
  printChecks(report)

  print("")
  print("approveResult:")
  dumpValue(serialized(report, ".atm10-approve-result") or {})

  print("")
  print("queueEntries:")
  local q = serialized(report, ".atm10-craft-queue")
  dumpValue((q and q.entries) or {})

  print("")
  print("craftResults:")
  dumpValue(serialized(report, ".atm10-craft-results") or {})

  print("")
  print("crafted:")
  dumpValue(report.crafted or {})
end

local function usage()
  print("Usage:")
  print("  lua tools/atm10-sim.lua list")
  print("  lua tools/atm10-sim.lua all")
  print("  lua tools/atm10-sim.lua <scenario> [args...]")
  print("")
  print("Scenarios:")
  for _, name in ipairs(scenarios.names()) do
    local spec = scenarios.get(name)
    print("  " .. name .. " - " .. tostring(spec and spec.description or ""))
  end
end

local command = arg[1] or "list"
if command == "list" or command == "help" or command == "--help" then
  usage()
  os.exit(0)
end

if command == "all" then
  local failed = 0
  for _, name in ipairs(scenarios.names()) do
    local report = scenarios.run(name, {})
    printReport(report)
    print("")
    if not report.ok then failed = failed + 1 end
  end
  os.exit(failed == 0 and 0 or 1)
end

local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
local report, err = scenarios.run(command, args)
if not report then
  print(tostring(err))
  usage()
  os.exit(2)
end

printReport(report)
os.exit(report.ok and 0 or 1)
