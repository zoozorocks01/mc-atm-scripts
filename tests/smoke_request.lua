-- Off-CC LOAD + END-TO-END test of the A2 craft-request panel
-- (inventory/request.lua) in a stubbed CC env. Proves the program loads (no
-- missing require/global), renders >=1 frame without error, and that a SUBMIT
-- touch produces EXACTLY ONE rednet.send on the control protocol whose payload
-- is action="craft_request", target=<selected name>, args.count=<picked qty>,
-- token=<resolved>. The loop ends in `while true`, so a scripted os.pullEvent
-- feeds events then errors a sentinel to break out (the smoke_auto pattern).
--
-- Run:  lua tests/smoke_request.lua
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
  clock = function() clock = clock + 1; return clock end,
  epoch = function() clock = clock + 50; return clock end,
  startTimer = function() return 1 end,
  getComputerID = function() return 9 end,
}

-- no token file (panel sends token=nil; this is the safe default we assert)
_G.fs = {
  exists = function() return false end,
  open = function() return nil end,
}

_G.rs = {
  getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
}

-- rednet: SPY every send so we can assert the SUBMIT produced exactly one
-- craft_request on the control protocol.
local sent = {}
_G.rednet = {
  open = function() end,
  broadcast = function() end,
  send = function(id, msg, protocol) sent[#sent + 1] = { id = id, msg = msg, protocol = protocol } end,
}

-- fake monitor: 60x24, records nothing meaningful but answers the buffer API
-- (setCursorPos/blit) so renderBuffer works.
local function fakeMonitor()
  local m, noop = {}, function() end
  m.setBackgroundColor, m.setTextColor, m.setTextScale = noop, noop, noop
  m.setPaletteColour, m.setPaletteColor = noop, noop
  m.clear, m.clearLine = noop, noop
  m.setCursorPos = noop
  m.isColor = function() return true end
  m.getSize = function() return 60, 24 end
  m.write = noop
  m.blit = noop
  return m
end

local MON = fakeMonitor()
_G.peripheral = {
  getNames = function() return { "monitor_0" } end,
  getType = function(n)
    if n == "monitor_0" then return "monitor" end
    if n == "back" then return "modem" end -- modem reachable on a side (openModems scans sides)
    return "unknown"
  end,
  wrap = function(n) if n == "monitor_0" then return MON end return nil end,
  find = function() return nil end,
}

-- sleep is only reached on the no-modem/no-monitor branch (not in our happy path),
-- but stub it defensively so a stray call never throws.
_G.sleep = function() end

-- ---- compute the touch coordinates the program will hit ---------------------
-- We replicate the program's known layout via the SAME console helpers it uses,
-- so the smoke targets the real button x/y without reaching into program locals.
local console = require("atm10-console")

local SELECTED_NAME = "alltheores:zinc_ingot"
local PICKED_QTY = 9 -- 1 (default) +8 via one inc:8 tap
local viewItems = {
  { name = SELECTED_NAME, id = SELECTED_NAME, amount = 1000 },
  { name = "minecraft:iron_ingot", id = "minecraft:iron_ingot", amount = 5000 },
}

-- Browse: drawBrowse sorts viewItems by "qty" (iron 5000 > zinc 1000), so after
-- the sort the FIRST row is iron, the SECOND is zinc. listStart = headerY+1 = 7.
-- We want zinc -> tap the second row (y = 8). x anywhere in the row (x = 5).
local SORTED = { table.unpack(viewItems) }
console.sortItems(SORTED, "qty")
local zincRow
for i, it in ipairs(SORTED) do if it.name == SELECTED_NAME then zincRow = i end end
local listStart = 7
local ZINC_Y = listStart + (zincRow - 1)

-- Detail: quantityButtonRow(qty, 9, 1). Find inc:8 and submit x.
local qrow = console.quantityButtonRow(1, 9, 1)
local INC8_X, SUBMIT_X
for _, b in ipairs(qrow.buttons) do
  if b.key == "inc:8" then INC8_X = b.x1 end
  if b.key == "submit" then SUBMIT_X = b.x1 end
end

-- ---- scripted event sequence -----------------------------------------------
-- 1) a timer (acquires monitor/modem on the first loop pass, first render)
-- 2) the inventory_snapshot (viewItems + source id) -> learn managerId
-- 3) monitor_touch on the zinc row -> selects it, mode=detail
-- 4) monitor_touch on [+8] -> qty 1 -> 9
-- 5) monitor_touch on [SUBMIT] -> rednet.send craft_request
-- 6) sentinel -> break the while-true loop
local SENTINEL = "__SMOKE_REQUEST_DONE__"
local snapshot = {
  kind = "inventory_snapshot",
  source = 6,
  viewItems = viewItems,
  craftQueue = {},
}
local events = {
  { "timer", 1 },
  { "rednet_message", 6, snapshot, "atm10-inventory-v1" },
  { "monitor_touch", "monitor_0", 5, ZINC_Y },
  { "monitor_touch", "monitor_0", INC8_X, 9 },
  { "monitor_touch", "monitor_0", SUBMIT_X, 9 },
}
local ei = 0
_G.os.pullEvent = function()
  ei = ei + 1
  local ev = events[ei]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end

-- ---- run it ----------------------------------------------------------------
print("smoke-request: running inventory/request.lua, selecting " .. SELECTED_NAME ..
  " and submitting x" .. PICKED_QTY)
local ok, err = pcall(function() dofile("inventory/request.lua") end)
check(ok == false and tostring(err):find(SENTINEL, 1, true) ~= nil,
  "panel loaded, rendered, and ran the scripted cycle to the sentinel: " .. tostring(err))

-- exactly one control-protocol craft_request from the SUBMIT touch
local control = require("atm10-control")
local crafts = {}
for _, s in ipairs(sent) do
  if s.protocol == control.PROTOCOL and type(s.msg) == "table" and s.msg.action == "craft_request" then
    crafts[#crafts + 1] = s
  end
end
check(#crafts == 1, "SUBMIT produced EXACTLY ONE craft_request on the control protocol (got " .. #crafts .. ")")
if crafts[1] then
  local m = crafts[1].msg
  check(m.target == SELECTED_NAME, "craft_request target is the selected registry name (" .. tostring(m.target) .. ")")
  check(type(m.args) == "table" and m.args.count == PICKED_QTY,
    "craft_request args.count is the picked qty (" .. tostring(m.args and m.args.count) .. ")")
  check(m.token == nil, "craft_request token is the resolved value (nil, no token file)")
  check(crafts[1].id == 6, "craft_request was sent to the learned manager source id (6)")
end

print("")
if failures == 0 then
  print("SMOKE-REQUEST OK")
  os.exit(0)
else
  print(failures .. " smoke-request FAILURES")
  os.exit(1)
end
