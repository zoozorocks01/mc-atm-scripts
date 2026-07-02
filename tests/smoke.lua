-- Off-CC SMOKE test: actually RUN inventory/manager.lua against a stubbed
-- CC:Tweaked environment. The pure-logic suite (run.lua) only loadfile()s the
-- manager (parse, never execute), so undefined-global / nil-index bugs in the
-- scan/draw/touch paths slip through and crash only in-game (e.g. the missing
-- require("atm10-control")). This feeds the manager a synthetic event stream
-- (refresh -> tab taps -> apply a preset -> toggle smart -> browse/editor ->
-- resize), records what gets drawn, and fails if anything throws or if the
-- screen shows the error/"waiting" fallback (which means scan crashed, since the
-- manager pcall()s scan and would otherwise hide it).
--
-- Run:  lua tests/smoke.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok: " .. msg)
  else
    failures = failures + 1
    print("  FAIL: " .. msg)
  end
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
  exit = os.exit, -- preserve the real exit (RHS evaluated before _G.os is replaced)
  time = os.time,
  epoch = function() clock = clock + 50; return clock end,
  clock = function() clock = clock + 1; return clock end,
  startTimer = function() return 1 end,
  getComputerID = function() return 7 end,
  -- pullEvent is installed below once the event queue is built
}

-- ---- parallel stub (TOUCH-DECOUPLE) ----------------------------------------
-- The manager's main loop is now parallel.waitForAny(scanLoop, inputLoop); plain Lua
-- has no `parallel` API, so we stub it. The stub re-creates CC's scheduling over the
-- smoke's EXISTING scripted event array with NO edits: _G.os.pullEvent is the master
-- timeline, and each scripted event is routed onto the two decoupled coroutines as CC
-- would --
--   {"timer", ...}  -> run ONE scan/render cycle (scanLoop: refreshAndDraw then sleep)
--   any other event -> deliver to the input loop's os.pullEvent (tab taps, preset/
--                      smart toggles, redstone, resize)
-- so the PLAN page still renders from a scan and every tap is still dispatched, in
-- scripted order. When the script is exhausted the smoke's pullEvent raises the
-- SENTINEL, which propagates out of waitForAny -> dofile -> the smoke's pcall.
_G.parallel = {
  waitForAny = function(scanLoop, inputLoop)
    local script = _G.os.pullEvent          -- the smoke's scripted event source
    local scanCo = coroutine.create(scanLoop)
    local inputCo = coroutine.create(inputLoop)
    _G.sleep = function() return coroutine.yield() end
    _G.os.pullEvent = function() return coroutine.yield() end
    local function step(co, ...)
      local ok, err = coroutine.resume(co, ...)
      if not ok then error(err, 0) end       -- propagate a real loop error OR the SENTINEL
    end
    step(inputCo)                            -- prime the input loop to its first pullEvent
    while true do
      local ev = { script() }                -- next scripted event (raises SENTINEL when done)
      if ev[1] == "timer" then
        step(scanCo)
      else
        step(inputCo, table.unpack(ev))
      end
    end
  end,
}

-- in-memory filesystem: no files exist; writes go to a sink
local files = {}
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
  unserialize = function() return {} end,
}

_G.rs = {
  getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
  getInput = function() return false end,
}
_G.rednet = { open = function() end, broadcast = function() end }

