-- Local CC:Tweaked simulation harness for inventory/manager.lua.
-- Dev-only: lets host-side tests run the manager against scripted events and a
-- fake RS bridge without touching the live Minecraft server.

local M = {}

local GLOBAL_KEYS = {
  "colors", "os", "fs", "textutils", "peripheral", "rednet", "rs", "parallel",
  "sleep", "print", "dofile",
}

local COLOR_NAMES = {
  "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
  "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

local function deepcopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do copy[deepcopy(k, seen)] = deepcopy(v, seen) end
  return copy
end

local function sortedKeys(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return tostring(a) < tostring(b) end
    return type(a) < type(b)
  end)
  return keys
end

function M.serialize(value, seen)
  local t = type(value)
  if t == "nil" or t == "boolean" or t == "number" then return tostring(value) end
  if t == "string" then return string.format("%q", value) end
  if t ~= "table" then error("cannot serialize " .. t, 0) end
  seen = seen or {}
  if seen[value] then error("cannot serialize recursive table", 0) end
  seen[value] = true
  local parts = {}
  for _, k in ipairs(sortedKeys(value)) do
    parts[#parts + 1] = "[" .. M.serialize(k, seen) .. "]=" .. M.serialize(value[k], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.unserialize(text)
  if type(text) ~= "string" then return nil end
  local chunk = load("return " .. text, "atm10-sim-data", "t", {})
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if not ok then return nil end
  return value
end

local function dynamic(value, ...)
  if type(value) == "function" then return value(...) end
  return value
end

local function fakeMonitor()
  local monitor, noop = {}, function() end
  monitor.setBackgroundColor, monitor.setTextColor, monitor.setTextScale = noop, noop, noop
  monitor.setPaletteColour, monitor.setPaletteColor = noop, noop
  monitor.clear, monitor.clearLine, monitor.setCursorPos = noop, noop, noop
  monitor.write, monitor.blit = noop, noop
  monitor.isColor = function() return true end
  monitor.getSize = function() return 60, 24 end
  return monitor
end

function M.bridge(opts)
  opts = opts or {}
  local bridge = {}
  local crafted = {}
  local jobSeq = tonumber(opts.jobSeq) or 1000

  local function itemList(...)
    return deepcopy(dynamic(opts.items, bridge, ...) or {})
  end

  local function craftableList(...)
    local configured = dynamic(opts.craftableItems, bridge, ...)
    if configured then return deepcopy(configured) end
    local out = {}
    for _, item in ipairs(itemList(...)) do
      if item.isCraftable == true and item.name then out[#out + 1] = { name = item.name } end
    end
    return out
  end

  local function itemByName(name, ...)
    for _, item in ipairs(itemList(...)) do
      if item.name == name then return item end
    end
    return nil
  end

  local function boolOrDefault(value, default, ...)
    local resolved = dynamic(value, bridge, ...)
    if resolved == nil then return default end
    return resolved
  end

  local function craftable(name, ...)
    local item = itemByName(name, ...)
    if item and item.isCraftable ~= nil then return item.isCraftable == true end
    for _, row in ipairs(craftableList(...)) do
      if row.name == name then return true end
    end
    return false
  end

  bridge.isConnected = function(...) return boolOrDefault(opts.connected, true, ...) end
  bridge.isOnline = function(...) return boolOrDefault(opts.online, true, ...) end
  bridge.getItems = function(...) return itemList(...) end
  bridge.getItem = function(arg, ...)
    local name = type(arg) == "table" and arg.name or arg
    return itemByName(name, ...)
  end
  bridge.getCraftableItems = function(...) return craftableList(...) end
  bridge.isCraftable = function(arg, ...)
    local name = type(arg) == "table" and arg.name or arg
    return craftable(name, ...)
  end
  bridge.isItemCraftable = bridge.isCraftable
  bridge.getCraftingTasks = function(...) return deepcopy(dynamic(opts.tasks, bridge, ...) or {}) end
  if opts.getCraftingTask ~= false then
    bridge.getCraftingTask = function(id, ...)
      local jobs = dynamic(opts.jobs, bridge, ...) or {}
      return jobs[id] or jobs[tostring(id)]
    end
  end
  bridge.isItemCrafting = function(arg, ...)
    local name = type(arg) == "table" and arg.name or arg
    local byName = dynamic(opts.craftingByName, bridge, ...) or {}
    return byName[name] == true
  end
  bridge.isCrafting = bridge.isItemCrafting
  bridge.craftItem = function(arg, ...)
    if opts.craftItem then return opts.craftItem(arg, bridge, ...) end
    crafted[#crafted + 1] = deepcopy(arg)
    jobSeq = jobSeq + 1
    local id = jobSeq
    return { getId = function() return id end, id = id }
  end
  bridge.getUsedItemStorage = function() return tonumber(opts.usedItemStorage) or 1000 end
  bridge.getTotalItemStorage = function() return tonumber(opts.totalItemStorage) or 100000 end
  bridge.getAvailableItemStorage = function() return tonumber(opts.availableItemStorage) or 99000 end
  bridge.getStoredEnergy = function() return tonumber(opts.storedEnergy) or 50000 end
  bridge.getEnergyCapacity = function() return tonumber(opts.energyCapacity) or 50000 end
  bridge.getEnergyUsage = function() return tonumber(opts.energyUsage) or 1000 end
  bridge.__crafted = crafted
  return bridge
end

local Sim = {}
Sim.__index = Sim

local function installColors()
  _G.colors = {}
  for i, name in ipairs(COLOR_NAMES) do _G.colors[name] = 2 ^ (i - 1) end
end

local function makeFs(sim)
  return {
    exists = function(path) return sim.files[path] ~= nil end,
    open = function(path, mode)
      if mode == "r" then
        if sim.files[path] == nil then return nil end
        local content, read = sim.files[path], false
        return {
          readAll = function()
            if read then return nil end
            read = true
            return content
          end,
          close = function() end,
        }
      end
      if mode == "w" then
        local pending = {}
        return {
          write = function(text) pending[#pending + 1] = tostring(text or "") end,
          close = function() sim.files[path] = table.concat(pending) end,
        }
      end
      return nil
    end,
    delete = function(path) sim.files[path] = nil end,
    move = function(from, to)
      if sim.files[from] == nil then error("missing source: " .. tostring(from), 0) end
      sim.files[to] = sim.files[from]
      sim.files[from] = nil
    end,
    getDir = function(path)
      local dir = tostring(path or ""):match("^(.*)/[^/]*$")
      return dir or ""
    end,
    makeDir = function() end,
  }
end

local function installParallel(sim)
  _G.parallel = {
    waitForAny = function(scanLoop, inputLoop)
      local script = _G.os.pullEvent
      local scanCo = coroutine.create(scanLoop)
      local inputCo = coroutine.create(inputLoop)
      _G.sleep = function() return coroutine.yield() end
      _G.os.pullEvent = function() return coroutine.yield() end

      local function step(co, ...)
        local ok, err = coroutine.resume(co, ...)
        if not ok then error(err, 0) end
        return coroutine.status(co) == "dead"
      end

      step(inputCo)
      while true do
        local ev = { script() }
        sim.eventsConsumed = sim.eventsConsumed + 1
        if ev[1] == "timer" then
          if step(scanCo) then return end
        else
          if step(inputCo, table.unpack(ev)) then return end
        end
      end
    end,
  }
end

function Sim:setFile(path, content)
  self.files[path] = content
end

function Sim:setSerializedFile(path, value)
  self.files[path] = M.serialize(value)
end

function Sim:getSerializedFile(path)
  return M.unserialize(self.files[path])
end

function Sim:nextEvent()
  self.eventIndex = self.eventIndex + 1
  local ev = self.events[self.eventIndex]
  if type(ev) == "function" then ev = ev(self) end
  if not ev then error(self.sentinel, 0) end
  return table.unpack(ev)
end

function Sim:install()
  package.path = "./lib/?.lua;./tests/?.lua;" .. package.path
  self.saved = {}
  for _, key in ipairs(GLOBAL_KEYS) do self.saved[key] = _G[key] end

  installColors()
  local realOs = self.saved.os or os
  _G.os = {
    exit = realOs.exit,
    time = realOs.time,
    date = realOs.date,
    epoch = function()
      self.clock = self.clock + self.clockStep
      return self.clock
    end,
    clock = function()
      self.clock = self.clock + 1
      return self.clock
    end,
    startTimer = function() return 1 end,
    getComputerID = function() return self.computerId end,
    pullEvent = function() return self:nextEvent() end,
  }
  _G.fs = makeFs(self)
  _G.textutils = { serialize = M.serialize, unserialize = M.unserialize }
  _G.rs = {
    getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
    getInput = function() return false end,
  }
  _G.rednet = {
    open = function() end,
    broadcast = function(payload, protocol)
      self.broadcasts[#self.broadcasts + 1] = { payload = deepcopy(payload), protocol = protocol }
    end,
  }
  _G.peripheral = {
    getNames = function() return { "monitor_0", "rs_bridge_0" } end,
    getType = function(name)
      if name == "monitor_0" then return "monitor" end
      if name == "rs_bridge_0" then return "rs_bridge" end
      return "unknown"
    end,
    wrap = function(name)
      if name == "monitor_0" then return self.monitor end
      if name == "rs_bridge_0" then return self.bridge end
      return nil
    end,
    find = function() return nil end,
  }
  installParallel(self)

  local realPrint = self.saved.print or print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local line = table.concat(parts, " ")
    self.prints[#self.prints + 1] = line
    if self.echo then realPrint(line) end
  end

  local realDofile = self.saved.dofile or dofile
  _G.dofile = function(path)
    if self.dofileTables[path] ~= nil then return deepcopy(self.dofileTables[path]) end
    return realDofile(path)
  end
end

function Sim:restore()
  if not self.saved then return end
  for _, key in ipairs(GLOBAL_KEYS) do _G[key] = self.saved[key] end
  self.saved = nil
end

function Sim:run()
  self:install()
  local ok, err = pcall(function() dofile(self.managerPath) end)
  self:restore()
  local result = {
    ok = ok,
    err = err,
    sentinel = self.sentinel,
    files = self.files,
    prints = self.prints,
    broadcasts = self.broadcasts,
    crafted = self.bridge and self.bridge.__crafted or {},
    eventsConsumed = self.eventsConsumed,
    sim = self,
  }
  self.result = result
  return result
end

function M.new(opts)
  opts = opts or {}
  local sim = setmetatable({
    files = {},
    events = opts.events or { { "timer", 1 } },
    eventIndex = 0,
    eventsConsumed = 0,
    sentinel = opts.sentinel or "__ATM10_SIM_DONE__",
    managerPath = opts.managerPath or "inventory/manager.lua",
    clock = tonumber(opts.clockStart) or 0,
    clockStep = tonumber(opts.clockStep) or 50,
    computerId = tonumber(opts.computerId) or 7,
    monitor = opts.monitor or fakeMonitor(),
    bridge = opts.bridge or M.bridge(opts.bridgeOpts or {}),
    broadcasts = {},
    prints = {},
    dofileTables = {},
    echo = opts.echo == true,
  }, Sim)

  sim:setSerializedFile(".atm10-managed", opts.managedStore or { items = {} })
  if opts.config then
    sim.files["inventory-config"] = "SIM_CONFIG"
    sim.dofileTables["inventory-config"] = opts.config
  end
  for path, content in pairs(opts.files or {}) do
    if type(content) == "table" then sim:setSerializedFile(path, content) else sim:setFile(path, content) end
  end
  if opts.approveRequest then sim:setSerializedFile(".atm10-approve-request", opts.approveRequest) end
  if opts.queue then sim:setSerializedFile(".atm10-craft-queue", opts.queue) end
  if opts.ledger then sim:setSerializedFile(".atm10-stock-ledger", opts.ledger) end
  return sim
end

return M
