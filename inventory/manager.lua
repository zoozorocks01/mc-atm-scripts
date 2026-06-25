local TITLE = "ATM10 INVENTORY MANAGER"
local MONITOR_SIDE = "auto"
local BRIDGE_NAME = "auto"
local TEXT_SCALE = "auto"
local REFRESH_SECONDS = 5
-- Craftability/crafting are expensive RS Bridge calls; cache them across scans to
-- stay responsive on a laggy server. A NOT-craftable result expires fast (so a
-- newly-added pattern shows quickly); a craftable result is held longer.
local CRAFTABLE_TRUE_TTL_MS = 60000
local CRAFTABLE_FALSE_TTL_MS = 10000
local CRAFTING_TTL_MS = 6000
local TOP_ITEM_COUNT = 8
local BROADCAST_ENABLED = true
local BROADCAST_MODEM_SIDE = "auto"
local BROADCAST_PROTOCOL = "atm10-inventory-v1"
local CONFIG_FILE = "inventory-config"
local LEDGER_FILE = ".atm10-stock-ledger"
local QUEUE_FILE = ".atm10-craft-queue"
local MANAGED_FILE = ".atm10-managed" -- operator-set quotas (tap-to-manage store)
local TRENDS_FILE = ".atm10-trends" -- smart-mode consumption history (survives reboot)
local DISMISSED_FILE = ".atm10-dismissed" -- smart suggestions the operator cleared (survives reboot)
-- Cycleable +/- step sizes in the quota editor: by count AND by stacks (a stack
-- is 64), so big late-game numbers are quick to dial in. {value, label}.
local STACK = 64
local EDIT_STEPS = {
  { value = 1, label = "1" },
  { value = 10, label = "10" },
  { value = 100, label = "100" },
  { value = 1000, label = "1000" },
  { value = STACK, label = "1 stack" },
  { value = 10 * STACK, label = "10 stacks" },
  { value = 100 * STACK, label = "100 stacks" },
  { value = 1000 * STACK, label = "1000 stacks" },
}
local PAGE_SECONDS = 0 -- auto page-rotation seconds; 0 = off (the manager is interactive)
local PAGES = { "PLAN", "QUEUE", "BROWSE", "PRESETS", "SMART" }
-- short tab labels used when the full strip would overflow a narrow monitor
local PAGES_SHORT = { "PLAN", "QUE", "BRWS", "PRE", "SMRT" }
local MODE_CYCLE = { "monitor", "dry-run", "manual", "auto" } -- console mode-chip order
local QUEUE_MAX_AGE_MS = 30 * 60 * 1000 -- prune approvals older than 30 minutes
local PAGE_BUTTON_SIDE = "back"          -- a redstone pulse here flips to the next page ("none" disables)
local BROWSE_CRAFT_AMOUNT = 64           -- default quantity when approving a craft from the Browse page

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")
local stockplan = require("atm10-stockplan")
local control = require("atm10-control")
local cqueue = require("atm10-queue")
local craftrunner = require("atm10-craftrunner")
local managed = require("atm10-managed")
local balance = require("atm10-balance")
local suggest = require("atm10-suggest")
local presets = require("atm10-presets")
local console = require("atm10-console")

