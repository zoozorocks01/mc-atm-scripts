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

print((failures == 0) and "SMOKE-AUTO OK" or ("SMOKE-AUTO FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