-- fake advanced monitor that records drawn text so we can inspect the screen
local screen = {}
local function fakeMonitor()
  local m = {}
  local function noop() end
  m.setBackgroundColor = noop
  m.setTextColor = noop
  m.setTextScale = noop
  m.setPaletteColour = noop
  m.setPaletteColor = noop
  m.clear = function() screen = {} end
  m.clearLine = noop
  m.setCursorPos = noop
  m.isColor = function() return true end
  m.getSize = function() return 60, 24 end
  m.write = function(s) screen[#screen + 1] = tostring(s) end
  m.blit = function(s) screen[#screen + 1] = tostring(s) end
  return m
end

-- fake RS Bridge: a small grid, nothing craftable (mirrors the live craftable=0)
local function fakeBridge()
  local items = {
    { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
    { name = "minecraft:glass", amount = 0, isCraftable = false },
    { name = "alltheores:zinc_dust", amount = 500000, isCraftable = false },
    { name = "alltheores:zinc_ingot", amount = 1000, isCraftable = false },
  }
  return {
    isConnected = function() return true end,
    isOnline = function() return true end,
    getItems = function() return items end,
    getItem = function() return nil end, -- force the local-map/fallback path
    isCraftable = function() return false end,
    isItemCraftable = function() return false end,
    isItemCrafting = function() return false end,
    isCrafting = function() return false end,
    craftItem = function() return true end,
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

-- ---- synthetic event stream ------------------------------------------------
-- (x,y) for taps: tab strip is on row 2; preset/smart rows are content rows.
local SENTINEL = "__SMOKE_DONE__"
local events = {
  { "timer", 1 },                       -- first refresh: scan + draw PLAN
  { "monitor_touch", "r", 10, 2 },      -- tab -> QUEUE
  { "monitor_touch", "r", 25, 2 },      -- tab -> BROWSE
  { "monitor_touch", "r", 1, 8 },       -- BROWSE: tap an item -> open editor
  { "monitor_touch", "r", 1, 8 },       -- editor: hit a button row (step/+/-)
  { "monitor_touch", "r", 28, 2 },      -- tab -> PRESETS (exits editor)
  { "monitor_touch", "r", 1, 8 },       -- PRESETS: apply first preset
  { "monitor_touch", "r", 1, 9 },       -- PRESETS: apply another (zoozo, smart on)
  { "monitor_touch", "r", 38, 2 },      -- tab -> SMART
  { "monitor_touch", "r", 1, 7 },       -- SMART: toggle button
  { "redstone" },                       -- redstone page button
  { "timer", 1 },                       -- second refresh (managed + smart active)
  { "monitor_resize" },                 -- resize -> rescale + redraw
}
local ei = 0
-- named so each run can re-install it (the parallel stub overwrites _G.os.pullEvent
-- with its yield-version during a run, so the next run must restore the script source).
local function scriptPull()
  ei = ei + 1
  local ev = events[ei]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end
_G.os.pullEvent = scriptPull

-- ---- run it ----------------------------------------------------------------
print("smoke: running inventory/manager.lua against stubbed CC env")
local ok, err = pcall(function() dofile("inventory/manager.lua") end)

check(ok == false, "manager ran the event loop (stopped by sentinel)")
check(ok == false and tostring(err):find(SENTINEL, 1, true) ~= nil,
  "manager stopped via the sentinel, not a real error: " .. tostring(err))

-- inspect what reached the screen: PLAN must have drawn, and we must NOT be stuck
-- on the "Attach monitor" waiting screen (which means scan crashed under pcall).
local blob = table.concat(screen, "\n")
check(blob:find("Stock Keeper Plan", 1, true) ~= nil or blob:find("PLAN", 1, true) ~= nil,
  "a real page rendered (not blank)")
check(blob:find("Attach monitor", 1, true) == nil,
  "scan did not fall back to the waiting/error screen")

-- ---- resilience: a throwing rednet.broadcast must NOT cost the primary render -
-- The viewer broadcast is a best-effort, secondary path. If rednet.broadcast
-- raises (modem closed/removed mid-run), refreshAndDraw must still reach
-- renderCurrent() so the console paints, and the loop must survive. broadcast()
-- wraps the send in pcall for exactly this. This run flips broadcast to throw,
-- enables the modem so broadcast() is actually reached, and asserts a real page
-- still rendered (not the waiting/error screen).
do
  screen = {}
  ei = 0
  _G.os.pullEvent = scriptPull -- restore the script source (the prior run clobbered it)
  -- present a modem on "back" so openBroadcastModems flips broadcastReady = true
  _G.peripheral.getType = function(n)
    if n == "monitor_0" then return "monitor" end
    if n == "rs_bridge_0" then return "rs_bridge" end
    if n == "back" then return "modem" end
    return "unknown"
  end
  _G.rednet = {
    open = function() end,
    broadcast = function() error("modem detached mid-broadcast", 0) end,
  }
  local ok2 = pcall(function() dofile("inventory/manager.lua") end)
  check(ok2 == false, "throwing-broadcast run still hit the sentinel (loop survived)")
  local blob2 = table.concat(screen, "\n")
  check(blob2:find("Stock Keeper Plan", 1, true) ~= nil or blob2:find("PLAN", 1, true) ~= nil,
    "primary console rendered despite the broadcast throw (pcall contained it)")
  check(blob2:find("Attach monitor", 1, true) == nil,
    "broadcast throw did not blank the console to the waiting screen")
end

-- ---- resilience: a thrown scan should hold the last-good plan ----------------
-- Empty/offline grid reads already return "stale" and keep the last plan. A
-- transient exception from the bridge read path should do the same instead of
-- blanking the console to the waiting/attach screen.
do
  screen = {}
  files = {}
  ei = 0
  events = {
    { "timer", 1 }, -- good scan: establish lastData
    { "timer", 1 }, -- thrown scan: should keep lastData with a stale banner
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  _G.peripheral.getType = function(n)
    if n == "monitor_0" then return "monitor" end
    if n == "rs_bridge_0" then return "rs_bridge" end
    return "unknown"
  end
  BR = fakeBridge()
  local getItemsCalls = 0
  local goodGetItems = BR.getItems
  BR.getItems = function()
    getItemsCalls = getItemsCalls + 1
    if getItemsCalls == 2 then return { true } end
    return goodGetItems()
  end

  local ok3, err3 = pcall(function() dofile("inventory/manager.lua") end)
  check(ok3 == false and tostring(err3):find(SENTINEL, 1, true) ~= nil,
    "throwing-scan run still hit the sentinel (loop survived)")
  check(getItemsCalls >= 2, "throwing-scan run exercised a good scan then a thrown scan")
  local blob3 = table.concat(screen, "\n")
  check(blob3:find("Stock Keeper Plan", 1, true) ~= nil or blob3:find("PLAN", 1, true) ~= nil,
    "thrown scan kept the last-good plan on screen")
  check(blob3:find("Attach monitor", 1, true) == nil,
    "thrown scan did not blank the console to the waiting screen")
  check(blob3:find("holding last plan", 1, true) ~= nil,
    "thrown scan surfaced a stale/error banner")
end

-- ---- resilience: non-render handler errors should not drop the monitor --------
-- A redstone/read/control handler failure is contained by the input-loop guard, but
-- it should not force a monitor reacquire. Only render/peripheral-display faults
-- should clear the monitor handle.
do
  screen = {}
  files = {}
  ei = 0
  events = {
    { "timer", 1 }, -- acquire monitor + render
    { "redstone" }, -- throws in the handler guard
    { "timer", 1 }, -- should reuse the existing monitor, not wrap it again
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()
  local monitorWraps, redstoneReads = 0, 0
  local realWrap, realGetInput = _G.peripheral.wrap, _G.rs.getInput
  _G.peripheral.wrap = function(n)
    if n == "monitor_0" then monitorWraps = monitorWraps + 1; return MON end
    if n == "rs_bridge_0" then return BR end
    return nil
  end
  _G.rs.getInput = function()
    redstoneReads = redstoneReads + 1
    error("redstone read exploded", 0)
  end

  local ok4, err4 = pcall(function() dofile("inventory/manager.lua") end)
  _G.peripheral.wrap, _G.rs.getInput = realWrap, realGetInput
  check(ok4 == false and tostring(err4):find(SENTINEL, 1, true) ~= nil,
    "redstone-error run still hit the sentinel (loop survived)")
  check(redstoneReads == 1, "redstone-error run exercised the throwing handler")
  check(monitorWraps == 1, "non-render handler error did not drop/re-wrap the monitor")
end

-- ---- resilience: partial bridge-stat reads keep prior display values ----------
-- Storage/energy stats are display-only and throttled. If one throttled refresh
-- returns nil fields, the broadcast/viewer payload should keep the last known value
-- per field instead of blanking the panels.
do
  screen = {}
  files = {}
  ei = 0
  events = {
    { "timer", 1 },
    { "timer", 1 },
  }
  _G.os.pullEvent = scriptPull
  local realGetType = _G.peripheral.getType
  _G.peripheral.getType = function(n)
    if n == "monitor_0" then return "monitor" end
    if n == "rs_bridge_0" then return "rs_bridge" end
    if n == "back" then return "modem" end
    return "unknown"
  end
  local realEpoch = _G.os.epoch
  _G.os.epoch = function() clock = clock + 20000; return clock end
  local payloads = {}
  _G.rednet = {
    open = function() end,
    broadcast = function(payload) payloads[#payloads + 1] = payload end,
  }
  BR = fakeBridge()
  local scanN = 0
  local goodGetItems = BR.getItems
  BR.getItems = function()
    scanN = scanN + 1
    return goodGetItems()
  end
  local function stat(v) if scanN <= 1 then return v end return nil end
  BR.getUsedItemStorage = function() return stat(1000) end
  BR.getTotalItemStorage = function() return stat(100000) end
  BR.getAvailableItemStorage = function() return stat(99000) end
  BR.getStoredEnergy = function() return stat(50000) end
  BR.getEnergyCapacity = function() return stat(50000) end
  BR.getEnergyUsage = function() return stat(1000) end

  local ok5, err5 = pcall(function() dofile("inventory/manager.lua") end)
  _G.peripheral.getType = realGetType
  _G.os.epoch = realEpoch
  check(ok5 == false and tostring(err5):find(SENTINEL, 1, true) ~= nil,
    "partial-stats run still hit the sentinel (loop survived)")
  check(#payloads >= 2, "partial-stats run broadcast two payloads")
  local second = payloads[2] or {}
  check(second.usedItemStorage == 1000 and second.totalItemStorage == 100000,
    "partial storage stat refresh kept prior storage values")
  check(second.storedEnergy == 50000 and second.energyCapacity == 50000 and second.energyUsage == 1000,
    "partial energy stat refresh kept prior energy values")
end

-- ---- resilience: failed serialization stays inside the guarded write path -----
-- State writes are best-effort. If serialization itself throws, it should return a
-- failed write, not escape into the loop guard.
do
  screen = {}
  files = {}
  ei = 0
  events = {
    { "timer", 1 },
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()
  local realSerialize, realPrint = _G.textutils.serialize, print
  local logged = {}
  _G.textutils.serialize = function(value)
    if type(value) == "table" then error("serialize exploded", 0) end
    return realSerialize(value)
  end
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    logged[#logged + 1] = table.concat(parts, " ")
    realPrint(...)
  end

  local ok6, err6 = pcall(function() dofile("inventory/manager.lua") end)
  _G.textutils.serialize, _G.print = realSerialize, realPrint
  check(ok6 == false and tostring(err6):find(SENTINEL, 1, true) ~= nil,
    "serialize-failure run still hit the sentinel (loop survived)")
  local loopErr = false
  for _, line in ipairs(logged) do if line:find("loop error", 1, true) then loopErr = true end end
  check(not loopErr, "serialize failure stayed inside the guarded write path")
end

-- ---- browse: empty managed filter must still draw the footer toggle -----------
-- When MANAGED has zero rows, Browse must still show the bottom toggle so the
-- operator can get back to ALL. This catches the early-return render path.
do
  screen = {}
  files = {}
  ei = 0
  events = {
    { "timer", 1 },
    { "monitor_touch", "r", 25, 2 }, -- BROWSE tab
    { "monitor_touch", "r", 30, 24 }, -- [ALL] -> [MANAGED], which is empty here
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()

  local ok7, err7 = pcall(function() dofile("inventory/manager.lua") end)
  check(ok7 == false and tostring(err7):find(SENTINEL, 1, true) ~= nil,
    "empty-managed Browse run still hit the sentinel (loop survived)")
  local blob7 = table.concat(screen, "\n")
  check(blob7:find("Browse Grid", 1, true) ~= nil,
    "Browse page actually rendered in smoke")
  check(blob7:find("[MANAGED]", 1, true) ~= nil,
    "empty managed Browse still renders the MANAGED footer toggle")
end

-- ---- browse: sort chip cycles the rendered order mode ------------------------
do
  screen = {}
  files = {}
  ei = 0
  events = {
    { "timer", 1 },
    { "monitor_touch", "r", 25, 2 }, -- BROWSE tab
    { "monitor_touch", "r", 24, 24 }, -- [QTY] -> [A-Z]
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()

  local ok8, err8 = pcall(function() dofile("inventory/manager.lua") end)
  check(ok8 == false and tostring(err8):find(SENTINEL, 1, true) ~= nil,
    "Browse sort run still hit the sentinel (loop survived)")
  local blob8 = table.concat(screen, "\n")
  check(blob8:find("[A-Z]", 1, true) ~= nil,
    "Browse sort chip cycles from QTY to A-Z")
end

-- ---- managed store: an out-of-band disk change survives an operator tap -------
-- The managedStore cache is loaded once per run; the CLOBBER bug was saving that
-- stale cache wholesale, wiping any newer on-disk state (external backfill). This
-- run caches the (empty) store in cycle 1, seeds a quota into the FILE mid-run,
-- then taps the SMART toggle. mutateManaged must reload-mutate-save so BOTH the
-- seeded quota and the toggle land. BITING: restore save-the-cache semantics in
-- mutateManaged and the backfill assert fails.
do
  screen = {}
  files = {}
  ei = 0
  local function realSer(v)
    if type(v) == "table" then
      local parts = {}
      for k, val in pairs(v) do
        local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. tostring(k) .. "]")
        parts[#parts + 1] = key .. "=" .. realSer(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    elseif type(v) == "string" then
      return string.format("%q", v)
    end
    return tostring(v)
  end
  -- fs-stub writes are lossy for atomicWrite targets (close promotes, move nils),
  -- so capture the persisted managed store via a serialize spy like other sections.
  local savedManaged = nil
  _G.textutils = {
    serialize = function(t)
      if type(t) == "table" and type(t.items) == "table" then savedManaged = t end
      return realSer(t)
    end,
    unserialize = function(text)
      local f = load("return " .. tostring(text))
      if not f then return nil end
      local okU, v = pcall(f)
      if okU then return v end
      return nil
    end,
  }
  local SEED = realSer({ items = { ["mc:backfill_test"] = {
    name = "mc:backfill_test", label = "Backfill Test", target = 64, craftTo = 128, addedAt = 1,
  } }, rev = 7 })
  events = {
    { "timer", 1 },                  -- cycle 1: scan caches the (empty) managed store
    { "SEED" },                      -- out-of-band: a backfill lands ON DISK mid-run
    { "monitor_touch", "r", 46, 2 }, -- tab -> SMART ([SMART] spans cols 44-50 post-HEALTH)
    { "monitor_touch", "r", 1, 7 },  -- SMART toggle -> mutateManaged writes the store
  }
  _G.os.pullEvent = function()
    ei = ei + 1
    local ev = events[ei]
    if not ev then error(SENTINEL, 0) end
    if ev[1] == "SEED" then
      files[".atm10-managed"] = SEED
      ei = ei + 1
      ev = events[ei]
      if not ev then error(SENTINEL, 0) end
    end
    return table.unpack(ev)
  end
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()

  local okM, errM = pcall(function() dofile("inventory/manager.lua") end)
  check(okM == false and tostring(errM):find(SENTINEL, 1, true) ~= nil,
    "managed-clobber run still hit the sentinel (loop survived)")
  check(type(savedManaged) == "table" and type(savedManaged.settings) == "table"
      and savedManaged.settings.smartMode == true,
    "SMART toggle persisted its setting through mutateManaged")
  check(type(savedManaged) == "table" and type(savedManaged.items) == "table"
      and savedManaged.items["mc:backfill_test"] ~= nil,
    "out-of-band backfilled quota SURVIVED the operator tap (no stale-cache clobber)")
end

-- ---- queue: failed entries show retry control and tap clears backoff ----------
do
  screen = {}
  files = { [".atm10-craft-queue"] = "FAILED_QUEUE" }
  local savedQueue = nil
  _G.textutils = {
    serialize = function(t) savedQueue = t; return "{}" end,
    unserialize = function(text)
      if text == "FAILED_QUEUE" then
        return { entries = {
          failed = {
            key = "failed",
            name = "alltheores:zinc_ingot",
            label = "Zinc",
            request = 32,
            state = "APPROVED",
            approvedAt = 50,
            triedAt = 1000000000,
            error = "missing ingredients",
          },
        } }
      end
      return {}
    end,
  }
  ei = 0
  events = {
    { "timer", 1 },
    { "monitor_touch", "r", 10, 2 }, -- QUEUE tab
    { "monitor_touch", "r", 26, 9 }, -- [RETRY FAILED]
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()

  local ok9, err9 = pcall(function() dofile("inventory/manager.lua") end)
  check(ok9 == false and tostring(err9):find(SENTINEL, 1, true) ~= nil,
    "Queue retry run still hit the sentinel (loop survived)")
  local blob9 = table.concat(screen, "\n")
  check(blob9:find("[ RETRY FAILED ]", 1, true) ~= nil,
    "failed Queue entries render a retry-failed footer button")
  check(type(savedQueue) == "table"
      and savedQueue.entries
      and savedQueue.entries.failed
      and savedQueue.entries.failed.error == nil
      and savedQueue.entries.failed.triedAt == nil,
    "tapping retry failed clears the queued entry error/backoff")
end

-- ---- queue: active AP task snapshot surfaces live progress ------------------
do
  screen = {}
  files = { [".atm10-craft-queue"] = "ACTIVE_QUEUE" }
  _G.textutils = {
    serialize = function() return "{}" end,
    unserialize = function(text)
      if text == "ACTIVE_QUEUE" then
        return { entries = {
          live = {
            key = "live",
            name = "alltheores:zinc_block",
            label = "Zinc Block",
            request = 64,
            state = "APPROVED",
            approvedAt = 50,
          },
        } }
      end
      return {}
    end,
  }
  ei = 0
  events = {
    { "timer", 1 },
    { "monitor_touch", "r", 10, 2 }, -- QUEUE tab
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()
  BR.getCraftingTasks = function()
    return {
      {
        bridge_id = 77,
        id = "live-zinc",
        crafted = 12,
        quantity = 64,
        completion = 0.25,
        resource = { name = "alltheores:zinc_block", displayName = "Zinc Block" },
      },
    }
  end

  local ok10, err10 = pcall(function() dofile("inventory/manager.lua") end)
  check(ok10 == false and tostring(err10):find(SENTINEL, 1, true) ~= nil,
    "Queue active-task run still hit the sentinel (loop survived)")
  local blob10 = table.concat(screen, "\n")
  check(blob10:find("Zinc Block", 1, true) ~= nil and blob10:find("25%%") ~= nil,
    "Queue row surfaces live active-task progress")
end

-- ---- queue safety: empty task list still verifies locally CRAFTING rows -------
-- The broad planner may trust an empty getCraftingTasks() snapshot for speed, but
-- queue/drain safety must be more conservative: if a row is already CRAFTING and
-- the per-item method says it is still active, an empty task list must not stale it.
do
  screen = {}
  files = { [".atm10-craft-queue"] = "LYING_EMPTY_TASKS" }
  clock = 100000
  _G.textutils = {
    serialize = function() return "{}" end,
    unserialize = function(text)
      if text == "LYING_EMPTY_TASKS" then
        return { entries = {
          live = {
            key = "live",
            name = "alltheores:zinc_block",
            label = "Zinc Block",
            request = 64,
            state = "CRAFTING",
            approvedAt = 1,
            craftingAt = 1,
          },
        } }
      end
      return {}
    end,
  }
  local queueWrites = 0
  local realOpen = _G.fs.open
  _G.fs.open = function(p, mode)
    if mode == "w" and tostring(p):find(".atm10-craft-queue", 1, true) then
      queueWrites = queueWrites + 1
    end
    return realOpen(p, mode)
  end
  ei = 0
  events = {
    { "timer", 1 },
    { "monitor_touch", "r", 10, 2 }, -- QUEUE tab
  }
  _G.os.pullEvent = scriptPull
  _G.rednet = { open = function() end, broadcast = function() end }
  BR = fakeBridge()
  local perItemChecks = 0
  BR.getCraftingTasks = function() return {} end
  BR.isItemCrafting = nil
  BR.isCrafting = function(arg)
    perItemChecks = perItemChecks + 1
    return type(arg) == "table" and arg.name == "alltheores:zinc_block"
  end

  local ok11, err11 = pcall(function() dofile("inventory/manager.lua") end)
  _G.fs.open = realOpen
  check(ok11 == false and tostring(err11):find(SENTINEL, 1, true) ~= nil,
    "empty-task queue-safety run still hit the sentinel (loop survived)")
  check(perItemChecks > 0,
    "empty getCraftingTasks snapshot still verifies existing CRAFTING rows per item")
  check(queueWrites == 0,
    "per-item active CRAFTING row is not marked stale after an empty task-list snapshot")
end

print((failures == 0) and "SMOKE OK" or ("SMOKE FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
