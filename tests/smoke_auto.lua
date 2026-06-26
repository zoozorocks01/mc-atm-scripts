-- Off-CC END-TO-END test of AUTO mode: run inventory/manager.lua against a stubbed
-- CC env where one managed item is a CRAFTABLE deficit and the mode is "auto",
-- then assert the manager auto-approved AND fired bridge.craftItem for it WITHOUT
-- any manual tap. This exercises the full wiring the pure suite can't:
--   scan -> planStockActions (WOULD CRAFT) -> autoApprovePlans (auto gate) ->
--   processCraftQueue -> control gate -> requestCraft -> bridge.craftItem.
--
-- Run:  lua tests/smoke_auto.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

-- ---- stub CC globals -------------------------------------------------------
local COLOR_NAMES = {
  "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
  "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}
_G.colors = {}
for i, name in ipairs(COLOR_NAMES) do _G.colors[name] = 2 ^ (i - 1) end

local clock = 0
_G.os = {
  exit = os.exit,
  time = os.time,
  epoch = function() clock = clock + 50; return clock end,
  clock = function() clock = clock + 1; return clock end,
  startTimer = function() return 1 end,
  getComputerID = function() return 7 end,
}

-- in-memory fs: only the managed-store file "exists" (carries a sentinel we map to
-- the real store in unserialize). No queue/ledger/trends files -> clean no-file
-- paths, so no stale ledger cooldown interferes with the single cycle.
local MANAGED_FILE = ".atm10-managed"
local MANAGED_STORE = {
  items = {
    ["alltheores:zinc_ingot"] = {
      name = "alltheores:zinc_ingot", label = "Zinc Ingot", target = 5000, craftTo = 5000,
    },
  },
  settings = { modeOverride = "auto" }, -- drive AUTO without a config file
}
local files = { [MANAGED_FILE] = "MANAGED" }
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  open = function(p, mode)
    if mode == "r" then
      if not files[p] then return nil end
      local content, read = files[p], false
      return { readAll = function() if read then return nil end; read = true; return content end,
               close = function() end }
    end
    return { write = function(s) files[p .. ".__pending"] = s end, close = function()
      files[p:gsub("%.tmp$", "")] = files[p .. ".__pending"]; files[p .. ".__pending"] = nil
    end }
  end,
  delete = function(p) files[p] = nil end,
  move = function(a, b) files[b] = files[a]; files[a] = nil end,
  getDir = function() return "" end,
  makeDir = function() end,
}

_G.textutils = {
  serialize = function() return "{}" end,
  -- the managed file maps to the real store; everything else is empty
  unserialize = function(text) if text == "MANAGED" then return MANAGED_STORE end return {} end,
}

_G.rs = {
  getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
  getInput = function() return false end,
}
_G.rednet = { open = function() end, broadcast = function() end }

local function fakeMonitor()
  local m, noop = {}, function() end
  m.setBackgroundColor, m.setTextColor, m.setTextScale = noop, noop, noop
  m.setPaletteColour, m.setPaletteColor = noop, noop
  m.clear, m.clearLine, m.setCursorPos = noop, noop, noop
  m.isColor = function() return true end
  m.getSize = function() return 60, 24 end
  m.write = noop
  m.blit = noop
  return m
end

