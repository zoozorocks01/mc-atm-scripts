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
local PAGE_SECONDS = 10
local PAGES = { "PLAN", "QUEUE" }

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")
local stockplan = require("atm10-stockplan")
local cqueue = require("atm10-queue")

local DEFAULT_CONFIG = {
  mode = "dry-run",
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

  if cfg.mode ~= "dry-run" then
    cfg.mode = "dry-run"
    noteConfigError("Mode forced to dry-run")
  end

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

local function planStockActions(items)
  local stock = config.stockKeeper or {}
  if stock.enabled ~= true then
    return {}
  end

  -- readLedger() records ledgerError on corruption, so call it only when the
  -- stock keeper is enabled: a disabled keeper must not surface a ledger error.
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

local function requestCraft(_plan)
  -- Single future craft chokepoint. There is intentionally no craftItem call in this build.
  error("Crafting is disabled in this dry-run build", 0)
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

  local managedNames = buildManagedItemNames()
  local listedItems = collectListedItems(items)
  local stockPlans = planStockActions(items)
  local stockTally = uiStatus.tally(stockPlans)

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
    craftQueue = cqueue.list(loadQueue()),
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
    line(planStart + i - 1, formatPlanRow(plans[i], w), uiStatus.color(plans[i].action))
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

  line(6, "Craft Queue   " .. #q .. " approved   [crafting disabled]", colors.cyan)

  if #q == 0 then
    line(8, "No approved crafts yet.", colors.lime)
    line(9, "Approving items from the Plan page comes in the next step.", colors.gray)
    return
  end

  local wide = w >= 60
  if wide then
    line(7, uiDraw.fit("ITEM", math.max(16, w - 28)) .. "  REQUEST   STATE     AGE", colors.gray)
  end

  local start = wide and 8 or 7
  local rows = math.max(0, math.min(#q, h - start))
  local now = nowMs()
  for i = 1, rows do
    local e = q[i]
    local ageS = math.max(0, math.floor((now - (e.approvedAt or now)) / 1000))
    local text
    if wide then
      text = uiDraw.fit(tostring(e.label or e.name), math.max(16, w - 28)) ..
        "  " .. rjust("+" .. fmt(e.request), 7) ..
        "  " .. uiDraw.fit(tostring(e.state or "?"), 8) ..
        "  " .. rjust(ageS .. "s", 4)
    else
      text = uiDraw.fit(tostring(e.label or e.name) .. " +" .. fmt(e.request) .. " " .. tostring(e.state), w)
    end
    line(start + i - 1, text, uiStatus.color(uiStatus.WOULD))
  end
end

local function draw(data, pageName, pageNumber)
  if not monitor then return end

  if not data then
    drawWaiting(status)
    return
  end

  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  -- shared header (both pages)
  line(1, TITLE, colors.cyan)
  line(2, "Page " .. tostring(pageNumber) .. "/" .. #PAGES .. ": " .. tostring(pageName) ..
    "   Bridge: " .. tostring(bridgeName or "?"), colors.gray)

  local onlineText, onlineColor = "unknown", colors.yellow
  if data.online == true then onlineText, onlineColor = "ONLINE", colors.lime
  elseif data.online == false then onlineText, onlineColor = "OFFLINE", colors.red end
  line(3, "Grid: " .. onlineText .. "   Managed: " .. fmt(data.managedItemCount), onlineColor)

  if data.configError then
    line(4, data.configError, colors.orange)
  else
    line(4, "Mode: " .. tostring(data.configMode or "dry-run") .. " (crafting disabled)", colors.gray)
  end

  if pageName == "QUEUE" then
    drawQueuePage(data)
  else
    drawPlanPage(data)
  end
end

while true do
  openBroadcastModems()

  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale() end
  end

  if monitor then
    local ok, data = pcall(scan)
    if ok then
      -- rotate through the console pages on a timer
      local nowT = nowMs()
      if not pageShownAt then pageShownAt = nowT end
      if nowT - pageShownAt >= PAGE_SECONDS * 1000 then
        pageIndex = pageIndex % #PAGES + 1
        pageShownAt = nowT
      end
      draw(data, PAGES[pageIndex], pageIndex)
      broadcast(data)
    else
      drawWaiting(tostring(data))
    end
  else
    print("No monitor found. Retrying...")
  end

  sleep(REFRESH_SECONDS)
end
