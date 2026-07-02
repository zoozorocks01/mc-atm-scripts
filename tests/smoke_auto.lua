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

-- ---- parallel stub (TOUCH-DECOUPLE) ----------------------------------------
-- The manager's main loop is now parallel.waitForAny(scanLoop, inputLoop), but plain
-- Lua has no `parallel` API, so we stub it. The stub re-creates CC's scheduling over
-- the smoke's EXISTING scripted event arrays with NO edits to them: the smoke's
-- _G.os.pullEvent is the master timeline, and we route each scripted event onto the
-- two decoupled coroutines exactly as CC would --
--   {"timer", ...}  -> run ONE scan/render cycle (scanLoop: refreshAndDraw then sleep)
--   any other event -> deliver to the input loop's os.pullEvent (touch/redstone/
--                      resize/control)
-- so scan-driven assertions still see refreshAndDraw fire, and event-driven assertions
-- still see their event dispatched -- interleaved in scripted order. When the script
-- is exhausted, the smoke's pullEvent raises the SENTINEL, which propagates out of
-- waitForAny -> dofile -> the smoke's pcall, exactly as before.
_G.parallel = {
  waitForAny = function(scanLoop, inputLoop)
    local script = _G.os.pullEvent          -- the smoke's scripted event source
    local scanCo = coroutine.create(scanLoop)
    local inputCo = coroutine.create(inputLoop)
    -- inside the loops: sleep() parks the scan coroutine after one cycle; os.pullEvent()
    -- parks the input coroutine until the driver hands it the next routed event.
    _G.sleep = function() return coroutine.yield() end
    _G.os.pullEvent = function() return coroutine.yield() end
    local function step(co, ...)
      local ok, err = coroutine.resume(co, ...)
      if not ok then error(err, 0) end       -- propagate a real loop error OR the SENTINEL
    end
    step(inputCo)                            -- prime: advance the input loop to its first pullEvent
    while true do
      local ev = { script() }                -- next scripted event (raises SENTINEL when done)
      if ev[1] == "timer" then
        step(scanCo)                          -- one refresh cycle; parks at sleep()
      else
        step(inputCo, table.unpack(ev))       -- one event delivered; parks at os.pullEvent()
      end
    end
  end,
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
      files[p] = files[p .. ".__pending"]; files[p .. ".__pending"] = nil
    end }
  end,
  delete = function(p) files[p] = nil end,
  move = function(a, b) files[b] = files[a]; files[a] = nil end,
  getDir = function() return "" end,
  makeDir = function() end,
}

