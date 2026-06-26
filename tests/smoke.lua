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
  { "monitor_touch", "r", 18, 2 },      -- tab -> BROWSE
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
_G.os.pullEvent = function()
  ei = ei + 1
  local ev = events[ei]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end

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

print((failures == 0) and "SMOKE OK" or ("SMOKE FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