-- bridge: zinc_ingot is a CRAFTABLE deficit (1000 < 5000). craftItem is a SPY.
local crafted = {}
local function fakeBridge()
  local items = {
    { name = "alltheores:zinc_ingot", amount = 1000, isCraftable = true },
    { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
  }
  return {
    isConnected = function() return true end,
    isOnline = function() return true end,
    getItems = function() return items end,
    getItem = function() return nil end,
    isCraftable = function() return true end,
    isItemCraftable = function() return true end,
    isItemCrafting = function() return false end,
    isCrafting = function() return false end,
    craftItem = function(arg) crafted[#crafted + 1] = arg; return true end,
    getUsedItemStorage = function() return 1000 end,
    getTotalItemStorage = function() return 100000 end,
    getAvailableItemStorage = function() return 99000 end,
    getStoredEnergy = function() return 50000 end,
    getEnergyCapacity = function() return 50000 end,
    getEnergyUsage = function() return 1000 end,
  }
end

local MON, BR = fakeMonitor(), fakeBridge()
_G.peripheral = {
  getNames = function() return { "monitor_0", "rs_bridge_0" } end,
  getType = function(n)
    if n == "monitor_0" then return "monitor" end
    if n == "rs_bridge_0" then return "rs_bridge" end
    return "unknown"
  end,
  wrap = function(n)
    if n == "monitor_0" then return MON end
    if n == "rs_bridge_0" then return BR end
    return nil
  end,
  find = function() return nil end,
}

-- ONE refresh cycle, then stop. One cycle is enough: scan plans the deficit, auto
-- mode approves it, and the runner fires craftItem -- all before any second read.
local SENTINEL = "__SMOKE_AUTO_DONE__"
local events = { { "timer", 1 } }
local ei = 0
_G.os.pullEvent = function()
  ei = ei + 1
  local ev = events[ei]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end

-- ---- run it ----------------------------------------------------------------
print("smoke-auto: running inventory/manager.lua in AUTO mode against a craftable deficit")
local ok, err = pcall(function() dofile("inventory/manager.lua") end)
check(ok == false and tostring(err):find(SENTINEL, 1, true) ~= nil,
  "manager ran one cycle then stopped via the sentinel: " .. tostring(err))

check(#crafted >= 1, "auto mode fired at least one craftItem with NO manual approval")
local hit = false
for _, c in ipairs(crafted) do
  if type(c) == "table" and c.name == "alltheores:zinc_ingot" and (tonumber(c.count) or 0) > 0 then
    hit = true
  end
end
check(hit, "auto mode crafted the deficit item (zinc_ingot) with a positive count")

-- ---- STAB-2: craft-path attachment recheck ---------------------------------
-- Race the #1 server-crash trigger: the bridge is CONNECTED when scan reads it
-- (so the deficit is planned + auto-approved), then DETACHED by the time
-- requestCraft is about to fire the mutating craftItem. STAB-2 must recheck
-- isConnected immediately before craftItem and refuse, so craftItem is never
-- issued at a half-detached peripheral (the uncatchable NotAttachedException).
-- isConnected is called exactly once before the craft (scan), so a call-counter
-- stub (true at scan, false at the recheck) isolates the recheck. Remove the
-- recheck and this run fires craftItem -> the #crafted2 assertion below bites.
local crafted2 = {}
local function fakeBridgeRace()
  local b = fakeBridge()
  local checks = 0
  b.isConnected = function() checks = checks + 1; return checks == 1 end
  b.craftItem = function(arg) crafted2[#crafted2 + 1] = arg; return true end
  return b
end

-- Reset the in-memory world so the deficit re-plans cleanly: run 1 wrote a
-- ledger/queue that would otherwise cooldown-skip zinc and mask the recheck.
files = { [MANAGED_FILE] = "MANAGED" }
clock = 0
ei = 0
local BR2 = fakeBridgeRace()
_G.peripheral.wrap = function(n)
  if n == "monitor_0" then return MON end
  if n == "rs_bridge_0" then return BR2 end
  return nil
end

print("smoke-auto: re-running with a bridge that detaches AFTER scan, BEFORE the craft")
local ok2, err2 = pcall(function() dofile("inventory/manager.lua") end)
check(ok2 == false and tostring(err2):find(SENTINEL, 1, true) ~= nil,
  "STAB-2: manager survived the cycle with a bridge that detached before the craft (no crash): " .. tostring(err2))
check(#crafted2 == 0,
  "STAB-2: craftItem was NOT issued at a bridge that detached after scan (recheck blocked it)")

-- ---- STAB-1(a): unknown events are ignored without throwing -----------------
-- Inject an event the loop has no handler for; it must fall through the dispatch
-- and the loop must keep running (and still craft the deficit on the timer).
files = { [MANAGED_FILE] = "MANAGED" }
clock = 0
local craftedA = {}
local BRA = fakeBridge()
BRA.craftItem = function(arg) craftedA[#craftedA + 1] = arg; return true end
_G.peripheral.wrap = function(n)
  if n == "monitor_0" then return MON end
  if n == "rs_bridge_0" then return BRA end
  return nil
end
local eventsA, eia = { { "weird_unhandled_event", "junk" }, { "timer", 1 } }, 0
_G.os.pullEvent = function()
  eia = eia + 1
  local ev = eventsA[eia]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end
print("smoke-auto: injecting an unknown event before the refresh timer")
local okA, errA = pcall(function() dofile("inventory/manager.lua") end)
check(okA == false and tostring(errA):find(SENTINEL, 1, true) ~= nil,
  "STAB-1: an unknown event is ignored without throwing (loop reached the sentinel): " .. tostring(errA))
check(#craftedA >= 1, "STAB-1: the loop kept running past the unknown event (still crafted the deficit)")

-- ---- STAB-1(b): a throwing craftItem is contained at the craft site ---------
-- call() pcall-wraps every bridge method, so a raising craftItem must be caught
-- THERE (entry rejected), never escalated to the loop's guard(). Bite: remove
-- call()'s pcall and the throw escapes to guard(), which prints "loop error:" ->
-- the no-loop-error assertion below fails.
files = { [MANAGED_FILE] = "MANAGED" }
clock = 0
local craftAttempts = 0
local BR3 = fakeBridge()
BR3.craftItem = function() craftAttempts = craftAttempts + 1; error("simulated AP craft failure", 0) end
_G.peripheral.wrap = function(n)
  if n == "monitor_0" then return MON end
  if n == "rs_bridge_0" then return BR3 end
  return nil
end
local eventsB, eib = { { "timer", 1 } }, 0
_G.os.pullEvent = function()
  eib = eib + 1
  local ev = eventsB[eib]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end
local realPrint = print
local logged = {}
_G.print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  logged[#logged + 1] = table.concat(parts, " ")
  realPrint(...)
end
print("smoke-auto: making craftItem raise; expect containment at call(), not the loop guard")
local okB, errB = pcall(function() dofile("inventory/manager.lua") end)
_G.print = realPrint
check(okB == false and tostring(errB):find(SENTINEL, 1, true) ~= nil,
  "STAB-1: a throwing craftItem does not crash the loop (reached the sentinel): " .. tostring(errB))
check(craftAttempts >= 1, "STAB-1: the throwing craftItem was actually invoked (craft path exercised)")
local loopErr = false
for _, line in ipairs(logged) do if line:find("loop error", 1, true) then loopErr = true end end
check(not loopErr, "STAB-1: call() contained the craft throw at the craft site (no loop-level error)")

-- ---- A3 recovery-hysteresis: hold crafts across the bridge re-attach window -----
-- The headline reliability win, tested END-TO-END (the pure gateCrafts test alone
-- did not catch the earlier no-op, because the no-op passed the unit test). A
-- detaching bridge (reboot/chunk-reload) produces a BURST of failed reads then
-- comes back; the mutating craftItem at that still-settling re-attach is the
-- uncatchable AP crash trigger, so the gate must HOLD firing for the first clean
-- read(s) after a degraded window, NOT resume on the first clean scan. We drive the
-- manager through a degraded window by flipping the bridge offline per cycle from
-- os.pullEvent (one schedule entry = one refresh cycle).
local flakyOnline = true
local function fakeBridgeFlaky()
  local b = fakeBridge()
  b.isConnected = function() return flakyOnline end
  b.isOnline = function() return flakyOnline end
  b.getItems = function()
    if not flakyOnline then return {} end
    return {
      { name = "alltheores:zinc_ingot", amount = 1000, isCraftable = true },
      { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
    }
  end
  return b
end

local function runFlaky(schedule, craftSpy)
  files = { [MANAGED_FILE] = "MANAGED" } -- fresh world so no stale queue/ledger
  clock = 0
  flakyOnline = true
  local BRF = fakeBridgeFlaky()
  BRF.craftItem = function(arg) craftSpy[#craftSpy + 1] = arg; return true end
  _G.peripheral.wrap = function(n)
    if n == "monitor_0" then return MON end
    if n == "rs_bridge_0" then return BRF end
    return nil
  end
  local ej = 0
  _G.os.pullEvent = function()
    ej = ej + 1
    if ej > #schedule then error(SENTINEL, 0) end
    flakyOnline = schedule[ej] -- set this cycle's bridge state before the refresh
    return "timer", 1
  end
  return pcall(function() dofile("inventory/manager.lua") end)
end

-- SUPPRESSION (the biting test): 3 offline reads degrade the bridge, then ONE clean
-- read. With hysteresis (recover=2) that first clean read must STILL hold, so NO
-- craft fires. Revert gateCrafts to reset-on-first-clean and cycle 4 fires -> bites.
local craftedHold = {}
print("smoke-auto: A3 hysteresis - 3 offline then 1 clean read must NOT fire (held)")
local okH, errH = runFlaky({ false, false, false, true }, craftedHold)
check(okH == false and tostring(errH):find(SENTINEL, 1, true) ~= nil,
  "A3: manager survived a degraded-then-recovering bridge with no crash: " .. tostring(errH))
check(#craftedHold == 0,
  "A3: craftItem HELD on the first clean read after a degraded window (recovery hysteresis)")

-- RESUME: a SECOND consecutive clean read (recover=2) must re-enable firing, so the
-- deficit finally crafts. Proves the hold is not a permanent latch.
local craftedResume = {}
print("smoke-auto: A3 hysteresis - a second clean read resumes firing")
local okR, errR = runFlaky({ false, false, false, true, true }, craftedResume)
check(okR == false and tostring(errR):find(SENTINEL, 1, true) ~= nil,
  "A3: manager survived the recovery cycles with no crash: " .. tostring(errR))
check(#craftedResume >= 1,
  "A3: craft-firing AUTO-RESUMES after recover consecutive clean reads")

-- ---- A3 module-missing resilience: a missing atm10-health must NOT crash ---------
-- This is the exact in-game failure that happened: the update manifest shipped the
-- manager (which require()s atm10-health) but not the module, so every scan threw
-- "module 'atm10-health' not found" and the screen was dead. The require is now
-- pcall-guarded with an always-allow stub, so a missing optional module degrades to
-- pre-A3 firing instead of breaking the manager. Simulate absence by failing require
-- for that one module. Bite: revert to a hard require("atm10-health") and the deficit
-- never crafts (scan throws every cycle) -> the degraded-fire assertion fails.
files = { [MANAGED_FILE] = "MANAGED" }
clock = 0
local craftedNoHealth = {}
local BRNH = fakeBridge()
BRNH.craftItem = function(arg) craftedNoHealth[#craftedNoHealth + 1] = arg; return true end
_G.peripheral.wrap = function(n)
  if n == "monitor_0" then return MON end
  if n == "rs_bridge_0" then return BRNH end
  return nil
end
local eventsNH, einh = { { "timer", 1 } }, 0
_G.os.pullEvent = function()
  einh = einh + 1
  local ev = eventsNH[einh]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end
local realRequire = require
_G.require = function(m)
  if m == "atm10-health" then error("module 'atm10-health' not found", 0) end
  return realRequire(m)
end
print("smoke-auto: simulating a MISSING atm10-health module (must degrade, not crash)")
local okNH, errNH = pcall(function() dofile("inventory/manager.lua") end)
_G.require = realRequire
check(okNH == false and tostring(errNH):find(SENTINEL, 1, true) ~= nil,
  "A3: manager reached the sentinel with atm10-health missing (no hard crash): " .. tostring(errNH))
check(#craftedNoHealth >= 1,
  "A3: a missing atm10-health degrades to always-fire (pre-A3), it does NOT break crafting")

print((failures == 0) and "SMOKE-AUTO OK" or ("SMOKE-AUTO FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
