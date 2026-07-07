-- Reusable manager simulator smoke scenarios.
--
-- Run: lua tests/smoke_sim.lua
package.path = "./tests/?.lua;./lib/?.lua;" .. package.path

local sim = require("sim.manager_sim")

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok: " .. msg)
  else
    failures = failures + 1
    print("  FAIL: " .. msg)
  end
end

local function aluminumApprovalRun(target)
  local bridge = sim.bridge({
    items = {
      { name = "alltheores:aluminum_ingot", amount = 1000, isCraftable = true },
      { name = "alltheores:aluminum_dust", amount = 5000, isCraftable = false },
      { name = "alltheores:tiny_aluminum_dust", amount = 12000, isCraftable = false },
      { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
    },
  })

  local run = sim.new({
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

  return run:run()
end

print("sim: terminal approval exact id resolves refill/compress collision")
local result = aluminumApprovalRun("alltheores:aluminum_ingot")
check(result.ok == false and tostring(result.err):find(result.sentinel, 1, true) ~= nil,
  "manager completed one scripted cycle and stopped at the simulator sentinel")

local approveResult = result.sim:getSerializedFile(".atm10-approve-result")
check(type(approveResult) == "table" and approveResult.ok == true
  and approveResult.name == "alltheores:aluminum_ingot",
  "approval result records the matched aluminum refill row")
check(type(approveResult) == "table" and approveResult.matcher == 2,
  "approval result records the runtime approval matcher version")
check(type(approveResult) == "table" and approveResult.reason == nil,
  "approval result is not an ambiguity failure")

local queue = result.sim:getSerializedFile(".atm10-craft-queue")
local refill = queue and queue.entries and queue.entries["alltheores:aluminum_ingot"]
local compress = queue and queue.entries and queue.entries["compress:alltheores:aluminum_dust"]
check(type(refill) == "table" and refill.state == "CRAFTING"
  and refill.key == "alltheores:aluminum_ingot",
  "exact item id selected the refill queue key")
check(compress == nil,
  "exact item id did not select the compress queue key")
check(#result.crafted == 1 and result.crafted[1].name == "alltheores:aluminum_ingot",
  "the simulated RS bridge received one aluminum ingot craftItem request")

local statusFile = result.sim:getSerializedFile(".atm10-status")
check(type(statusFile) == "table" and statusFile.version == 2
  and statusFile.runtime and statusFile.runtime.approvalMatcher == 2,
  "status file records the runtime approval matcher version")

local planState = result.sim:getSerializedFile(".atm10-planstate")
check(type(planState) == "table" and planState.runtime
  and planState.runtime.approvalMatcher == 2,
  "planstate records the runtime approval matcher version")

print((failures == 0) and "SMOKE-SIM OK" or ("SMOKE-SIM FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
