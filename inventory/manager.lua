local TITLE = "ATM10 INVENTORY MANAGER"
local MONITOR_SIDE = "auto"
local BRIDGE_NAME = "auto"
local TEXT_SCALE = "auto"
local REFRESH_SECONDS = 5
local TOP_ITEM_COUNT = 8
local BROADCAST_ENABLED = true
local BROADCAST_MODEM_SIDE = "auto"
local BROADCAST_PROTOCOL = "atm10-inventory-v1"
local CONFIG_FILE = "inventory-config"
local LEDGER_FILE = ".atm10-stock-ledger"
local QUEUE_FILE = ".atm10-craft-queue"
local MANAGED_FILE = ".atm10-managed" -- operator-set quotas (tap-to-manage store)
local EDIT_STEPS = { 1, 10, 100, 1000, 10000 } -- cycleable +/- step sizes in the quota editor
local PAGE_SECONDS = 10
local PAGES = { "PLAN", "QUEUE", "BROWSE", "PRESETS" }
local QUEUE_MAX_AGE_MS = 30 * 60 * 1000 -- prune approvals older than 30 minutes
local PAGE_BUTTON_SIDE = "back"          -- a redstone pulse here flips to the next page ("none" disables)
local BROWSE_CRAFT_AMOUNT = 64           -- default quantity when approving a craft from the Browse page

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")
local stockplan = require("atm10-stockplan")
local cqueue = require("atm10-queue")
local craftrunner = require("atm10-craftrunner")
local managed = require("atm10-managed")
local balance = require("atm10-balance")
local presets = require("atm10-presets")
local console = require("atm10-console")

local DEFAULT_CONFIG = {
  mode = "manual",          -- manual: plan + require operator approval before a craft fires
  allowAutocraft = true,    -- autocraft capability on by default (still gated by mode + approval)
  itemDefaults = {
    handling = "unmanaged",
  },
  listedItems = {},
  lowStock = {
    { label = "Glass", name = "minecraft:glass", target = 512 },
    { label = "Redstone", name = "minecraft:redstone", target = 1024 },
    { label = "Iron Ingots", name = "minecraft:iron_ingot", target = 512 },
    { label = "Quartz", name = "minecraft:quartz", target = 256 },
  },
  stockKeeper = {
    enabled = false,
    cooldownSeconds = 300,
    maxCraftsPerCycle = 2,
    maxRequest = 4096,
    items = {},
    categories = {},
  },
}

local monitor = nil
local bridge = nil
local bridgeName = nil
local status = "Starting"
local broadcastReady = false
local config = DEFAULT_CONFIG
local configError = nil
local ledgerError = nil
local paletteApplied = false
local pageIndex = 1
local pageShownAt = nil
local craftQueue = nil
local managedStore = nil
local lastData = nil
local tabStrip = nil
local planRowRegions = {}
local queueRowRegions = {}
local browseRowRegions = {}
local browseNavRegions = {}
local presetRowRegions = {}
local presetStatus = nil   -- short confirmation line after applying a preset
local browsePage = 1
local editing = nil       -- when set, the Browse page shows the quota editor for this item
local editorRows = {}     -- button rows in the editor, for touch hit-testing
local rsLevels = {}

local function peripheralTypeMatches(actual, expected)
  if actual == expected then return true end
  if type(actual) == "table" then
    for _, name in ipairs(actual) do
      if name == expected then return true end
    end
  end
  return false
end

local function findPeripheral(types, preferred)
  if preferred and preferred ~= "auto" then
    local p = peripheral.wrap(preferred)
    if p then return p, preferred end
  end

  for _, name in ipairs(peripheral.getNames()) do
    local actual = peripheral.getType(name)
    for _, expected in ipairs(types) do
      if peripheralTypeMatches(actual, expected) then
        return peripheral.wrap(name), name
      end
    end
  end

  return nil, nil
end

local function call(target, method, ...)
  if target and target[method] then
    local ok, result, extra = pcall(target[method], ...)
    if ok then return result, extra end
  end
  return nil
end

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function shallowCopyList(list)
  local copy = {}
  if type(list) ~= "table" then return copy end
  for i, item in ipairs(list) do copy[i] = item end
  return copy
end

local function noteConfigError(message)
  if configError then
    configError = configError .. "; " .. message
  else
    configError = message
  end
end

local function normalizeConfig(raw)
  local cfg = type(raw) == "table" and raw or {}

  -- Control mode gates execution: monitor/dry-run never craft; manual requires
  -- operator approval; auto crafts approved deficits unattended. Unknown values
  -- fall back to manual (the shipped default).
  local requestedMode = cfg.mode
  cfg.mode = control.normalizeMode(cfg.mode, control.MODE_MANUAL)
  if requestedMode ~= nil and requestedMode ~= cfg.mode then
    noteConfigError("Unknown mode '" .. tostring(requestedMode) .. "'; using " .. cfg.mode)
  end

  -- Autocraft capability flag. Default on; only an explicit false disables it.
  cfg.allowAutocraft = cfg.allowAutocraft ~= false

  local hadItemDefaults = type(cfg.itemDefaults) == "table"
  if not hadItemDefaults then cfg.itemDefaults = {} end
  if hadItemDefaults and cfg.itemDefaults.handling ~= nil and cfg.itemDefaults.handling ~= "unmanaged" then
    noteConfigError("Default handling forced unmanaged")
  end
  cfg.itemDefaults.handling = "unmanaged"

  if type(cfg.listedItems) ~= "table" then cfg.listedItems = {} end

  if type(cfg.lowStock) ~= "table" then
    cfg.lowStock = shallowCopyList(DEFAULT_CONFIG.lowStock)
  end

  if type(cfg.stockKeeper) ~= "table" then cfg.stockKeeper = {} end
  if cfg.stockKeeper.enabled ~= true then cfg.stockKeeper.enabled = false end
  cfg.stockKeeper.cooldownSeconds = tonumber(cfg.stockKeeper.cooldownSeconds) or 300
  cfg.stockKeeper.maxCraftsPerCycle = tonumber(cfg.stockKeeper.maxCraftsPerCycle) or 2
  cfg.stockKeeper.maxRequest = tonumber(cfg.stockKeeper.maxRequest) or 4096
  if type(cfg.stockKeeper.items) ~= "table" then cfg.stockKeeper.items = {} end
  if type(cfg.stockKeeper.categories) ~= "table" then cfg.stockKeeper.categories = {} end

  if #cfg.stockKeeper.categories == 0 and #cfg.stockKeeper.items > 0 then
    cfg.stockKeeper.categories = {
      { label = "Stock Keeper", items = cfg.stockKeeper.items },
    }
  end

  return cfg
