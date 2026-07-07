-- Reusable manager simulator smoke scenarios.
--
-- Run: lua tests/smoke_sim.lua
package.path = "./tests/?.lua;./lib/?.lua;" .. package.path

local scenarios = require("sim.scenarios")

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok: " .. msg)
  else
    failures = failures + 1
    print("  FAIL: " .. msg)
  end
end

for _, name in ipairs(scenarios.names()) do
  local report, err = scenarios.run(name, {})
  print("sim: " .. name)
  if not report then
    check(false, err)
  else
    for _, c in ipairs(report.checks or {}) do
      check(c.ok, c.msg)
    end
  end
end

print((failures == 0) and "SMOKE-SIM OK" or ("SMOKE-SIM FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
