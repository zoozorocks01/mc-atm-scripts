-- Off-CC SMOKE test: actually RUN power/probe.lua against a stubbed CC:Tweaked
-- environment for ONE loop iteration. run.lua only loadfile()-parses the probe and
-- smoke.lua only runs the inventory manager, so a runtime bug in the probe's sample
-- loop (e.g. a multi-return leaking into tonumber's `base` arg, QUICK-4) would ship
-- a 100%-dead probe with a green gate. This drives both the healthy and the
-- sensor-unreachable paths and fails if either throws or sends a malformed sample.
--
-- Run:  lua tests/smoke_probe.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local realExit = os.exit -- captured before _G.os is stubbed
local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

local SENTINEL = "__PROBE_DONE__"

-- Run the probe once against a given induction-port stub. `sleep` throws the sentinel
-- to break out after the first iteration; rednet.send captures the broadcast sample.
local function runProbe(port)
  local sent = nil
  _G.os = {
    epoch = function() return 1000 end,
    clock = function() return 1 end,
    getComputerID = function() return 9 end,
  }
  _G.sleep = function() error(SENTINEL, 0) end
  _G.rednet = {
    open = function() end,
    lookup = function() return 5 end,        -- a display is "found" so the probe sends
    send = function(_, msg) sent = msg end,
  }
  _G.peripheral = { wrap = function() return port end }
  local ok, err = pcall(function() dofile("power/probe.lua") end)
  return ok, err, sent
end

-- scenario 1: a healthy induction matrix -> a full sample, sensorOk true
local healthy = {
  getEnergy = function() return 5000 end,
  getMaxEnergy = function() return 10000 end,
  getLastInput = function() return 200 end,
  getLastOutput = function() return 50 end,
  getTransferCap = function() return 1000 end,
  getEnergyFilledPercentage = function() return 0.5 end,
}
print("smoke: running power/probe.lua (healthy port) against stubbed CC env")
local ok1, err1, s1 = runProbe(healthy)
check(ok1 == false and tostring(err1):find(SENTINEL, 1, true) ~= nil,
  "probe ran one loop iteration with no runtime error: " .. tostring(err1))
check(type(s1) == "table" and s1.kind == "power_sample", "probe broadcast a power_sample")
check(s1 and s1.sensorOk == true, "healthy port -> sensorOk true")
check(s1 and s1.energy == 5000 and s1.maxEnergy == 10000, "energy/maxEnergy read correctly")
check(s1 and s1.transferCap == 1000, "transferCap carried in the sample (QUICK-1)")
check(s1 and s1.input == 200 and s1.output == 50, "input/output read without tonumber crash (QUICK-4 regression guard)")

-- scenario 2: a port missing the core reads -> sensorOk false, still no crash
print("smoke: running power/probe.lua (unreachable port) against stubbed CC env")
local broken = { getLastInput = function() return 0 end } -- no getEnergy/getMaxEnergy
local ok2, err2, s2 = runProbe(broken)
check(ok2 == false and tostring(err2):find(SENTINEL, 1, true) ~= nil,
  "probe survives an unresponsive port: " .. tostring(err2))
check(s2 and s2.sensorOk == false, "missing core reads -> sensorOk false (QUICK-4)")

print((failures == 0) and "SMOKE-PROBE OK" or ("SMOKE-PROBE FAILED (" .. failures .. ")"))
realExit(failures == 0 and 0 or 1)