local DEFAULT_CONFIG = {
  mode = "manual",          -- manual: plan + require operator approval before a craft fires
  allowAutocraft = true,    -- autocraft capability on by default (still gated by mode + approval)
  refreshSeconds = 5,       -- bridge poll interval; raise it to cut RS-Bridge load if TPS is low
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
    maxCraftsPerCycle = 8,    -- new craft requests issued per cycle (late-game default)
    maxRequest = 65536,       -- cap per single craft request (bigger batches)
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
local firedTimes = {}      -- ms timestamps of crafts fired in the last 60s (throughput readout)
local craftQueue = nil
local managedStore = nil
local itemsByName = {}      -- name -> item, rebuilt each scan (avoids per-item bridge.getItem)
local craftableCache = {}   -- name -> { v = bool, at = ms } (TTL'd, see constants)
local craftingCache = {}    -- name -> { v = bool, at = ms }
local lastData = nil
local lastUnique = 0       -- last good unique-item count; guards transient empty bridge reads
local bridgeStats = nil    -- cached storage/energy snapshot (display-only, polled on a throttle)
local bridgeStatsAt = 0    -- last bridgeStats refresh (ms)
local STATS_INTERVAL_MS = 10000 -- refresh storage/energy stats at most every 10s (cuts RS-bridge calls)
local tabStrip = nil
local planRowRegions = {}
local planNavRegions = {}
local planActionRegion = nil -- [APPROVE ALL] bulk button on the Plan nav row
local planPage = 1
local modeChip = nil       -- hit region for the header mode-cycle chip
local modeConfirm = nil    -- mode awaiting a confirm tap (auto only)
local queueRowRegions = {}
local queueActionRegion = nil -- [CLEAR QUEUE] bulk button on the Queue page
local browseRowRegions = {}
local browseNavRegions = {}
local presetRowRegions = {}
local presetStatus = nil   -- short confirmation line after applying a preset
local flashMsg = nil       -- transient confirmation shown on the active page's hint line
local flashAt = 0          -- when flashMsg was set (ms)
local FLASH_MS = 4000      -- how long an approve/cancel confirmation stays up
local smartRowRegions = {} -- tappable suggestion rows on the Smart page
local smartButtons = nil   -- enable/disable + clear toggle row on the Smart page
local trendHistory = {}    -- consumption history for smart mode (persisted to disk)
local trendsLoaded = false -- lazily load the persisted history on first smart cycle
local lastTrendsSaveMs = 0 -- throttle trend persistence (history is large; don't save every cycle)
local TRENDS_SAVE_INTERVAL_MS = 120000 -- persist smart-mode history at most every 2 min
local TREND_MAX_AGE_MS = 43200000     -- drop trend entries not seen in 12h (item left the grid)
local TREND_MAX_WINDOW_MS = 21600000  -- restart a trend window after 6h so drain stays recent
-- Hard cap on persisted trend entries. CC computers have a ~1MB disk and atomicWrite
-- needs ~2x transiently (tmp + original), so the file must stay well under ~250KB. A
-- base has thousands of items but only a fraction move; 800 most-sampled is plenty for
-- suggestions and keeps the file ~150KB. (Bloat here caused an out-of-space lockup.)
local TREND_MAX_ENTRIES = 800
local dismissedSuggestions = {} -- names the operator cleared (persisted to disk)
local dismissedLoaded = false   -- lazily load persisted dismissals on first smart cycle
local browsePage = 1
local browseFilter = false  -- false = whole grid; true = managed (quota'd) items only
local browseFilterBtn = nil -- hit region for the Browse ALL/MANAGED toggle
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

  -- Bridge poll interval. The scan does a full getItems() over the whole network
  -- each tick it fires, so this is the manager's main per-tick server cost. Floor
  -- at 2s so it can't be set low enough to hammer a laggy server; raise it (10-15)
  -- to trade refresh latency for TPS.
  cfg.refreshSeconds = math.max(2, tonumber(cfg.refreshSeconds) or 5)

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
  -- floor at a positive value: cooldownSeconds = 0 is reachable (0 is truthy in
  -- Lua) and would collapse BOTH re-fire guards -- the planner's ON COOLDOWN check
  -- and the runner's failed-craft backoff -- letting auto mode re-fire an item
  -- every cycle. A non-positive/garbage value falls back to the safe default.
  local cd = tonumber(cfg.stockKeeper.cooldownSeconds)
  cfg.stockKeeper.cooldownSeconds = (cd and cd > 0) and cd or 300
  cfg.stockKeeper.maxCraftsPerCycle = tonumber(cfg.stockKeeper.maxCraftsPerCycle) or 8
  cfg.stockKeeper.maxRequest = tonumber(cfg.stockKeeper.maxRequest) or 65536
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

-- Atomically write content to path (tmp + move), fully guarded: a full disk, a
-- leftover .tmp from a prior crash, or any fs error returns false instead of
-- throwing up into the event loop (which would freeze the console). Clears a
-- stale .tmp first so a single failed write doesn't wedge every future save.
local function atomicWrite(path, content)
  local tmp = path .. ".tmp"
  if fs.exists(tmp) then pcall(fs.delete, tmp) end
  local file = fs.open(tmp, "w")
  if not file then return false end
  local wrote = pcall(function() file.write(content); file.close() end)
  if not wrote then pcall(fs.delete, tmp); return false end
  local moved = pcall(function()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
  end)
  -- on move failure leave the .tmp in place: if delete(path) already succeeded the
  -- tmp holds the only copy of the new data. The next atomicWrite clears stale tmp.
  return moved == true
end

local function writeLedger(data)
  return atomicWrite(LEDGER_FILE, textutils.serialize(data))
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

local function saveManaged(store)
  return atomicWrite(MANAGED_FILE, textutils.serialize(store))
end

local function saveQueue(q)
  return atomicWrite(QUEUE_FILE, textutils.serialize(q))
end

-- Smart-mode trend history is wall-clock based (os.epoch), so persisting it lets
-- the drain window survive a reboot instead of restarting from zero each boot.
-- Fail-safe: any problem yields an empty history (smart mode just relearns).
local function loadTrends()
  if not fs.exists(TRENDS_FILE) then return {} end
  local file = fs.open(TRENDS_FILE, "r")
  if not file then return {} end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function saveTrends(history)
  return atomicWrite(TRENDS_FILE, textutils.serialize(history or {}))
end

-- Dismissed smart suggestions persist too: now that the trend window survives a
-- reboot, suggestions would otherwise reappear after every restart. Fail-safe.
local function loadDismissed()
  if not fs.exists(DISMISSED_FILE) then return {} end
  local file = fs.open(DISMISSED_FILE, "r")
  if not file then return {} end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function saveDismissed(set)
  return atomicWrite(DISMISSED_FILE, textutils.serialize(set or {}))
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
  if a >= 1000000 then return (string.format("%.2fM", n / 1000000):gsub("%.00?M$", "M")) end
  if a >= 1000 then return (string.format("%.1fk", n / 1000):gsub("%.0k$", "k")) end
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
  -- itemsByName is built once per scan from getItems(); look up locally instead
  -- of a bridge.getItem round-trip per item. Falls back to a scan if the map is
  -- not built yet (e.g. first call before a scan completes).
  local mapped = itemsByName[registryName]
  if mapped ~= nil then return mapped end

  for _, item in pairs(items or {}) do
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
    if plan.adjusted then text = text .. "!" end
    if plan.banded and not plan.adjusted then text = text .. "~" end
    return text
  end

  if plan.action == "ON COOLDOWN" then
    return tostring(plan.secondsLeft or "?") .. "s"
  end

  if plan.action == "BLOCKED" and plan.reason then
    return "band!"
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
  if type(item) == "table" and item.isCraftable ~= nil then return item.isCraftable == true end

  local cached = craftableCache[registryName]
  if cached then
    local ttl = cached.v and CRAFTABLE_TRUE_TTL_MS or CRAFTABLE_FALSE_TTL_MS
    if (nowMs() - cached.at) < ttl then return cached.v end
  end

  local result = call(bridge, "isCraftable", { name = registryName })
  if result == nil then result = call(bridge, "isItemCraftable", { name = registryName }) end
  local v = result == true
  craftableCache[registryName] = { v = v, at = nowMs() }
  return v
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
  local cached = craftingCache[registryName]
  if cached and (nowMs() - cached.at) < CRAFTING_TTL_MS then return cached.v end

  local result = call(bridge, "isItemCrafting", { name = registryName })
  if result == nil then result = call(bridge, "isCrafting", { name = registryName }) end
  local v = result == true
  craftingCache[registryName] = { v = v, at = nowMs() }
  return v
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
    -- DISPLAY is uncapped: every deficit shows as WOULD CRAFT so the operator can
    -- approve any of them. The real rate-limit (maxCraftsPerCycle) is enforced in
    -- the craft runner per cycle, not on the plan display.
    maxCraftsPerCycle = math.huge,
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

-- The active control mode: an operator override set from the console (persisted
-- in the managed store so it survives reboot + isn't clobbered by loadConfig)
-- takes precedence over the config file. This is what the gate actually sees.
local function effectiveMode()
  local override = managed.getSetting(managedStore, "modeOverride")
  if override and control.normalizeMode(override) == override then return override end
  return config.mode or "manual"
end

-- Cycle the console mode chip: monitor -> dry-run -> manual -> auto -> monitor.
-- Advancing INTO auto (the only unattended-crafting mode) needs a confirm tap.
-- autoArmed: was the auto-confirm armed by the IMMEDIATELY preceding chip tap?
-- (handleTouch clears the arm on any other tap, so only consecutive chip taps
-- commit auto -- one stray tap can't sneak the unattended mode on.)
local function cycleMode(autoArmed)
  local cur = effectiveMode()
  local idx = 1
  for i, m in ipairs(MODE_CYCLE) do if m == cur then idx = i end end
  local nextMode = MODE_CYCLE[idx % #MODE_CYCLE + 1]
  if nextMode == control.MODE_AUTO and not autoArmed then
    modeConfirm = control.MODE_AUTO -- arm: require a consecutive second chip tap
    return
  end
  modeConfirm = nil
  managedStore = managedStore or loadManaged()
  managed.setSetting(managedStore, "modeOverride", nextMode)
  saveManaged(managedStore)
  pageShownAt = nowMs()
  print("Mode -> " .. nextMode)
end

-- Execution policy derived from the effective mode + capability flags that gate
-- every real action. Local touch approval lives in the craft queue.
local function buildPolicy()
  return control.policy({
    mode = effectiveMode(),
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
    mode = effectiveMode(),
    now = now,
    cooldownMs = (tonumber(stock.cooldownSeconds) or 300) * 1000,
    -- rate-limit ACTUAL bridge requests per cycle (the plan display is uncapped)
    maxPerCycle = tonumber(stock.maxCraftsPerCycle) or 2,
    isCrafting = function(name) return isItemCrafting(name) end,
    craft = function(name, amount) return requestCraft(name, amount) end,
    recordRequest = recordCraftRequest,
  })
  if summary.changed then saveQueue(craftQueue) end

  -- Keep the cooldown ALIVE for in-flight crafts: while RS still reports an item
  -- crafting, slide its ledger timestamp so a batch that outlives cooldownSeconds
  -- cannot be re-fired on a momentary isItemCrafting false-negative. The cooldown
  -- only starts counting down once RS actually stops crafting the item, so the
  -- ledger guard no longer expires mid-flight. Batched into one ledger write.
  local inflight = {}
  for _, e in ipairs(cqueue.list(craftQueue)) do
    if e.state == cqueue.CRAFTING and isItemCrafting(e.name) then inflight[#inflight + 1] = e end
  end
  if #inflight > 0 then
    local ledger = readLedger() or { requests = {} }
    if type(ledger.requests) ~= "table" then ledger.requests = {} end
    for _, e in ipairs(inflight) do
      ledger.requests[e.name] = { requestedAt = now, request = tonumber(e.request) or 0 }
    end
    writeLedger(ledger)
  end

  for _, r in ipairs(summary.requested) do
    firedTimes[#firedTimes + 1] = now
    print("Craft requested: " .. tostring(r.name) .. " x" .. tostring(r.amount))
  end
  -- keep only the last 60s so #firedTimes == crafts/min (bounds the list too)
  local keptFired = {}
  for _, ts in ipairs(firedTimes) do if now - ts <= 60000 then keptFired[#keptFired + 1] = ts end end
  firedTimes = keptFired
  for _, f in ipairs(summary.failed) do
    print("Craft failed (" .. tostring(f.reason) .. "): " .. tostring(f.name))
  end
end

-- AUTO MODE: maintain quotas hands-free. Auto-approve every craftable deficit
-- (a "WOULD CRAFT" plan row, refill OR overflow/compress) into the queue so the
-- gated runner fires it next -- no manual taps. Other modes are unchanged: they
-- still require a tap on the Plan page to approve.
--
-- Re-approving an item that is already queued is intentional and safe:
--   * The ledger COOLDOWN (cooldownSeconds, floored > 0 in normalizeConfig) keeps
--     the planner from reporting an item as WOULD CRAFT again until the window
--     elapses; processCraftQueue SLIDES that timestamp while RS reports the item
--     still crafting, so a long batch (one that outlives cooldownSeconds) can't be
--     re-fired on a momentary isItemCrafting false-negative -- the window only
--     starts counting once RS actually stops crafting it.
--   * An item RS is actively crafting reports ALREADY CRAFTING (not WOULD CRAFT)
--     and is skipped here; the runner also re-checks isCrafting before firing.
--   * maxCraftsPerCycle still caps the ACTUAL bridge requests issued per cycle, so
--     a large backlog drains a few per cycle instead of flooding a laggy server.
local function autoApprovePlans(plans)
  if effectiveMode() ~= control.MODE_AUTO then return end
  if type(plans) ~= "table" then return end
  craftQueue = craftQueue or loadQueue()
  local _, n = cqueue.autoApprove(craftQueue, plans, nowMs())
  if n > 0 then saveQueue(craftQueue) end
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

  -- Distrust a transient empty/offline read: getItems() returns {} on any bridge
  -- error or laggy/partial tick. If we HAD items last cycle (or the grid reports
  -- offline), treat this as stale and hold the last plan rather than manufacturing
  -- a full set of phantom deficits (which in auto mode could re-fire bulk crafts).
  if (next(items) == nil and lastUnique > 0) or online == false or connected == false then
    status = (online == false or connected == false)
      and "Grid OFFLINE - holding last plan"
      or "Grid read failed - holding last plan"
    return nil, "stale"
  end

  local unique = 0
  local totalAmount = 0
  local craftableCount = 0
  local sorted = {}

  itemsByName = {} -- rebuilt each scan so findStoredItem is a local lookup
  for _, item in pairs(items) do
    local amount = itemAmount(item)
    unique = unique + 1
    totalAmount = totalAmount + amount
    if item.isCraftable then craftableCount = craftableCount + 1 end
    if item.name then itemsByName[item.name] = item end
    sorted[#sorted + 1] = item
  end
  lastUnique = unique -- remember a good read so the next empty read is caught as stale

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

  -- smart mode (opt-in): record consumption trends and compute quota suggestions
  local smartOn = managed.getSetting(managedStore, "smartMode") == true
  local suggestions = {}
  if smartOn then
    -- lazily restore the persisted drain window the first time smart mode runs, so
    -- a reboot continues learning instead of starting from zero
    if not trendsLoaded then
      trendHistory = loadTrends()
      trendsLoaded = true
    end
    if not dismissedLoaded then
      dismissedSuggestions = loadDismissed()
      dismissedLoaded = true
    end
    -- track drain for ALL items, not just craftable ones: with the live grid
    -- reporting craftable=0, gating on isCraftable would learn nothing.
    local snapshot = {}
    for _, item in ipairs(sorted) do
      if item.name then
        snapshot[#snapshot + 1] = { name = item.name, label = itemName(item), amount = itemAmount(item) }
      end
    end
    local now = nowMs()
    suggest.record(trendHistory, snapshot, now)
    -- persist on a throttle: the history spans thousands of items, so writing it
    -- every 5s cycle would thrash the disk; every couple minutes is plenty
    if now - lastTrendsSaveMs >= TRENDS_SAVE_INTERVAL_MS then
      -- bound the file + keep windows recent before persisting (see suggest.prune)
      suggest.prune(trendHistory, now, {
        maxAgeMs = TREND_MAX_AGE_MS, maxWindowMs = TREND_MAX_WINDOW_MS, maxEntries = TREND_MAX_ENTRIES,
      })
      saveTrends(trendHistory)
      lastTrendsSaveMs = now
    end
    local quotasMap = {}
    for _, e in ipairs(managed.list(managedStore)) do
      quotasMap[e.name] = { target = e.target, craftTo = e.craftTo }
    end
    suggestions = suggest.analyze(trendHistory,
      { managed = managedNames, quotas = quotasMap, dismissed = dismissedSuggestions, max = 8 })
  end
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

  -- Bridge storage/energy stats are display-only and change slowly. Polling them
  -- every cycle is 6 extra RS-bridge calls; throttle to STATS_INTERVAL_MS to cut the
  -- bridge-call load (each call is a chance to hit the AP NotAttachedException that
  -- crashed the server). Reuse the cached snapshot between refreshes.
  local statNow = nowMs()
  if not bridgeStats or (statNow - bridgeStatsAt) >= STATS_INTERVAL_MS then
    bridgeStats = {
      usedItemStorage = call(bridge, "getUsedItemStorage"),
      totalItemStorage = call(bridge, "getTotalItemStorage") or call(bridge, "getMaxItemDiskStorage"),
      availableItemStorage = call(bridge, "getAvailableItemStorage"),
      storedEnergy = call(bridge, "getStoredEnergy") or call(bridge, "getEnergyStorage"),
      energyCapacity = call(bridge, "getEnergyCapacity") or call(bridge, "getMaxEnergyStorage"),
      energyUsage = call(bridge, "getEnergyUsage"),
    }
    bridgeStatsAt = statNow
  end

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
    usedItemStorage = bridgeStats.usedItemStorage,
    totalItemStorage = bridgeStats.totalItemStorage,
    availableItemStorage = bridgeStats.availableItemStorage,
    storedEnergy = bridgeStats.storedEnergy,
    energyCapacity = bridgeStats.energyCapacity,
    energyUsage = bridgeStats.energyUsage,
    configMode = effectiveMode(),
    configError = configError,
    ledgerError = ledgerError,
    stockPlans = stockPlans,
    stockTally = stockTally,
    categorySummaries = summarizeCategories(stockPlans),
    craftQueue = cqueue.list(craftQueue),
    smartMode = smartOn,
    suggestions = suggestions,
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
    craftQueue = data.craftQueue,
  }, BROADCAST_PROTOCOL)
end

local function drawWaiting(message)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  line(1, TITLE, colors.cyan)
  line(3, message, colors.red)
  line(5, "Attach monitor + RS Bridge to this computer.", colors.gray)
end

-- The manager monitor is the control console (Plan / Queue / Browse / Presets /
-- Smart). The Browse tab here is for picking items to manage; the separate
-- inventory-remote computers are the read-only viewers. This is the Plan page.
local function drawPlanPage(data)
  local w, h = monitor.getSize()

  line(6, "Category Summary   + ok  > would  ~ craft  . wait  x recipe  # block", colors.cyan)
  local summaries = data.categorySummaries or {}
  local summaryRows = math.min(4, #summaries)
  for i = 1, summaryRows do
    line(6 + i, formatCategorySummary(summaries[i], w), uiStatus.color(categorySummaryStatus(summaries[i])))
  end

  -- Order: WOULD CRAFT (approvable) first, then most-severe problems, OK last,
  -- so the actionable rows are always on the first page(s).
  local plans = {}
  for _, p in ipairs(data.stockPlans or {}) do plans[#plans + 1] = p end
  local function planKey(p)
    if p.action == "WOULD CRAFT" then return 0 end
    return 100 - uiStatus.severity(p.action)
  end
  table.sort(plans, function(a, b)
    local ka, kb = planKey(a), planKey(b)
    if ka ~= kb then return ka < kb end
    if a.action == "WOULD CRAFT" and b.action == "WOULD CRAFT" then
      local pa, pb = tonumber(a.priority) or 0, tonumber(b.priority) or 0
      if pa ~= pb then return pa > pb end
    end
    return tostring(a.label) < tostring(b.label)
  end)

  local planLabelY = 6 + summaryRows + 2
  local headerRows = (w >= 72) and 1 or 0
  local planStart = planLabelY + 1 + headerRows
  -- reserve the bottom two lines for the nav+tally row and the hint
  local navY = h - 1
  local perPage = math.max(1, navY - planStart)
  local pg = console.paginate(#plans, perPage, planPage)
  planPage = pg.page

  line(planLabelY, "Stock Keeper Plan [" .. tostring(effectiveMode()) ..
    "]   page " .. pg.page .. "/" .. pg.pages, colors.cyan)
  if w >= 72 then
    line(planLabelY + 1, uiDraw.fit("ITEM", math.max(18, w - 39)) .. "     HAVE   TARGET    PLAN   STATUS", colors.gray)
  end

  for i = pg.from, pg.to do
    local p = plans[i]
    local y = planStart + (i - pg.from)
    line(y, formatPlanRow(p, w), uiStatus.color(p.action))
    -- only WOULD CRAFT rows are tappable (tap = approve into the queue)
    if p.action == "WOULD CRAFT" and p.name then
      planRowRegions[#planRowRegions + 1] = { y = y, entry = p }
    end
  end

  -- nav row (paging) + a compact tally on the same line
  local prev, next = "[< PREV]", "[NEXT >]"
  uiDraw.write(monitor, 1, navY, prev, pg.page > 1 and colors.cyan or colors.gray, colors.black)
  uiDraw.write(monitor, 11, navY, next, pg.page < pg.pages and colors.cyan or colors.gray, colors.black)
  planNavRegions = {
    { x1 = 1, x2 = #prev, y = navY, delta = -1 },
    { x1 = 11, x2 = 10 + #next, y = navY, delta = 1 },
  }
  local tally = data.stockTally or {}
  if w >= 40 then
    uiDraw.write(monitor, 21, navY, "+" .. fmt(tally.OK) .. " >" .. fmt(tally.WOULD) ..
      " ~" .. fmt(tally.CRAFTING) .. " x" .. fmt(tally.NO_RECIPE) .. " #" .. fmt(tally.BLOCKED), colors.gray)
  end

  -- footer hint: a recent action flashes a confirmation here, else the tap hint
  local flashing = flashMsg and (nowMs() - flashAt < FLASH_MS)
  if (tally.WOULD or 0) > 0 then
    line(h, flashing and flashMsg or "Tap a > WOULD row to approve.", flashing and colors.white or colors.lime)
    -- bulk: one tap approves EVERY WOULD CRAFT row (all pages), right-aligned so
    -- it never collides with the hint text
    local label = "[APPROVE ALL]"
    local bx = w - #label + 1
    if bx > 30 then
      uiDraw.write(monitor, bx, h, label, colors.lime, colors.black)
      planActionRegion = { x1 = bx, x2 = w, y = h }
    end
  else
    line(h, "Nothing craftable yet - RS reports no patterns (set up Crafters).", colors.gray)
  end
end

local function drawQueuePage(data)
  local w, h = monitor.getSize()
  local q = data.craftQueue or {}
  local policy = buildPolicy()

  local crafting = 0
  for _, e in ipairs(q) do if e.state == cqueue.CRAFTING then crafting = crafting + 1 end end
  line(6, "Craft Queue   " .. #q .. " approved   " .. crafting .. " crafting   ~" .. #firedTimes ..
    "/min   mode:" .. tostring(effectiveMode()), colors.cyan)

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
    -- show how long a job has been CRAFTING (craftingAt), else how long it's waited
    local ageBase = (e.state == cqueue.CRAFTING and e.craftingAt) or e.approvedAt or now
    local ageS = math.max(0, math.floor((now - ageBase) / 1000))
    -- In-flight and failed entries show their lifecycle state; entries still
    -- awaiting a request show the live safety-gate verdict (would it craft now?).
    local gateState
    if e.state == cqueue.CRAFTING then
      gateState = uiStatus.CRAFTING
    elseif e.error then
      gateState = uiStatus.BLOCKED -- bridge rejected; retries after backoff
    else
      local action = control.craftAction(e, { mode = effectiveMode(), execute = requestCraft })
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
    local flashing = flashMsg and (nowMs() - flashAt < FLASH_MS)
    line(hintY, flashing and flashMsg or "Tap a row to cancel its approval.", flashing and colors.white or colors.gray)
    -- bulk: one tap cancels every approval, right-aligned past the hint text
    local label = "[CLEAR QUEUE]"
    local bx = w - #label + 1
    if bx > 34 then
      uiDraw.write(monitor, bx, hintY, label, colors.orange, colors.black)
      queueActionRegion = { x1 = bx, x2 = w, y = hintY }
    end
  end
end

-- Browse the live grid and tap any item to set/edit its stock quota (no
-- hand-typed registry IDs). Managed items show their target. Rows are paginated;
-- [< PREV] / [NEXT >] tap targets sit on the bottom line.
local function drawBrowsePage(data)
  local w, h = monitor.getSize()
  local store = managedStore or managed.new()
  local items = data.items or {}

  -- managed-only filter: cut the ~5.9k-item haystack down to the items you tune
  if browseFilter then
    local filtered = {}
    for _, item in ipairs(items) do
      if item.name and managed.has(store, item.name) then filtered[#filtered + 1] = item end
    end
    items = filtered
  end
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
  -- ALL <-> MANAGED filter toggle (cuts the ~5.9k haystack to your quota'd items).
  -- Hidden while picking a compress target, where tapping it would be a dead no-op.
  if not (editing and editing.pickingInto) then
    local toggle = browseFilter and "[MANAGED]" or "[ALL]"
    uiDraw.write(monitor, 21, navY, toggle, colors.black, browseFilter and colors.lime or colors.cyan)
    browseFilterBtn = { x1 = 21, x2 = 20 + #toggle, y = navY }
    if w >= 52 then
      uiDraw.write(monitor, 21 + #toggle + 1, navY, "tap item to set quota", colors.gray, colors.black)
    end
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

-- The next step VALUE in the cycle (counts then stacks, then wraps).
local function nextStep(cur)
  for i, s in ipairs(EDIT_STEPS) do
    if s.value == cur then return EDIT_STEPS[(i % #EDIT_STEPS) + 1].value end
  end
  return EDIT_STEPS[1].value
end

-- Human label for the current step value (e.g. "100" or "10 stacks").
local function stepLabel(cur)
  for _, s in ipairs(EDIT_STEPS) do
    if s.value == cur then return s.label end
  end
  return tostring(cur)
end

-- A "[-] LABEL: value [+]" row that adjusts `field` by the current step size.
-- Shows the EXACT integer (not fmt-rounded) so a small step on a big number is
-- visible (e.g. +100 on 264000 must not display as unchanged "264.0k").
local function renderFieldRow(label, value, field, y)
  -- placed left-to-right with no hardcoded x: [-] LABEL: value [+]. The [+] sits
  -- right after the (exact-integer) value, so it never overlaps a big number.
  local text = label .. ": " .. tostring(math.floor(tonumber(value) or 0))
  uiDraw.write(monitor, 1, y, "[-]", colors.cyan, colors.black)
  uiDraw.write(monitor, 5, y, text, colors.white, colors.black)
  local plusX = 5 + #text + 1
  uiDraw.write(monitor, plusX, y, "[+]", colors.cyan, colors.black)
  editorRows[#editorRows + 1] = { y = y, buttons = {
    { key = field .. ":-", x1 = 1, x2 = 3 },
    { key = field .. ":+", x1 = plusX, x2 = plusX + 2 },
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

  uiDraw.write(monitor, 1, 8, "step: " .. stepLabel(e.step) ..
    (e.step >= STACK and ("  (" .. fmt(e.step) .. ")") or ""), colors.gray, colors.black)
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
    local tag = p.personal and "* " or ""
    line(y, uiDraw.fit(tag .. p.label .. "  (" .. p.count .. " items)  - " .. p.description, w),
      p.personal and colors.lime or colors.white)
    presetRowRegions[#presetRowRegions + 1] = { y = y, entry = p }
  end

  if presetStatus then
    line(start + rows + 1, uiDraw.fit(presetStatus, w), colors.lime)
  end
  line(h, "Applied quotas appear on Plan; approve them there (or use auto mode).", colors.gray)
end

-- Smart mode (opt-in): suggests recurring quotas from observed drain.
local function drawSmartPage(data)
  local w, h = monitor.getSize()
  local on = data.smartMode == true

  line(6, "Smart Mode: " .. (on and "ON" or "OFF") .. "   (suggests quotas from drain)",
    on and colors.lime or colors.gray)
  do
    local specs = { { label = on and "DISABLE" or "ENABLE", key = "smarttoggle" } }
    if on and #(data.suggestions or {}) > 0 then specs[#specs + 1] = { label = "CLEAR", key = "smartclear" } end
    local r = console.buttonRow(specs, 7, 1)
    for _, b in ipairs(r.buttons) do uiDraw.write(monitor, b.x1, 7, b.text, colors.cyan, colors.black) end
    smartButtons = r
  end

  if not on then
    line(9, "Off by default. Enable here, or apply the zoozo-late-game profile.", colors.gray)
    line(10, "When on, items that keep draining are suggested as recurring quotas.", colors.gray)
    return
  end

  local sugg = data.suggestions or {}
  if #sugg == 0 then
    line(9, "No suggestions yet - watching consumption...", colors.gray)
    line(10, "Items that decline over time will appear here to review + accept.", colors.gray)
    return
  end

  line(9, "Suggested quotas (tap to review + save):", colors.cyan)
  local start = 10
  local rows = math.min(#sugg, math.max(0, h - start - 1))
  local kindTag = { quota = "STOCK", raise = "RAISE", cap = "CAP" }
  for i = 1, rows do
    local s = sugg[i]
    local y = start + (i - 1)
    local detail = (s.kind == "cap")
      and ("cap " .. fmt(s.ceiling))
      or ("keep " .. fmt(s.target) .. "/" .. fmt(s.craftTo))
    line(y, uiDraw.fit("[" .. (kindTag[s.kind] or "?") .. "] " .. s.label .. " -> " .. detail ..
      "  (" .. tostring(s.reason) .. ")", w), colors.white)
    smartRowRegions[#smartRowRegions + 1] = { y = y, entry = s }
  end
  line(h, "Tapping opens the editor pre-filled; SAVE to apply.", colors.gray)
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
  planNavRegions = {}
  planActionRegion = nil
  modeChip = nil
  queueRowRegions = {}
  queueActionRegion = nil
  browseRowRegions = {}
  browseNavRegions = {}
  browseFilterBtn = nil
  presetRowRegions = {}
  smartRowRegions = {}
  smartButtons = nil
  editorRows = {}

  local pageName = PAGES[pageIndex]

  line(1, TITLE, colors.cyan)

  -- tappable tab strip (right-click a tab to switch pages). Use short labels when
  -- the full strip would run off this monitor, so SMART is never cut off/untappable.
  local tabW = select(1, monitor.getSize())
  tabStrip = console.tabs(PAGES, 2)
  if (tabStrip.tabs[#tabStrip.tabs] and tabStrip.tabs[#tabStrip.tabs].x2 or 0) > tabW then
    tabStrip = console.tabs(PAGES_SHORT, 2)
  end
  monitor.setCursorPos(1, 2)
  monitor.setBackgroundColor(colors.black)
  monitor.clearLine()
  -- active tab is highlighted (inverted) so "you are here" + tap targets are clear
  for _, tab in ipairs(tabStrip.tabs) do
    local active = tab.page == pageIndex
    uiDraw.write(monitor, tab.x1, tabStrip.y, "[" .. tab.label .. "]",
      active and colors.black or colors.lightGray, active and colors.cyan or colors.black)
  end

  local onlineText, onlineColor = "unknown", colors.yellow
  if data.online == true then onlineText, onlineColor = "ONLINE", colors.lime
  elseif data.online == false then onlineText, onlineColor = "OFFLINE", colors.red end
  -- a stale read holds the last plan; say so loudly (the grid line below is stale too)
  if data.stale then
    line(3, "! " .. tostring(data.stale), colors.red)
  else
    line(3, "Grid: " .. onlineText .. "   Managed: " .. fmt(data.managedItemCount) ..
      "   Bridge: " .. tostring(bridgeName or "?"), onlineColor)
  end

  if data.configError then
    line(4, data.configError, colors.orange)
  else
    local mode = effectiveMode()
    local craftLive = (config.allowAutocraft == true)
      and (mode == control.MODE_MANUAL or mode == control.MODE_AUTO)
    -- tappable mode chip: tap to cycle monitor->dry-run->manual->auto (auto needs a confirm tap)
    monitor.setCursorPos(1, 4)
    monitor.setBackgroundColor(colors.black)
    monitor.clearLine()
    local chip = "[" .. mode .. (modeConfirm == control.MODE_AUTO and " AUTO?" or "") .. "]"
    uiDraw.write(monitor, 1, 4, chip, colors.black,
      modeConfirm == control.MODE_AUTO and colors.orange or colors.cyan)
    modeChip = { x1 = 1, x2 = #chip, y = 4 }
    uiDraw.write(monitor, #chip + 2, 4, "autocraft: " .. (craftLive and "ON" or "off") ..
      "   Queue: " .. cqueue.count(craftQueue), craftLive and colors.lime or colors.gray)
  end

  -- the quota editor is a modal: it renders over any tab when open (unless we're
  -- picking a compress target, which needs the grid list)
  if editing and not editing.pickingInto then
    drawEditor()
  elseif editing and editing.pickingInto then
    drawBrowsePage(data)
  elseif pageName == "QUEUE" then
    drawQueuePage(data)
  elseif pageName == "BROWSE" then
    drawBrowsePage(data)
  elseif pageName == "PRESETS" then
    drawPresetsPage(data)
  elseif pageName == "SMART" then
    drawSmartPage(data)
  else
    drawPlanPage(data)
  end
end

local function setPage(i)
  pageIndex = ((i - 1) % #PAGES) + 1
  editing = nil -- any page change exits the quota editor
  modeConfirm = nil -- and cancels a pending auto-mode confirm
  pageShownAt = nowMs() -- a manual page change resets the auto-rotate timer
end

-- Only the dashboard pages auto-rotate; Browse/Presets are interactive and held.
local AUTO_PAGES = { PLAN = true, QUEUE = true }

local function advancePageIfDue()
  if PAGE_SECONDS <= 0 then return end -- auto-rotation disabled
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
    { name = entry.name, label = entry.label, request = entry.request, key = entry.key,
      priority = entry.priority, amount = entry.amount, target = entry.target, category = entry.category,
      craftTo = entry.craftTo, banded = entry.banded, adjusted = entry.adjusted, reason = entry.reason }, nowMs())
  saveQueue(craftQueue)
  pageShownAt = nowMs()
  flashMsg = "+ Approved " .. tostring(entry.label or entry.name); flashAt = nowMs()
  print("Approved: " .. tostring(entry.label or entry.name) .. " x" .. tostring(entry.request))
end

-- Cancel a queued approval. Removes intent only; the runner crafts at most once
-- per approval, so a canceled-but-already-requested item just stops being shown.
local function cancelEntry(entry)
  if not entry or not entry.name then return end
  craftQueue = cqueue.cancel(craftQueue or loadQueue(), entry.key or entry.name)
  saveQueue(craftQueue)
  pageShownAt = nowMs()
  flashMsg = "x Canceled " .. tostring(entry.label or entry.name); flashAt = nowMs()
  print("Canceled approval: " .. tostring(entry.label or entry.name))
end

-- Bulk approve: enqueue every WOULD CRAFT row in the current plan (all pages, not
-- just the visible slice) in one tap. Same per-item path as a manual tap.
local function approveAllPlans()
  if not lastData then return end
  local q = craftQueue or loadQueue()
  local n = 0
  for _, p in ipairs(lastData.stockPlans or {}) do
    if p.action == "WOULD CRAFT" and p.name and (tonumber(p.request) or 0) > 0 then
      q = cqueue.approve(q, p, nowMs())
      n = n + 1
    end
  end
  craftQueue = q
  saveQueue(craftQueue)
  pageShownAt = nowMs()
  flashMsg = "+ Approved all (" .. n .. ")"; flashAt = nowMs()
  print("Approved all WOULD CRAFT: " .. n)
end

-- Bulk cancel: clear every approval at once. Removes intent only (an item already
-- requested keeps crafting in RS); the runner fires at most once per approval.
local function clearQueue()
  craftQueue = cqueue.new()
  saveQueue(craftQueue)
  pageShownAt = nowMs()
  flashMsg = "x Queue cleared"; flashAt = nowMs()
  print("Cleared craft queue")
end

-- Open the quota editor for a browsed item, seeding from an existing quota or
-- from sensible defaults (hold current stock, refill one batch above).
local function openEditor(entry)
  local existing = managed.get(managedStore or loadManaged(), entry.name)
  local target, craftTo, ceiling, into, ratio
  if entry.seeded then
    -- accepting a smart-mode suggestion: seed its fields, keep any existing
    -- overflow config, and let the operator review before saving
    target = math.max(0, math.floor(entry.target or (existing and existing.target) or 0))
    craftTo = math.max(target, math.floor(entry.craftTo or (existing and existing.craftTo) or (target + BROWSE_CRAFT_AMOUNT)))
    ceiling = math.max(0, math.floor(entry.ceiling or (existing and existing.ceiling) or 0))
    into = existing and existing.into or nil
    ratio = (existing and existing.ratio) or 1
  elseif existing then
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
  -- a profile may also enable behavior (e.g. smart mode); apply those settings
  local settings = presets.settings(p.id)
  local extra = ""
  if settings.smartMode then
    managed.setSetting(managedStore, "smartMode", true)
    extra = "  + smart mode ON"
  end
  saveManaged(managedStore)
  presetStatus = "Applied " .. tostring(p.label) .. ": " .. n .. " quotas." .. extra
  pageShownAt = nowMs()
  print("Applied preset " .. tostring(p.label) .. " (" .. n .. " quotas)" .. extra)
end

-- Toggle smart mode on/off (persisted on the managed store).
local function toggleSmart()
  managedStore = managedStore or loadManaged()
  local on = not (managed.getSetting(managedStore, "smartMode") == true)
  managed.setSetting(managedStore, "smartMode", on)
  saveManaged(managedStore)
  pageShownAt = nowMs()
  print("Smart mode " .. (on and "ENABLED" or "disabled"))
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
        -- size the one-off craft to the deficit (craftTo - have), capped at
        -- maxRequest; fall back to the default batch when already at/above craftTo
        local stock = config.stockKeeper or {}
        local maxReq = tonumber(stock.maxRequest) or 4096
        local deficit = (editing.craftTo or 0) - (editing.amount or 0)
        local request = (deficit > 0) and math.min(deficit, maxReq) or BROWSE_CRAFT_AMOUNT
        approve({ name = editing.name, label = editing.label, request = request })
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

  -- any tap clears the auto-mode arm; only a consecutive chip tap re-confirms it
  local autoArmed = (modeConfirm == control.MODE_AUTO)
  modeConfirm = nil

  -- header mode chip: cycle the control mode (available on every page)
  if modeChip and y == modeChip.y and x >= modeChip.x1 and x <= modeChip.x2 then
    cycleMode(autoArmed)
    renderCurrent()
    return
  end

  local page = console.tabHit(tabStrip, x, y)
  if page then
    setPage(page)
    renderCurrent()
    return
  end

  -- Plan page: [< PREV] / [NEXT >] paging, then tap a WOULD CRAFT row to approve
  for _, nav in ipairs(planNavRegions) do
    if y == nav.y and x >= nav.x1 and x <= nav.x2 then
      planPage = math.max(1, planPage + nav.delta)
      pageShownAt = nowMs()
      renderCurrent()
      return
    end
  end

  if planActionRegion and y == planActionRegion.y
    and x >= planActionRegion.x1 and x <= planActionRegion.x2 then
    approveAllPlans()
    renderCurrent()
    return
  end

  local planEntry = console.rowHit(planRowRegions, y)
  if planEntry then
    approve(planEntry)
    renderCurrent()
    return
  end

  if queueActionRegion and y == queueActionRegion.y
    and x >= queueActionRegion.x1 and x <= queueActionRegion.x2 then
    clearQueue()
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

  -- Smart page: enable/disable + clear toggles, then tap a suggestion to review
  local smartKey = console.buttonHit(smartButtons, x, y)
  if smartKey == "smarttoggle" then
    toggleSmart()
    renderCurrent()
    return
  elseif smartKey == "smartclear" then
    for _, s in ipairs((lastData and lastData.suggestions) or {}) do
      if s.name then dismissedSuggestions[s.name] = true end
    end
    saveDismissed(dismissedSuggestions)
    pageShownAt = nowMs()
    renderCurrent()
    return
  end
  local smartEntry = console.rowHit(smartRowRegions, y)
  if smartEntry then
    openEditor({ name = smartEntry.name, label = smartEntry.label, craftable = true, seeded = true,
      target = smartEntry.target, craftTo = smartEntry.craftTo, ceiling = smartEntry.ceiling })
    renderCurrent()
    return
  end

  -- Browse page: ALL/MANAGED filter toggle, [< PREV]/[NEXT >] paging, tap a row
  if browseFilterBtn and y == browseFilterBtn.y and x >= browseFilterBtn.x1 and x <= browseFilterBtn.x2 then
    browseFilter = not browseFilter
    browsePage = 1
    pageShownAt = nowMs()
    renderCurrent()
    return
  end
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

  local ok, data, reason = pcall(scan)
  if ok then
    if data then
      lastData = data
      -- in auto mode, enqueue craftable deficits so the runner can maintain quotas
      -- unattended; a no-op in monitor/dry-run/manual (those need a manual tap)
      autoApprovePlans(data.stockPlans)
      -- drive the gated craft runner, then refresh the queue snapshot so the page
      -- reflects this cycle's state transitions (APPROVED -> CRAFTING) immediately
      processCraftQueue(nowMs())
      data.craftQueue = cqueue.list(craftQueue)
      broadcast(data)
    elseif reason == "stale" then
      -- keep the last good plan, but mark it stale so draw() shows a banner
      -- (otherwise a held plan looks live and a real bridge loss reads ONLINE)
      if lastData then lastData.stale = status end
    else
      lastData = nil -- hard failure (e.g. no bridge): show the waiting screen
    end
  else
    lastData = nil
    status = tostring(data)
  end
  renderCurrent()
end

-- Every loop step is guarded: a UI/peripheral error must NOT freeze the console
-- on a dead frame (the worst failure for an unattended in-game screen). On error,
-- log it and drop the monitor handle so the next cycle re-acquires + redraws.
local function guard(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    print("loop error: " .. tostring(err))
    monitor = nil
    paletteApplied = false
  end
end

local refreshTimer = os.startTimer(0)

while true do
  local ev = { os.pullEvent() }
  local kind = ev[1]

  if kind == "timer" and ev[2] == refreshTimer then
    guard(advancePageIfDue)
    guard(refreshAndDraw)
    -- poll interval is operator-tunable (config.refreshSeconds) so a laggy server
    -- can dial back RS-Bridge load; falls back to the constant before first load
    refreshTimer = os.startTimer((config and config.refreshSeconds) or REFRESH_SECONDS)
  elseif kind == "monitor_touch" then
    guard(handleTouch, ev[3], ev[4])
  elseif kind == "redstone" then
    guard(handleRedstone)
  elseif kind == "monitor_resize" then
    guard(function()
      if monitor then pickTextScale() end
      renderCurrent()
    end)
  end
end
