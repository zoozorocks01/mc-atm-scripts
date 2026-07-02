-- Off-CC LOAD + TOUCH test of the read-only inventory viewer
-- (inventory/remote.lua). Proves the viewer loads, consumes a snapshot, and that
-- touch paging/filter/detail/sort paths render visible state without writing to
-- the manager/control channel.
--
-- Run:  lua tests/smoke_remote.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

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
  getComputerID = function() return 8 end,
}

_G.fs = {
  exists = function() return false end,
  open = function() return nil end,
}

_G.rs = {
  getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
}

local sent = {}
_G.rednet = {
  open = function() end,
  broadcast = function() end,
  send = function(id, msg, protocol) sent[#sent + 1] = { id = id, msg = msg, protocol = protocol } end,
}

local rendered = {}
local function fakeMonitor()
  local m, noop = {}, function() end
  local cx, cy = 1, 1
  m.setBackgroundColor, m.setTextColor, m.setTextScale = noop, noop, noop
  m.setPaletteColour, m.setPaletteColor = noop, noop
  m.clear, m.clearLine = noop, noop
  m.setCursorPos = function(x, y) cx, cy = x, y end
  m.isColor = function() return true end
  m.getSize = function() return 60, 24 end
  m.write = function(text) rendered[#rendered + 1] = tostring(text or "") end
  m.blit = function(text)
    rendered[#rendered + 1] = tostring(text or "")
    cx = cx + #(text or "")
  end
  return m
end

local MON = fakeMonitor()
_G.peripheral = {
  getNames = function() return { "monitor_0" } end,
  getType = function(n)
    if n == "monitor_0" then return "monitor" end
    if n == "back" then return "modem" end
    return "unknown"
  end,
  wrap = function(n) if n == "monitor_0" then return MON end return nil end,
  find = function() return nil end,
}

_G.sleep = function() end

local viewItems = {
  { name = "Alpha Item", id = "test:alpha_item", amount = 13000 },
  { name = "Beta Item", id = "test:beta_item", amount = 12000 },
  { name = "Copper Ingot", id = "alltheores:copper_ingot", amount = 11000 },
  { name = "Diamond", id = "minecraft:diamond", amount = 10000 },
  { name = "Emerald", id = "minecraft:emerald", amount = 9000 },
  { name = "Gold Ingot", id = "minecraft:gold_ingot", amount = 8000 },
  { name = "Iron Ingot", id = "minecraft:iron_ingot", amount = 7000 },
  { name = "Lead Ingot", id = "alltheores:lead_ingot", amount = 6000 },
  { name = "Nickel Ingot", id = "alltheores:nickel_ingot", amount = 5000 },
  { name = "Quartz", id = "minecraft:quartz", amount = 4000 },
  { name = "Redstone", id = "minecraft:redstone", amount = 3000 },
  { name = "Tin Ingot", id = "alltheores:tin_ingot", amount = 2000 },
  { name = "Zinc Dust", id = "alltheores:zinc_dust", amount = 1000,
    trend = { dir = "down", perMin = 2 } },
}

local snapshot = {
  kind = "inventory_snapshot",
  source = 6,
  online = true,
  unique = #viewItems,
  totalAmount = 91000,
  listedItemCount = #viewItems,
  managedItemCount = 0,
  defaultHandling = "unmanaged",
  viewItems = viewItems,
  usedItemStorage = 1000,
  totalItemStorage = 100000,
  availableItemStorage = 99000,
  storedEnergy = 50000,
  energyCapacity = 100000,
}

local SENTINEL = "__SMOKE_REMOTE_DONE__"
local events = {
  { "rednet_message", 6, snapshot, "atm10-inventory-v1" },
  { "monitor_touch", "monitor_0", 10, 24 }, -- [NEXT >] -> page 2
  { "monitor_touch", "monitor_0", 31, 13 }, -- [DUST] filter -> 1 match
  { "monitor_touch", "monitor_0", 5, 14 },  -- row tap -> detail card
  { "monitor_touch", "monitor_0", 20, 24 }, -- [SORT:Qty] -> [SORT:A-Z]
  -- ORDER bite (VIEW-3): this fixture is qty-descending AND alphabetical at once,
  -- so a label-only check can't tell a real re-sort from a no-op. Clear the filter
  -- and cycle to Mod sort, where the order genuinely flips: alltheores: rows lead
  -- and the test: items (Alpha/Beta, qty #1/#2) drop to the bottom.
  { "monitor_touch", "monitor_0", 2, 13 },  -- [ALL] filter -> full list again
  { "monitor_touch", "monitor_0", 20, 24 }, -- [SORT:A-Z] -> [SORT:Mod] (order must flip)
}
local ei = 0
_G.os.pullEvent = function()
  ei = ei + 1
  local ev = events[ei]
  if not ev then error(SENTINEL, 0) end
  return table.unpack(ev)
end

print("smoke-remote: running inventory/remote.lua against a paged/filterable snapshot")
local ok, err = pcall(function() dofile("inventory/remote.lua") end)
check(ok == false and tostring(err):find(SENTINEL, 1, true) ~= nil,
  "remote loaded, rendered, and ran scripted touches to sentinel: " .. tostring(err))

local blob = table.concat(rendered, "\n")
check(blob:find("page 2/2", 1, true) ~= nil, "NEXT touch paged the viewer list")
check(blob:find("[DUST]", 1, true) ~= nil, "filter chips rendered")
check(blob:find("1/13 shown", 1, true) ~= nil, "DUST filter narrowed the list to one item")
check(blob:find("ITEM DETAIL", 1, true) ~= nil, "row tap opened the read-only detail card")
check(blob:find("alltheores:zinc_dust", 1, true) ~= nil, "detail card includes the registry id")
check(blob:find("[SORT:A-Z]", 1, true) ~= nil, "sort chip cycles from Qty to A-Z")
check(blob:find("[SORT:Mod]", 1, true) ~= nil, "sort chip cycles on to Mod")
-- The FINAL render (after the Mod tap) must actually reorder the rows: row 1 is
-- Copper Ingot (first alltheores: by name), not qty-leader Alpha Item (test:).
local lastRow1 = nil
for i = #rendered, 1, -1 do
  if rendered[i]:match("^%s+1%. ") then lastRow1 = rendered[i]; break end
end
check(lastRow1 ~= nil and lastRow1:find("Copper Ingot", 1, true) ~= nil,
  "sort tap actually REORDERS the list (Mod sort row 1 = Copper Ingot, got: " .. tostring(lastRow1) .. ")")
check(#sent == 0, "remote viewer sent no rednet control messages")

print("")
if failures == 0 then
  print("SMOKE-REMOTE OK")
  os.exit(0)
else
  print(failures .. " smoke-remote FAILURES")
  os.exit(1)
end