end

local function loadConfig()
  configError = nil

  if not fs.exists(CONFIG_FILE) then
    config = normalizeConfig(DEFAULT_CONFIG)
    return
  end

  local ok, loaded = pcall(dofile, CONFIG_FILE)
  if not ok then
    config = normalizeConfig(DEFAULT_CONFIG)
    configError = "Config error: " .. tostring(loaded)
    return
  end

  config = normalizeConfig(loaded)
end

local function readLedger()
  ledgerError = nil

  if not fs.exists(LEDGER_FILE) then
    return { requests = {} }
  end

  local file = fs.open(LEDGER_FILE, "r")
  if not file then
    ledgerError = "Ledger unreadable"
    return nil
  end

  local text = file.readAll()
  file.close()

  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" or type(data.requests) ~= "table" then
    ledgerError = "Ledger corrupt; stock keeper blocked"
    return nil
  end

  return data
end

local function writeLedger(data)
  -- Reserved for the future manual/auto craft path. Dry-run planning never writes.
  local tmp = LEDGER_FILE .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then return false, "Ledger tmp open failed" end
  file.write(textutils.serialize(data))
  file.close()

  if fs.exists(LEDGER_FILE) then fs.delete(LEDGER_FILE) end
  fs.move(tmp, LEDGER_FILE)
  return true
end

-- Load the approved-craft queue (fail-safe: any problem yields an empty queue).
local function loadQueue()
  if not fs.exists(QUEUE_FILE) then return cqueue.new() end
  local file = fs.open(QUEUE_FILE, "r")
  if not file then return cqueue.new() end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok then return cqueue.new() end
  return cqueue.normalize(data)
end

-- Load operator-set quotas (fail-safe: any problem yields an empty store).
local function loadManaged()
  if not fs.exists(MANAGED_FILE) then return managed.new() end
  local file = fs.open(MANAGED_FILE, "r")
  if not file then return managed.new() end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok then return managed.new() end
  return managed.normalize(data)
end

-- Persist the managed-quota store atomically (tmp + move), like the queue.
local function saveManaged(store)
  local tmp = MANAGED_FILE .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then return false end
  file.write(textutils.serialize(store))
  file.close()
  if fs.exists(MANAGED_FILE) then fs.delete(MANAGED_FILE) end
  fs.move(tmp, MANAGED_FILE)
  return true
end

-- Persist the craft queue atomically (tmp + move), like the ledger.
local function saveQueue(q)
  local tmp = QUEUE_FILE .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then return false end
  file.write(textutils.serialize(q))
  file.close()
  if fs.exists(QUEUE_FILE) then fs.delete(QUEUE_FILE) end
  fs.move(tmp, QUEUE_FILE)
  return true
end

local function openBroadcastModems()
  if not BROADCAST_ENABLED or broadcastReady then return end

  if BROADCAST_MODEM_SIDE ~= "auto" then
    if peripheralTypeMatches(peripheral.getType(BROADCAST_MODEM_SIDE), "modem") then
      rednet.open(BROADCAST_MODEM_SIDE)
      broadcastReady = true
    end
    return
  end

  for _, side in ipairs(rs.getSides()) do
    if peripheralTypeMatches(peripheral.getType(side), "modem") then
      rednet.open(side)
      broadcastReady = true
    end
  end
end