local function smokeSerialize(value, seen)
  local t = type(value)
  if t == "nil" or t == "boolean" or t == "number" then return tostring(value) end
  if t == "string" then return string.format("%q", value) end
  if t ~= "table" then error("cannot serialize " .. t) end
  seen = seen or {}
  if seen[value] then error("cannot serialize recursive table") end
  seen[value] = true
  local keys, parts = {}, {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return tostring(a) < tostring(b) end
    return type(a) < type(b)
  end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = "[" .. smokeSerialize(k, seen) .. "]=" .. smokeSerialize(value[k], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

_G.textutils = {
  serialize = smokeSerialize,
  -- the managed file maps to the real store; everything else parses like CC data.
  unserialize = function(text)
    if text == "MANAGED" then return MANAGED_STORE end
    if type(text) ~= "string" then return nil end
    local chunk = load("return " .. text, "smoke-textutils", "t", {})
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if not ok then return nil end
    return data
  end,
}
files[".atm10-drain-request"] = textutils.serialize({ requestedAt = -1 })

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
local jobSeq = 1000
local function fakeCraftJob()
  jobSeq = jobSeq + 1
  local id = jobSeq
  return { getId = function() return id end }
end
local taskListCalls, perItemCraftingCalls = 0, 0
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
    getCraftingTasks = function() taskListCalls = taskListCalls + 1; return {} end,
    isItemCrafting = function() perItemCraftingCalls = perItemCraftingCalls + 1; return false end,
    isCrafting = function() perItemCraftingCalls = perItemCraftingCalls + 1; return false end,
    craftItem = function(arg) crafted[#crafted + 1] = arg; return fakeCraftJob() end,
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
-- named so the STAB-2 run (which reuses this single-timer script) can re-install it:
-- the parallel stub overwrites _G.os.pullEvent with its yield-version during a run.
local function scriptPull()
  ei = ei + 1
  local ev = events[ei]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end
_G.os.pullEvent = scriptPull

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
check(files[".atm10-craft-audit"] ~= nil,
  "auto mode writes the bounded craft audit file for live diagnostics")
local qfile = textutils.unserialize(files[".atm10-craft-queue"])
local qentry = qfile and qfile.entries and qfile.entries["alltheores:zinc_ingot"]
check(qentry and qentry.jobId == 1001,
  "auto mode stores craftItem job id on the queue entry")
local craftstate = textutils.unserialize(files[".atm10-craftstate"])
check(type(craftstate) == "table" and type(craftstate.outstanding) == "table"
  and craftstate.outstanding[1] and craftstate.outstanding[1].id == 1001
  and craftstate.outstanding[1].name == "alltheores:zinc_ingot",
  "craftstate exposes the outstanding craftItem job id for safereboot")
check(files[".atm10-drain-request"] == nil,
  "manager clears a stale drain request flag on boot")
check(taskListCalls >= 1 and perItemCraftingCalls == 0,
  "empty getCraftingTasks snapshot skips per-item isCrafting checks during planning")

-- ---- DRAIN-1: an active drain request ACKs and suppresses craftItem ----------
-- The flag must be set AFTER boot: stale flags are intentionally deleted during
-- startup, while an active safereboot request lands while the manager is running.
files = { [MANAGED_FILE] = "MANAGED" }
clock = 0
jobSeq = 1000
local drainCrafted = {}
local BRD = fakeBridge()
BRD.craftItem = function(arg) drainCrafted[#drainCrafted + 1] = arg; return fakeCraftJob() end
_G.peripheral.wrap = function(n)
  if n == "monitor_0" then return MON end
  if n == "rs_bridge_0" then return BRD end
  return nil
end
local drainRequestedAt = 4242
local eventsD, eid = { { "drain_request" }, { "timer", 1 } }, 0
_G.os.pullEvent = function()
  eid = eid + 1
  local ev = eventsD[eid]
  if not ev then error(SENTINEL, 0) end
  if ev[1] == "drain_request" then
    files[".atm10-drain-request"] = textutils.serialize({ requestedAt = drainRequestedAt })
    return "weird_unhandled_event", "drain"
  end
  return table.unpack(ev)
end
print("smoke-auto: active safereboot drain request suppresses craft firing")
local okD, errD = pcall(function() dofile("inventory/manager.lua") end)
check(okD == false and tostring(errD):find(SENTINEL, 1, true) ~= nil,
  "DRAIN-1: manager reached the sentinel while a drain was requested: " .. tostring(errD))
check(#drainCrafted == 0,
  "DRAIN-1: drain request held craftItem even though AUTO had a craftable deficit")
local drainState = textutils.unserialize(files[".atm10-craftstate"])
check(type(drainState) == "table" and drainState.drainAck == true
  and drainState.drainRequestAt == drainRequestedAt,
  "DRAIN-1: manager persisted a matching drain ack in craftstate")
check(files[".atm10-drain-request"] ~= nil,
  "DRAIN-1: active drain flag remains for safereboot while the manager is holding")

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
_G.os.pullEvent = scriptPull -- restore the script source (the prior run clobbered it)
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

-- ---- A1 manual jobs: fire BEFORE a quota refill + bypass the per-item cooldown -----
-- The REQUIRED biting end-to-end test (a pure test alone is insufficient: the A3
-- lesson). We drive the FULL control wiring -- a rednet craft_request event flows
-- through handleControlMessage -> the craft_request actuator -> cqueue.enqueueJob --
-- then a refresh timer runs processCraftQueue. Setup:
--   * mode = auto, controlEnabled + allowAutocraft on (so a craft_request is accepted).
--   * maxCraftsPerCycle = 1, manualReserve = 1 -> exactly one fire per cycle, reserved
--     for the manual lane.
--   * TWO craftable deficits as competing quotas: zinc_ingot (also seeded ON COOLDOWN
--     in the ledger so its QUOTA path would NOT fire) and copper_ingot (no cooldown).
--   * a manual job for zinc_ingot enqueued over rednet.
-- Asserts:
--   (1) crafted[1] is the MANUAL item -> the reserved manual slot beats the copper
--       quota deficit under a cap of 1 (manual fires FIRST).
--   (2) zinc fired even though its quota is ON COOLDOWN (and the copper quota did NOT
--       fire) -> the manual job bypassed the cooldown that blocks the quota path.
-- BITE: revert the fireOrder manual lane -> crafted[1] becomes copper (1 fails);
--       revert the cooldown-bypass... the cooldown here is the LEDGER/planner cooldown
--       a manual job structurally skips (it never traverses the planner), so the proof
--       is that zinc -- ON COOLDOWN as a quota -- still crafts via the manual lane while
--       the copper quota is the only refill that competes for the single slot.
do
local A1_MANAGED = {
  items = {
    ["alltheores:zinc_ingot"]   = { name = "alltheores:zinc_ingot", label = "Zinc Ingot", target = 5000, craftTo = 5000 },
    ["alltheores:copper_ingot"] = { name = "alltheores:copper_ingot", label = "Copper Ingot", target = 5000, craftTo = 5000 },
  },
  settings = { modeOverride = "auto" },
}
-- a config table enabling the control channel (loaded via dofile in the manager)
local A1_CONFIG = {
  controlEnabled = true, allowAutocraft = true,
  stockKeeper = { enabled = true, cooldownSeconds = 300, maxCraftsPerCycle = 1, manualReserve = 1 },
}
-- ledger with a FRESH zinc request -> the planner reports zinc ON COOLDOWN (its quota
-- path won't fire); copper has no record so its quota IS a WOULD CRAFT deficit.
local A1_LEDGER = { requests = { ["alltheores:zinc_ingot"] = { requestedAt = 1, request = 5000 } } }

local LEDGER_FILE = ".atm10-stock-ledger"
local CONFIG_FILE = "inventory-config"
-- the config file must "exist" so loadConfig consults dofile(CONFIG_FILE) (its content
-- is irrelevant -- the dofile override returns A1_CONFIG for that path).
local a1files = { [MANAGED_FILE] = "MANAGED", [LEDGER_FILE] = "LEDGER", [CONFIG_FILE] = "CONFIG" }
local realDofile = dofile
local realUnser = textutils.unserialize
-- the manager loads its config via dofile(CONFIG_FILE); return the A1 config for that
-- path and delegate every other path (the manager program itself) to the real dofile.
_G.dofile = function(p)
  if p == CONFIG_FILE then return A1_CONFIG end
  return realDofile(p)
end
_G.fs.exists = function(p) return a1files[p] ~= nil end
_G.fs.open = function(p, mode)
  if mode == "r" then
    if not a1files[p] then return nil end
    local content, read = a1files[p], false
    return { readAll = function() if read then return nil end; read = true; return content end,
             close = function() end }
  end
  return { write = function(s) a1files[p .. ".__pending"] = s end, close = function()
    a1files[p] = a1files[p .. ".__pending"]; a1files[p .. ".__pending"] = nil
  end }
end
_G.textutils.unserialize = function(text)
  if text == "MANAGED" then return A1_MANAGED end
  if text == "LEDGER" then return A1_LEDGER end
  return realUnser(text) or {}
end

local a1crafted = {}
-- cycle 1: NO deficit (both at target) so the first timer loads config + scans WITHOUT
-- firing any quota. cycle 2+: a deficit appears so the copper quota WOULD craft -- but
-- by then the manual job is queued and the reserved manual slot wins the single fire.
-- (The manager has no startup loadConfig; config loads on the first scan. So the rednet
-- craft_request must arrive AFTER that first scan or handleControlMessage sees the
-- default controlEnabled=false. This is the real in-game ordering -- scans run every
-- few seconds, so a control message is simply handled on/after the next scan.)
local a1cycle = 0
local A1BR = fakeBridge()
A1BR.getItems = function()
  a1cycle = a1cycle + 1
  if a1cycle == 1 then
    return {
      { name = "alltheores:zinc_ingot", amount = 5000, isCraftable = true },
      { name = "alltheores:copper_ingot", amount = 5000, isCraftable = true },
    }
  end
  return {
    { name = "alltheores:zinc_ingot", amount = 1000, isCraftable = true },
    { name = "alltheores:copper_ingot", amount = 1000, isCraftable = true },
  }
end
A1BR.craftItem = function(arg) a1crafted[#a1crafted + 1] = arg; return true end
_G.peripheral.wrap = function(n)
  if n == "monitor_0" then return MON end
  if n == "rs_bridge_0" then return A1BR end
  return nil
end
clock = 0

-- event order: timer (loads config, no deficit -> no craft) -> rednet craft_request
-- for zinc (config now loaded -> enqueues the manual job through the full control
-- wiring) -> timer (deficit now present -> runner fires; the manual lane leads).
local CONTROL_PROTOCOL = "atm10-control-v1"
local a1events = {
  { "timer", 1 },
  { "rednet_message", 7, { action = "craft_request", target = "alltheores:zinc_ingot", args = { count = 777 } }, CONTROL_PROTOCOL },
  { "timer", 1 },
}
local a1i = 0
_G.os.pullEvent = function()
  a1i = a1i + 1
  local ev = a1events[a1i]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end

print("smoke-auto: A1 - a manual job (rednet craft_request) fires BEFORE a quota deficit under cap=1")
local okA1, errA1 = pcall(function() dofile("inventory/manager.lua") end)
-- restore the globals the rest of the file (none after this) / safety doesn't depend on,
-- but leave them clean regardless
_G.dofile = realDofile
_G.textutils.unserialize = realUnser
check(okA1 == false and tostring(errA1):find(SENTINEL, 1, true) ~= nil,
  "A1: manager ran the enqueue + one craft cycle then stopped: " .. tostring(errA1))
check(#a1crafted == 1, "A1: exactly one craft fired under maxCraftsPerCycle=1")
check(#a1crafted >= 1 and a1crafted[1].name == "alltheores:zinc_ingot",
  "A1: the MANUAL job (zinc) fired FIRST, beating the copper quota deficit (reserved manual slot)")
check(#a1crafted >= 1 and (tonumber(a1crafted[1].count) or 0) == 32,
  "A1: the manual job fired one maxBridgeRequest-capped batch (32) via the full control wiring")
local a1copperFired = false
for _, c in ipairs(a1crafted) do if c.name == "alltheores:copper_ingot" then a1copperFired = true end end
check(a1copperFired == false,
  "A1: the copper quota did NOT fire (the single slot went to the manual lane)")
check(a1crafted[1].name == "alltheores:zinc_ingot",
  "A1: zinc crafted via the manual lane despite its QUOTA being ON COOLDOWN (cooldown bypass)")
end

print((failures == 0) and "SMOKE-AUTO OK" or ("SMOKE-AUTO FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