local function fmt(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1000000000000 then return string.format("%.2fT", n / 1000000000000) end
  if a >= 1000000000 then return string.format("%.2fG", n / 1000000000) end
  if a >= 1000000 then return string.format("%.2fM", n / 1000000) end
  if a >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function pickTextScale()
  if not monitor then return end
  if not paletteApplied then
    pcall(uiPalette.apply, monitor)
    paletteApplied = true
  end

  if type(TEXT_SCALE) == "number" then
    monitor.setTextScale(TEXT_SCALE)
    return
  end

  local scales = {4, 3, 2.5, 2, 1.5, 1, 0.5}
  for _, scale in ipairs(scales) do
    monitor.setTextScale(scale)
    local w, h = monitor.getSize()
    if w >= 42 and h >= 18 then return end
  end

  monitor.setTextScale(0.5)
end

local function line(y, text, color)
  uiDraw.line(monitor, y, text, color or colors.white, colors.black)
end

local function getItems()
  local items = call(bridge, "getItems", {})
  if type(items) == "table" then return items end

  items = call(bridge, "listItems")
  if type(items) == "table" then return items end

  return {}
end

local function itemAmount(item)
  return tonumber(item.amount or item.count or item.size) or 0
end

local function itemName(item)
  return item.displayName or item.display_name or item.name or "Unknown"
end

local function findStoredItem(items, registryName)
  local direct = call(bridge, "getItem", { name = registryName })
  if type(direct) == "table" then return direct end

  for _, item in pairs(items) do
    if item.name == registryName then return item end
  end

  return nil
end

local function buildManagedItemNames()
  local names = {}
  local stock = config.stockKeeper or {}
  local categories = stock.categories or {}

  if #categories == 0 and type(stock.items) == "table" then
    categories = { { label = "Stock Keeper", items = stock.items } }
  end

  for _, category in ipairs(categories) do
    for _, target in ipairs(category.items or {}) do
      if target.name then names[target.name] = true end
    end
  end

  -- tap-to-manage quotas count as managed too
  for _, e in ipairs(managed.list(managedStore or managed.new())) do
    if e.name then names[e.name] = true end
  end

  return names
end

local function countKeys(map)
  local count = 0
  for _ in pairs(map or {}) do count = count + 1 end
  return count
end

local function rjust(value, width)
  local text = tostring(value or "")
  width = math.max(0, tonumber(width) or 0)
  if #text >= width then return string.sub(text, 1, width) end
  return string.rep(" ", width - #text) .. text
end

local function planDelta(plan)
  if plan.action == "WOULD CRAFT" then
    local text = "+" .. fmt(plan.request)
    if plan.capped then text = text .. "*" end
    return text
  end

  if plan.action == "ON COOLDOWN" then
    return tostring(plan.secondsLeft or "?") .. "s"
  end

  return "-"
end

local function formatCategorySummary(summary, width)
  local text = tostring(summary.label or "?") ..
    ": +" .. fmt(summary.ok) ..
    " >" .. fmt(summary.would) ..
    " ~" .. fmt(summary.crafting) ..
    " ." .. fmt(summary.cooldown) ..
    " x" .. fmt(summary.noRecipe) ..
    " #" .. fmt(summary.blocked)

  return uiDraw.fit(text, width)
end

local function categorySummaryStatus(summary)
  if (summary.noRecipe or 0) > 0 then return uiStatus.NO_RECIPE end
  if (summary.blocked or 0) > 0 then return uiStatus.BLOCKED end
  if (summary.would or 0) > 0 then return uiStatus.WOULD end
  if (summary.crafting or 0) > 0 then return uiStatus.CRAFTING end
  if (summary.cooldown or 0) > 0 then return uiStatus.COOLDOWN end
  return uiStatus.OK
end

local function formatPlanRow(plan, width)
  local tag = uiStatus.tag(plan.action)
  local category = tostring(plan.category or "?")
  local label = tostring(plan.label or "?")
  local item = category .. ": " .. label
  local have = fmt(plan.amount)
  local target = fmt(plan.target)
  local delta = planDelta(plan)

  if width >= 72 then
    local itemWidth = math.max(18, width - 39)
    return uiDraw.fit(item, itemWidth) ..
      " " .. rjust(have, 8) ..
      " " .. rjust(target, 8) ..
      " " .. rjust(delta, 7) ..
      " " .. uiDraw.fit(tag, 12)
  end

  return uiDraw.fit(tag .. " " .. item .. " " .. delta .. " (" .. have .. "/" .. target .. ")", width)
end

local function isCraftable(registryName, item)
  if type(item) == "table" and item.isCraftable ~= nil then return item.isCraftable end

  local result = call(bridge, "isCraftable", { name = registryName })
  if result ~= nil then return result == true end

  result = call(bridge, "isItemCraftable", { name = registryName })
  return result == true
end

local function collectListedItems(items)
  local listed = {}
  for _, target in ipairs(config.listedItems or {}) do
    if target.name then
      local item = findStoredItem(items, target.name)
      listed[#listed + 1] = {
        label = target.label or target.name,
        name = target.name,
        amount = item and itemAmount(item) or 0,
        handling = "unmanaged",
        craftable = isCraftable(target.name, item),
      }
    end
  end
  return listed
end

local function isItemCrafting(registryName)
  local result = call(bridge, "isItemCrafting", { name = registryName })
  if result ~= nil then return result == true end

  result = call(bridge, "isCrafting", { name = registryName })
  if result ~= nil then return result == true end

  return false
end

local function summarizeCategories(plans)
  local byName = {}
  local ordered = {}

  for _, plan in ipairs(plans or {}) do
    local name = plan.category or "Stock Keeper"
    local summary = byName[name]
    if not summary then
      summary = {
        label = name,
        ok = 0,
        would = 0,
        crafting = 0,
        cooldown = 0,
        noRecipe = 0,
        blocked = 0,
        other = 0,
      }
      byName[name] = summary
      ordered[#ordered + 1] = summary
    end

    local normalized = uiStatus.normalize(plan.action)
    if normalized == uiStatus.OK then summary.ok = summary.ok + 1
    elseif normalized == uiStatus.WOULD then summary.would = summary.would + 1
    elseif normalized == uiStatus.CRAFTING then summary.crafting = summary.crafting + 1
    elseif normalized == uiStatus.COOLDOWN then summary.cooldown = summary.cooldown + 1
    elseif normalized == uiStatus.NO_RECIPE then summary.noRecipe = summary.noRecipe + 1
    elseif normalized == uiStatus.BLOCKED then summary.blocked = summary.blocked + 1
    else summary.other = summary.other + 1 end
  end

  return ordered
end

-- Merge the hand-edited config stock keeper with the operator-set tap-to-manage
-- quotas (a synthetic "Tapped" category). Returns nil when neither has anything
-- to plan, so a disabled keeper with no quotas plans nothing (and never touches
-- the ledger). Presence of any managed quota enables planning.
local function effectiveStockKeeper()
  local stock = config.stockKeeper or {}
  local managedCat = managed.toCategory(managedStore or managed.new())

  if not managedCat and stock.enabled ~= true then
    return nil
  end

  -- Config categories plan only when the keeper is explicitly enabled; managed
  -- quotas always plan. (So tapping one item never silently re-activates config
  -- categories the operator disabled.)
  local categories = {}
  if stock.enabled == true then
    for _, c in ipairs(stock.categories or {}) do categories[#categories + 1] = c end
    if #categories == 0 and type(stock.items) == "table" and #stock.items > 0 then
      categories[#categories + 1] = { label = "Stock Keeper", items = stock.items }
    end
  end
  if managedCat then categories[#categories + 1] = managedCat end

  return {
    enabled = true,
    cooldownSeconds = stock.cooldownSeconds,
    maxCraftsPerCycle = stock.maxCraftsPerCycle,
    maxRequest = stock.maxRequest,
    categories = categories,
  }
end

-- Overflow/compress plans: when a managed item exceeds its ceiling, craft the
-- denser "into" item to drain the surplus. Same row shape as the stock planner,
-- so they show + approve + craft through the existing path.
local function planOverflowActions(items)
  local overflow = managed.overflowItems(managedStore or managed.new())
  if #overflow == 0 then return {} end

  local stock = config.stockKeeper or {}
  return balance.plan({
    items = overflow,
    now = nowMs(),
    ledger = readLedger(),
    cooldownSeconds = stock.cooldownSeconds,
    maxRequest = stock.maxRequest,
    resolve = function(name)
      local item = findStoredItem(items, name)
      local amount = item and itemAmount(item) or 0
      return amount, isCraftable(name, item), isItemCrafting(name)
    end,
  })
end

local function planStockActions(items)
  local stock = effectiveStockKeeper()
  if not stock then
    return {}
  end

  -- readLedger() records ledgerError on corruption, so call it only when there
  -- is something to plan: an idle keeper must not surface a ledger error.
  local ledger = readLedger()

  return stockplan.plan({
    stockKeeper = stock,
    now = nowMs(),
    ledger = ledger,
    ledgerError = ledgerError,
    resolve = function(name)
      local item = findStoredItem(items, name)
      local amount = item and itemAmount(item) or 0
      return amount, isCraftable(name, item), isItemCrafting(name)
    end,
  })
end

-- The single craft chokepoint. Reached ONLY through control.execute (every
-- safety gate has passed) via the craft runner. Drives the RS Bridge and
-- returns true iff the bridge accepted the craft request.
local function requestCraft(name, count)
  if not bridge then return false, "no bridge" end
  count = tonumber(count) or 0
  if not name or count <= 0 then return false, "nothing to craft" end

  local result = call(bridge, "craftItem", { name = name, count = count })
  -- Advanced Peripherals' craftItem returns a boolean on most builds (a table on
  -- some). call() returns nil if the method is missing or pcall errored. Treat an
  -- explicit false / nil as rejected. EXACT return shape to confirm in-game.
  if result == nil or result == false then return false, "bridge rejected craft" end
  if type(result) == "table" and result.success == false then
    return false, tostring(result.error or "bridge rejected craft")
  end
  return true
end

-- Persist a craft request into the ledger so the planner's cooldown engages and
-- a reboot does not immediately re-request the same item.
local function recordCraftRequest(name, amount, now)
  local ledger = readLedger() or { requests = {} }
  if type(ledger.requests) ~= "table" then ledger.requests = {} end
  ledger.requests[name] = { requestedAt = now, request = tonumber(amount) or 0 }
  writeLedger(ledger)
end

-- Execution policy derived from config: the global mode + capability flags that
-- gate every real action. Local touch approval lives in the craft queue.
local function buildPolicy()
  return control.policy({
    mode = config.mode,
    allowAutocraft = config.allowAutocraft == true,
  })
end

-- Run the approved craft queue through the gated runner. The runner performs at
-- most one bridge request per approval; nothing crafts unless mode + capability
-- + approval all pass. Returns nothing; prints a short line per request/failure.
local function processCraftQueue(now)
  if not craftQueue then return end
  local stock = config.stockKeeper or {}
  local summary = craftrunner.run(craftQueue, {
    policy = buildPolicy(),
    mode = config.mode,
    now = now,
    cooldownMs = (tonumber(stock.cooldownSeconds) or 300) * 1000,
    isCrafting = function(name) return isItemCrafting(name) end,
    craft = function(name, amount) return requestCraft(name, amount) end,
    recordRequest = recordCraftRequest,
  })
  if summary.changed then saveQueue(craftQueue) end
  for _, r in ipairs(summary.requested) do
    print("Craft requested: " .. tostring(r.name) .. " x" .. tostring(r.amount))
  end
  for _, f in ipairs(summary.failed) do
    print("Craft failed (" .. tostring(f.reason) .. "): " .. tostring(f.name))
  end
end

local function scan()
  loadConfig()

  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale() end
  end

  if not bridge then
    bridge, bridgeName = findPeripheral({ "rs_bridge", "rsBridge" }, BRIDGE_NAME)
  end

  if not bridge then
    status = "No RS Bridge found"
    return nil
  end

  local connected = call(bridge, "isConnected")
  local online = call(bridge, "isOnline")

  local items = getItems()
  local unique = 0
  local totalAmount = 0
  local craftableCount = 0
  local sorted = {}

  for _, item in pairs(items) do
    local amount = itemAmount(item)
    unique = unique + 1
    totalAmount = totalAmount + amount
    if item.isCraftable then craftableCount = craftableCount + 1 end
    sorted[#sorted + 1] = item
  end

  table.sort(sorted, function(a, b) return itemAmount(a) > itemAmount(b) end)

  local warnings = {}
  for _, target in ipairs(config.lowStock or {}) do
    local item = findStoredItem(items, target.name)
    local amount = item and itemAmount(item) or 0
    if amount < target.target then
      warnings[#warnings + 1] = {
        label = target.label,
        amount = amount,
        target = target.target,
        craftable = isCraftable(target.name, item),
      }
    end
  end

  if not managedStore then managedStore = loadManaged() end
  local managedNames = buildManagedItemNames()
  local listedItems = collectListedItems(items)
  local stockPlans = planStockActions(items)
  -- append overflow/compress plans so they render + approve like refill rows
  for _, r in ipairs(planOverflowActions(items)) do stockPlans[#stockPlans + 1] = r end
  local stockTally = uiStatus.tally(stockPlans)

  -- keep the in-memory queue tidy: drop now-satisfied items, age out stale ones
  if not craftQueue then craftQueue = loadQueue() end
  local satisfied = {}
  for _, p in ipairs(stockPlans) do
    if p.action == "OK" and p.name then satisfied[p.name] = true end
  end
  local beforeCount = cqueue.count(craftQueue)
  cqueue.reconcile(craftQueue, satisfied)
  cqueue.prune(craftQueue, nowMs(), QUEUE_MAX_AGE_MS)
  if cqueue.count(craftQueue) ~= beforeCount then saveQueue(craftQueue) end

  return {
    connected = connected,
    online = online,
    items = sorted,
    unique = unique,
    totalAmount = totalAmount,
    craftableCount = craftableCount,
    defaultHandling = config.itemDefaults.handling,
    managedItemCount = countKeys(managedNames),
    listedItemCount = #listedItems,
    unmanagedItemCount = math.max(0, unique - countKeys(managedNames)),
    listedItems = listedItems,
    warnings = warnings,
    usedItemStorage = call(bridge, "getUsedItemStorage"),
    totalItemStorage = call(bridge, "getTotalItemStorage") or call(bridge, "getMaxItemDiskStorage"),
    availableItemStorage = call(bridge, "getAvailableItemStorage"),
    storedEnergy = call(bridge, "getStoredEnergy") or call(bridge, "getEnergyStorage"),
    energyCapacity = call(bridge, "getEnergyCapacity") or call(bridge, "getMaxEnergyStorage"),
    energyUsage = call(bridge, "getEnergyUsage"),
    configMode = config.mode or "dry-run",
    configError = configError,
    ledgerError = ledgerError,
    stockPlans = stockPlans,
    stockTally = stockTally,
    categorySummaries = summarizeCategories(stockPlans),
    craftQueue = cqueue.list(craftQueue),
  }
end

local function compactItems(items, limit)
  local compact = {}
  for i = 1, math.min(limit, #items) do
    local item = items[i]
    compact[#compact + 1] = {
      name = itemName(item),
      amount = itemAmount(item),
      id = item.name,
    }
  end
  return compact
end

local function broadcast(data)
  if not BROADCAST_ENABLED or not broadcastReady or not data then return end

  rednet.broadcast({
    kind = "inventory_snapshot",
    source = os.getComputerID(),
    bridgeName = bridgeName,
    online = data.online,
    connected = data.connected,
    unique = data.unique,
    totalAmount = data.totalAmount,
    craftableCount = data.craftableCount,
    defaultHandling = data.defaultHandling,
    managedItemCount = data.managedItemCount,
    listedItemCount = data.listedItemCount,
    unmanagedItemCount = data.unmanagedItemCount,
    listedItems = data.listedItems,
    warnings = data.warnings,
    topItems = compactItems(data.items, TOP_ITEM_COUNT),
    usedItemStorage = data.usedItemStorage,
    totalItemStorage = data.totalItemStorage,
    availableItemStorage = data.availableItemStorage,
    storedEnergy = data.storedEnergy,
    energyCapacity = data.energyCapacity,
    energyUsage = data.energyUsage,
    configMode = data.configMode,
    configError = data.configError,
    ledgerError = data.ledgerError,
    stockPlans = data.stockPlans,
    stockTally = data.stockTally,
    categorySummaries = data.categorySummaries,
  }, BROADCAST_PROTOCOL)
end

local function drawWaiting(message)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  line(1, TITLE, colors.cyan)
  line(3, message, colors.red)
  line(5, "Attach monitor + RS Bridge to this computer.", colors.gray)
end

-- The manager monitor is a management-only console. Inventory browsing lives on
-- the separate read-only viewers; here we show the stock Plan and the craft Queue.
local function drawPlanPage(data)
  local w, h = monitor.getSize()

  line(6, "Category Summary   + ok  > would  ~ craft  . wait  x recipe  # block", colors.cyan)
  local summaries = data.categorySummaries or {}
  local summaryRows = math.min(4, #summaries)
  for i = 1, summaryRows do
    line(6 + i, formatCategorySummary(summaries[i], w), uiStatus.color(categorySummaryStatus(summaries[i])))
  end

  local planLabelY = 6 + summaryRows + 2
  line(planLabelY, "Stock Keeper Plan [dry-run]", colors.cyan)
  local headerRows = 0
  if w >= 72 then
    line(planLabelY + 1, uiDraw.fit("ITEM", math.max(18, w - 39)) .. "     HAVE   TARGET    PLAN   STATUS", colors.gray)
    headerRows = 1
  end

  local planStart = planLabelY + 1 + headerRows
  local plans = data.stockPlans or {}
  local planRows = math.max(0, math.min(#plans, h - planStart - 1))
  for i = 1, planRows do
    local p = plans[i]
    local y = planStart + i - 1
    line(y, formatPlanRow(p, w), uiStatus.color(p.action))
    -- only WOULD CRAFT rows are tappable (tap = approve into the queue)
    if p.action == "WOULD CRAFT" and p.name then
      planRowRegions[#planRowRegions + 1] = { y = y, entry = p }
    end
  end

  local tally = data.stockTally or {}
  local tallyY = planStart + planRows
  if tallyY <= h then
    line(tallyY, "+ " .. fmt(tally.OK) ..
      "  > " .. fmt(tally.WOULD) ..
      "  ~ " .. fmt(tally.CRAFTING) ..
      "  . " .. fmt(tally.COOLDOWN) ..
      "  x " .. fmt(tally.NO_RECIPE) ..
      "  # " .. fmt(tally.BLOCKED) ..
      "   apply disabled", colors.gray)
  end
end

local function drawQueuePage(data)
  local w, h = monitor.getSize()
  local q = data.craftQueue or {}
  local policy = buildPolicy()

  line(6, "Craft Queue   " .. #q .. " approved   mode:" .. tostring(config.mode), colors.cyan)

  if #q == 0 then
    line(8, "No approved crafts yet.", colors.lime)
    line(9, "Tap a WOULD CRAFT row on the Plan page to approve one.", colors.gray)
    return
  end

  local wide = w >= 60
  if wide then
    line(7, uiDraw.fit("ITEM", math.max(16, w - 28)) .. "  REQUEST   GATE      AGE", colors.gray)
  end

  local start = wide and 8 or 7
  -- leave the last row for the cancel hint
  local rows = math.max(0, math.min(#q, h - start - 1))
  local now = nowMs()
  for i = 1, rows do
    local e = q[i]
    local ageS = math.max(0, math.floor((now - (e.approvedAt or now)) / 1000))
    -- In-flight and failed entries show their lifecycle state; entries still
    -- awaiting a request show the live safety-gate verdict (would it craft now?).
    local gateState
    if e.state == cqueue.CRAFTING then
      gateState = uiStatus.CRAFTING
    elseif e.error then
      gateState = uiStatus.BLOCKED -- bridge rejected; retries after backoff
    else
      local action = control.craftAction(e, { mode = config.mode, execute = requestCraft })
      gateState = control.executionState(action, policy)
    end
    local text
    if wide then
      text = uiDraw.fit(tostring(e.label or e.name), math.max(16, w - 28)) ..
        "  " .. rjust("+" .. fmt(e.request), 7) ..
        "  " .. uiDraw.fit(uiStatus.label(gateState), 8) ..
        "  " .. rjust(ageS .. "s", 4)
    else
      text = uiDraw.fit(tostring(e.label or e.name) .. " +" .. fmt(e.request) ..
        " " .. uiStatus.label(gateState), w)
    end
    local y = start + i - 1
    line(y, text, uiStatus.color(gateState))
    -- tap a queued row to cancel (remove) the approval
    if e.name then
      queueRowRegions[#queueRowRegions + 1] = { y = y, entry = e }
    end
  end

  local hintY = start + rows
  if hintY <= h then
    line(hintY, "Tap a row to cancel its approval.", colors.gray)
  end
end

-- Browse the live grid and tap any item to set/edit its stock quota (no
-- hand-typed registry IDs). Managed items show their target. Rows are paginated;
-- [< PREV] / [NEXT >] tap targets sit on the bottom line.
local function drawBrowsePage(data)
  local w, h = monitor.getSize()
  local items = data.items or {}
  local total = #items

  local listTop = 8
  local listBottom = h - 1 -- bottom line is the nav row
  local perPage = math.max(1, listBottom - listTop + 1)
  local pg = console.paginate(total, perPage, browsePage)
  browsePage = pg.page -- keep the clamped page

  if editing and editing.pickingInto then
    line(6, uiDraw.fit("Pick compress target for " .. tostring(editing.label) .. " - tap an item", w), colors.yellow)
  else
    line(6, "Browse Grid   " .. fmt(total) .. " items   page " .. pg.page .. "/" .. pg.pages, colors.cyan)
  end
  local wide = w >= 60
  if wide then
    line(7, uiDraw.fit("ITEM", math.max(16, w - 26)) .. "   STORED   QUOTA", colors.gray)
  end

  if total == 0 then
    line(listTop, "Grid is empty or unavailable.", colors.gray)
    return
  end

  local store = managedStore or managed.new()
  for i = pg.from, pg.to do
    local item = items[i]
    local y = listTop + (i - pg.from)
    local name = itemName(item)
    local amount = itemAmount(item)
    local craftable = item.isCraftable == true
    local quota = item.name and managed.get(store, item.name) or nil

    local tag, color
    if quota then tag, color = "Q " .. fmt(quota.target), colors.lime
    elseif craftable then tag, color = "craft", colors.white
    else tag, color = "-", colors.gray end

    local text
    if wide then
      text = uiDraw.fit(name, math.max(16, w - 26)) ..
        "   " .. rjust(fmt(amount), 6) ..
        "   " .. uiDraw.fit(tag, 8)
    else
      text = uiDraw.fit((quota and "Q " or (craftable and "* " or "  ")) .. name .. " " .. fmt(amount), w)
    end
    line(y, text, color)
    -- every named item is tappable: tap opens the quota editor
    if item.name then
      browseRowRegions[#browseRowRegions + 1] = {
        y = y,
        entry = { name = item.name, label = name, amount = amount, craftable = craftable },
      }
    end
  end

  local navY = h
  local prev, next = "[< PREV]", "[NEXT >]"
  uiDraw.write(monitor, 1, navY, prev, pg.page > 1 and colors.cyan or colors.gray, colors.black)
  uiDraw.write(monitor, 11, navY, next, pg.page < pg.pages and colors.cyan or colors.gray, colors.black)
  browseNavRegions = {
    { x1 = 1, x2 = #prev, y = navY, delta = -1 },
    { x1 = 11, x2 = 10 + #next, y = navY, delta = 1 },
  }
  if w >= 44 then
    uiDraw.write(monitor, 21, navY, "tap an item to set its quota", colors.gray, colors.black)
  end
end

-- Render a button row and keep it for hit-testing. specs: {{label,key}}.
local function renderButtonRow(specs, y)
  local row = console.buttonRow(specs, y, 1, 1)
  for _, b in ipairs(row.buttons) do
    uiDraw.write(monitor, b.x1, y, b.text, colors.cyan, colors.black)
  end
  editorRows[#editorRows + 1] = row
  return row
end

-- The next step size in the cycle (1 -> 10 -> ... -> 10000 -> 1).
local function nextStep(cur)
  for i, s in ipairs(EDIT_STEPS) do
    if s == cur then return EDIT_STEPS[(i % #EDIT_STEPS) + 1] end
  end
  return EDIT_STEPS[1]
end

-- A "[-] LABEL: value [+]" row that adjusts `field` by the current step size.
local function renderFieldRow(label, value, field, y)
  uiDraw.write(monitor, 1, y, "[-]", colors.cyan, colors.black)
  uiDraw.write(monitor, 5, y, label .. ": " .. fmt(value), colors.white, colors.black)
  uiDraw.write(monitor, 26, y, "[+]", colors.cyan, colors.black)
  editorRows[#editorRows + 1] = { y = y, buttons = {
    { key = field .. ":-", x1 = 1, x2 = 3 },
    { key = field .. ":+", x1 = 26, x2 = 28 },
  } }
end

-- The quota editor for the item in `editing` (opened from the Browse page).
-- Step size cycles so big late-game numbers (300k) are reachable.
local function drawEditor()
  local w = (monitor.getSize())
  editorRows = {}
  local e = editing
  local already = managed.has(managedStore or managed.new(), e.name)

  line(6, uiDraw.fit("Quota: " .. tostring(e.label), w), colors.cyan)
  line(7, "stored: " .. fmt(e.amount) .. "   craftable: " .. (e.craftable and "yes" or "NO"),
    e.craftable and colors.gray or colors.orange)

  uiDraw.write(monitor, 1, 8, "step: " .. fmt(e.step), colors.gray, colors.black)
  do
    local r = console.buttonRow({ { label = "STEP", key = "step" } }, 8, 14)
    for _, b in ipairs(r.buttons) do uiDraw.write(monitor, b.x1, 8, b.text, colors.cyan, colors.black) end
    editorRows[#editorRows + 1] = r
  end

  renderFieldRow("TARGET ", e.target, "target", 10)   -- floor: craft when below
  renderFieldRow("CRAFTTO", e.craftTo, "craftTo", 11) -- refill up to
  renderFieldRow("CEILING", e.ceiling, "ceiling", 12) -- cap: compress surplus above (0 = off)

  local intoLabel = e.into and tostring(e.into.label or e.into.name) or "none"
  line(13, "compress into: " .. intoLabel .. (e.into and ("  (x" .. e.ratio .. ")") or ""), colors.white)
  renderButtonRow({
    { label = "SET INTO", key = "setinto" },
    { label = "x-", key = "ratio:-" },
    { label = "x+", key = "ratio:+" },
    { label = "CLR OVF", key = "clrovf" },
  }, 14)

  local actions = { { label = "SAVE", key = "save" } }
  if already then actions[#actions + 1] = { label = "REMOVE", key = "remove" } end
  if e.craftable then actions[#actions + 1] = { label = "CRAFT", key = "craftnow" } end
  actions[#actions + 1] = { label = "BACK", key = "back" }
  renderButtonRow(actions, 16)

  if e.ceiling > 0 and not e.into then
    line(18, "Set 'compress into' or the ceiling just caps refills (no compress).", colors.orange)
  elseif not e.craftable then
    line(18, "Not craftable now: refill reads NOT CRAFTABLE until a recipe exists.", colors.orange)
  else
    line(18, "TARGET=floor (refill below).  CEILING=compress surplus above into the item.", colors.gray)
  end
end

-- Apply a stage preset's quotas in one tap. Quotas merge into the managed store.
local function drawPresetsPage(data)
  local w, h = monitor.getSize()
  local list = presets.list()

  line(6, "Quota Presets   tap one to apply its stock targets", colors.cyan)

  local start = 8
  local rows = math.min(#list, math.max(0, h - start - 2))
  for i = 1, rows do
    local p = list[i]
    local y = start + (i - 1)
    line(y, uiDraw.fit(p.label .. "  (" .. p.count .. " items)  - " .. p.description, w), colors.white)
    presetRowRegions[#presetRowRegions + 1] = { y = y, entry = p }
  end

  if presetStatus then
    line(start + rows + 1, uiDraw.fit(presetStatus, w), colors.lime)
  end
  line(h, "Applied quotas appear on Plan; approve them there (or use auto mode).", colors.gray)
end

local function draw(data)
  if not monitor then return end

  if not data then
    drawWaiting(status)
    return
  end

  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  planRowRegions = {} -- rebuilt each render for touch hit-testing
  queueRowRegions = {}
  browseRowRegions = {}
  browseNavRegions = {}
  presetRowRegions = {}
  editorRows = {}

  local pageName = PAGES[pageIndex]

  line(1, TITLE, colors.cyan)

  -- tappable tab strip (right-click a tab to switch pages)
  tabStrip = console.tabs(PAGES, 2)
  monitor.setCursorPos(1, 2)
  monitor.setBackgroundColor(colors.black)
  monitor.clearLine()
  for _, tab in ipairs(tabStrip.tabs) do
    uiDraw.write(monitor, tab.x1, tabStrip.y, "[" .. tab.label .. "]",
      tab.page == pageIndex and colors.cyan or colors.gray, colors.black)
  end

  local onlineText, onlineColor = "unknown", colors.yellow
  if data.online == true then onlineText, onlineColor = "ONLINE", colors.lime
  elseif data.online == false then onlineText, onlineColor = "OFFLINE", colors.red end
  line(3, "Grid: " .. onlineText .. "   Managed: " .. fmt(data.managedItemCount) ..
    "   Bridge: " .. tostring(bridgeName or "?"), onlineColor)

  if data.configError then
    line(4, data.configError, colors.orange)
  else
    local craftLive = (config.allowAutocraft == true)
      and (config.mode == control.MODE_MANUAL or config.mode == control.MODE_AUTO)
    line(4, "Mode: " .. tostring(data.configMode or "manual") ..
      "   autocraft: " .. (craftLive and "ON" or "off"), craftLive and colors.lime or colors.gray)
  end

  if pageName == "QUEUE" then
    drawQueuePage(data)
  elseif pageName == "BROWSE" then
    -- editing shows the editor, unless we're picking a compress target from the grid
    if editing and not editing.pickingInto then drawEditor() else drawBrowsePage(data) end
  elseif pageName == "PRESETS" then
    drawPresetsPage(data)
  else
    drawPlanPage(data)
  end
end

local function setPage(i)
  pageIndex = ((i - 1) % #PAGES) + 1
  editing = nil -- any page change exits the quota editor
  pageShownAt = nowMs() -- a manual page change resets the auto-rotate timer
end

-- Only the dashboard pages auto-rotate; Browse/Presets are interactive and held.
local AUTO_PAGES = { PLAN = true, QUEUE = true }

local function advancePageIfDue()
  local nowT = nowMs()
  if not pageShownAt then pageShownAt = nowT end
  if not AUTO_PAGES[PAGES[pageIndex]] then
    pageShownAt = nowT -- manual page: don't auto-rotate away
    return
  end
  if nowT - pageShownAt >= PAGE_SECONDS * 1000 then
    local nextIndex = pageIndex
    for _ = 1, #PAGES do
      nextIndex = nextIndex % #PAGES + 1
      if AUTO_PAGES[PAGES[nextIndex]] then break end
    end
    pageIndex = nextIndex
    pageShownAt = nowT
  end
end

local function renderCurrent()
  draw(lastData)
end

-- Approve a planned/selected craft into the queue. The gated craft runner issues
-- the actual request on a later cycle, and only if mode + capability + approval
-- all pass; approving here never crafts directly.
local function approve(entry)
  if not entry or not entry.name then return end
  craftQueue = cqueue.approve(craftQueue or loadQueue(),
    { name = entry.name, label = entry.label, request = entry.request }, nowMs())
  saveQueue(craftQueue)
  pageShownAt = nowMs()
  print("Approved: " .. tostring(entry.label or entry.name) .. " x" .. tostring(entry.request))
end

-- Cancel a queued approval. Removes intent only; the runner crafts at most once
-- per approval, so a canceled-but-already-requested item just stops being shown.
local function cancelEntry(entry)
  if not entry or not entry.name then return end
  craftQueue = cqueue.cancel(craftQueue or loadQueue(), entry.name)
  saveQueue(craftQueue)
  pageShownAt = nowMs()
  print("Canceled approval: " .. tostring(entry.label or entry.name))
end

-- Open the quota editor for a browsed item, seeding from an existing quota or
-- from sensible defaults (hold current stock, refill one batch above).
local function openEditor(entry)
  local existing = managed.get(managedStore or loadManaged(), entry.name)
  local target, craftTo, ceiling, into, ratio
  if existing then
    target, craftTo = existing.target, existing.craftTo
    ceiling, into, ratio = existing.ceiling or 0, existing.into, existing.ratio or 1
  else
    target = math.max(0, math.floor(entry.amount or 0))
    craftTo = target + BROWSE_CRAFT_AMOUNT
    ceiling, into, ratio = 0, nil, 1
  end
  editing = {
    name = entry.name, label = entry.label, amount = entry.amount or 0,
    craftable = entry.craftable == true,
    target = target, craftTo = craftTo, ceiling = ceiling, into = into, ratio = ratio,
    step = 100, pickingInto = false,
  }
  pageShownAt = nowMs()
end

local function saveEditing()
  local store = managedStore or loadManaged()
  local hasOverflow = editing.ceiling > 0 and editing.into ~= nil
  managed.set(store, {
    name = editing.name, label = editing.label,
    target = editing.target, craftTo = editing.craftTo,
    ceiling = hasOverflow and editing.ceiling or nil,
    into = hasOverflow and editing.into or nil,
    ratio = editing.ratio,
  }, nowMs())
  if not hasOverflow then managed.clearOverflow(store, editing.name) end
  managedStore = store
  saveManaged(managedStore)
  print("Quota saved: " .. tostring(editing.label) .. "  target " .. editing.target ..
    (hasOverflow and ("  compress>" .. editing.ceiling .. " -> " .. tostring(editing.into.label)) or ""))
  editing = nil
end

local function removeEditing()
  managedStore = managed.remove(managedStore or loadManaged(), editing.name)
  saveManaged(managedStore)
  print("Quota removed: " .. tostring(editing.label))
  editing = nil
end

-- Apply a stage preset: merge its quotas into the managed store and persist.
local function applyPreset(p)
  if not p or not p.id then return end
  managedStore = managedStore or loadManaged()
  local _, n = presets.apply(managedStore, p.id, nowMs())
  saveManaged(managedStore)
  presetStatus = "Applied " .. tostring(p.label) .. ": " .. n .. " quotas set."
  pageShownAt = nowMs()
  print("Applied preset " .. tostring(p.label) .. " (" .. n .. " quotas)")
end

-- Touch handling while the quota editor is open.
local function handleEditorTouch(x, y)
  -- tabs still navigate (and exit the editor)
  local page = console.tabHit(tabStrip, x, y)
  if page then setPage(page); renderCurrent(); return end

  for _, row in ipairs(editorRows) do
    local key = console.buttonHit(row, x, y)
    if key then
      if key == "save" then saveEditing()
      elseif key == "remove" then removeEditing()
      elseif key == "back" then editing = nil
      elseif key == "step" then editing.step = nextStep(editing.step)
      elseif key == "setinto" then editing.pickingInto = true
      elseif key == "clrovf" then editing.ceiling, editing.into = 0, nil
      elseif key == "ratio:-" then editing.ratio = math.max(1, editing.ratio - 1)
      elseif key == "ratio:+" then editing.ratio = editing.ratio + 1
      elseif key == "craftnow" then
        approve({ name = editing.name, label = editing.label, request = BROWSE_CRAFT_AMOUNT })
        editing = nil
      else
        local field, sign = string.match(key, "^(%a+):([-+])$")
        if field == "target" or field == "craftTo" or field == "ceiling" then
          local d = (sign == "-") and -editing.step or editing.step
          editing[field] = math.max(0, (editing[field] or 0) + d)
        end
      end
      pageShownAt = nowMs()
      renderCurrent()
      return
    end
  end
end

-- Touch handling while picking a compress-into target from the Browse grid.
local function handlePickIntoTouch(x, y)
  local page = console.tabHit(tabStrip, x, y)
  if page then setPage(page); renderCurrent(); return end -- tab cancels the whole edit

  for _, nav in ipairs(browseNavRegions) do
    if y == nav.y and x >= nav.x1 and x <= nav.x2 then
      browsePage = math.max(1, browsePage + nav.delta)
      pageShownAt = nowMs(); renderCurrent(); return
    end
  end

  local pick = console.rowHit(browseRowRegions, y)
  if pick then
    editing.into = { name = pick.name, label = pick.label }
    editing.pickingInto = false
    if editing.ceiling <= 0 then editing.ceiling = math.max(0, math.floor(editing.amount or 0)) end
    pageShownAt = nowMs()
    renderCurrent()
  end
end

local function handleTouch(x, y)
  if editing and editing.pickingInto then
    handlePickIntoTouch(x, y)
    return
  end
  if editing then
    handleEditorTouch(x, y)
    return
  end

  local page = console.tabHit(tabStrip, x, y)
  if page then
    setPage(page)
    renderCurrent()
    return
  end

  local planEntry = console.rowHit(planRowRegions, y)
  if planEntry then
    approve(planEntry)
    renderCurrent()
    return
  end

  local queueEntry = console.rowHit(queueRowRegions, y)
  if queueEntry then
    cancelEntry(queueEntry)
    renderCurrent()
    return
  end

  local presetEntry = console.rowHit(presetRowRegions, y)
  if presetEntry then
    applyPreset(presetEntry)
    renderCurrent()
    return
  end

  -- Browse page: [< PREV] / [NEXT >] paging, then tap a row to edit its quota
  for _, nav in ipairs(browseNavRegions) do
    if y == nav.y and x >= nav.x1 and x <= nav.x2 then
      browsePage = math.max(1, browsePage + nav.delta)
      pageShownAt = nowMs()
      renderCurrent()
      return
    end
  end

  local browseEntry = console.rowHit(browseRowRegions, y)
  if browseEntry then
    openEditor(browseEntry)
    renderCurrent()
  end
end

-- A rising edge on the configured side flips to the next page.
local function handleRedstone()
  if PAGE_BUTTON_SIDE == "none" then return end
  local level = rs.getInput(PAGE_BUTTON_SIDE)
  if level and not rsLevels[PAGE_BUTTON_SIDE] then
    setPage(pageIndex + 1)
    renderCurrent()
  end
  rsLevels[PAGE_BUTTON_SIDE] = level
end

local function ensurePeripherals()
  openBroadcastModems()
  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale() end
  end
end

local function refreshAndDraw()
  ensurePeripherals()
  if not monitor then
    print("No monitor found. Retrying...")
    return
  end

  local ok, data = pcall(scan)
  if ok then
    lastData = data
    -- drive the gated craft runner, then refresh the queue snapshot so the page
    -- reflects this cycle's state transitions (APPROVED -> CRAFTING) immediately
    processCraftQueue(nowMs())
    data.craftQueue = cqueue.list(craftQueue)
    broadcast(data)
  else
    lastData = nil
    status = tostring(data)
  end
  renderCurrent()
end

local refreshTimer = os.startTimer(0)

while true do
  local ev = { os.pullEvent() }
  local kind = ev[1]

  if kind == "timer" and ev[2] == refreshTimer then
    advancePageIfDue()
    refreshAndDraw()
    refreshTimer = os.startTimer(REFRESH_SECONDS)
  elseif kind == "monitor_touch" then
    handleTouch(ev[3], ev[4])
  elseif kind == "redstone" then
    handleRedstone()
  elseif kind == "monitor_resize" then
    if monitor then pickTextScale() end
    renderCurrent()
  end
end
