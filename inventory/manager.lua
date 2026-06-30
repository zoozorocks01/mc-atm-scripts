local TITLE = "ATM10 INVENTORY MANAGER"
local MONITOR_SIDE = "auto"
local BRIDGE_NAME = "auto"
local TEXT_SCALE = "auto"
local REFRESH_SECONDS = 5
-- Craftability/crafting are expensive RS Bridge calls; cache them across scans to
-- stay responsive on a laggy server. A NOT-craftable result expires fast (so a
-- newly-added pattern shows quickly); a craftable result is held longer.
-- Bundled into one table to stay well under Lua's 200-local-per-function cap: CC's
-- Lua (Cobalt) counts main-chunk locals stricter than Lua 5.4, so a packed table
-- (one local) is the safe way to hold many constants.
local TTL = { craftableTrue = 60000, craftableFalse = 10000, crafting = 6000 } -- ms
-- Broadcast slice sizes: an 8-item header summary (topItems) + a larger BOUNDED
-- list (viewItems) the read-only viewer paginates (VIEW-1). Capped, never thousands.
local BROADCAST_ITEMS = { top = 8, view = 150 }
local BROADCAST_ENABLED = true
local BROADCAST_MODEM_SIDE = "auto"
local BROADCAST_PROTOCOL = "atm10-inventory-v1"
local CRAFT_RESULTS = { file = ".atm10-craft-results", max = 150 } -- last-craft outcome (QUICK-5); bounded
-- On-disk filenames bundled into one table (same locals-cap reason as TTL above).
local FILES = {
  config = "inventory-config",
  ledger = ".atm10-stock-ledger",
  queue = ".atm10-craft-queue",
  managed = ".atm10-managed",       -- operator-set quotas (tap-to-manage store)
  trends = ".atm10-trends",         -- smart-mode consumption history (survives reboot)
  dismissed = ".atm10-dismissed",   -- smart suggestions the operator cleared
  craftstate = ".atm10-craftstate", -- drain snapshot read by safereboot (avoids the AP detach-crash)
  heartbeat = ".atm10-heartbeat",   -- liveness ping; startup watchdog restarts a hung manager
}
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
local PAGES = { "PLAN", "QUEUE", "HEALTH", "BROWSE", "PRESETS", "SMART" }
-- short tab labels used when the full strip would overflow a narrow monitor
local PAGES_SHORT = { "PLAN", "QUE", "HLTH", "BRWS", "PRE", "SMRT" }
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
    overflowReserve = 0,      -- CRAFT-5: compress slots reserved first within the cap (0 = pure priority)
    manualReserve = 1,        -- A1: slots reserved first for manual/oneshot jobs (quotas can't starve them)
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
local firedTimes = {}      -- ms timestamps of crafts fired in the last 60s (throughput readout)
local lastCraftAt = nil    -- ms of the most recent craftItem (unpruned; drives reboot-safety)
local craftQueue = nil
local craftResults = nil -- name -> { ok, reason, at } (QUICK-5); nil = not yet loaded from disk
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
local queueRowRegions = {}
local queueActionRegion = nil -- [CLEAR QUEUE] bulk button on the Queue page
local browseRowRegions = {}
local browseNavRegions = {}
local presetRowRegions = {}
local ui = {            -- bundled flash/page transient scalars (B1-prep)
  pageShownAt = nil,    -- auto-rotate timer anchor
  lastInteractionAt = nil, -- last monitor touch; pauses auto-rotation after taps
  modeConfirm = nil,    -- mode awaiting a confirm tap (auto only)
  presetStatus = nil,   -- short confirmation line after applying a preset
  flashMsg = nil,       -- transient confirmation on the active page hint line
  flashAt = 0,          -- when flashMsg was set (ms)
  FLASH_MS = 4000,      -- how long an approve/cancel confirmation stays up
  frame = nil,          -- B1: in-progress render buffer (set during a render)
  prevFrame = nil,      -- B1: last rendered buffer, for the flicker-free diff
}
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
local DISMISSED_OPTS = { maxAgeMs = 604800000, maxEntries = 400 } -- 7d TTL + 400 cap (drop-oldest)
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

  -- Resolve the high-level operating tier (viewer/manual/auto), if set, into
  -- mode/allowAutocraft/stockKeeper.enabled BEFORE they are individually normalized
  -- below. Unset tier -> no-op (raw mode/flags used, backward compatible).
  control.applyTier(cfg)

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
  -- CRAFT-5: clamp the compress reserve to a non-negative integer; fireOrder clamps it to
  -- the cap at use time, so a mis-set value (e.g. 99) can never exceed maxCraftsPerCycle.
  cfg.stockKeeper.overflowReserve = math.max(0, math.floor(tonumber(cfg.stockKeeper.overflowReserve) or 0))
  -- A1: the per-cycle slice reserved for manual jobs (non-negative integer; fireOrder
  -- clamps it to the cap at use time, so a mis-set value can never exceed maxCraftsPerCycle).
  cfg.stockKeeper.manualReserve = math.max(0, math.floor(tonumber(cfg.stockKeeper.manualReserve) or 1))
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

  if not fs.exists(FILES.config) then
    config = normalizeConfig(DEFAULT_CONFIG)
    return
  end

  local ok, loaded = pcall(dofile, FILES.config)
  if not ok then
    config = normalizeConfig(DEFAULT_CONFIG)
    configError = "Config error: " .. tostring(loaded)
    return
  end

  config = normalizeConfig(loaded)
end

local function readLedger()
  ledgerError = nil

  if not fs.exists(FILES.ledger) then
    return { requests = {} }
  end

  local file = fs.open(FILES.ledger, "r")
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

-- Atomically write content to path (tmp + move), fully guarded: serialization,
-- a full disk, a leftover .tmp from a prior crash, or any fs error returns false
-- instead of throwing up into the event loop (which would freeze the console).
-- Clears a stale .tmp first so a single failed write doesn't wedge every future
-- save. Tables are serialized inside this guard so callers cannot accidentally
-- throw before the protected write path starts.
local function atomicWrite(path, content)
  if type(content) ~= "string" then
    local ok, encoded = pcall(textutils.serialize, content)
    if not ok or type(encoded) ~= "string" then return false end
    content = encoded
  end
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
  return atomicWrite(FILES.ledger, data)
end

-- Load the approved-craft queue (fail-safe: any problem yields an empty queue).
local function loadQueue()
  if not fs.exists(FILES.queue) then return cqueue.new() end
  local file = fs.open(FILES.queue, "r")
  if not file then return cqueue.new() end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok then return cqueue.new() end
  return cqueue.normalize(data)
end

-- Load operator-set quotas (fail-safe: any problem yields an empty store).
local function loadManaged()
  if not fs.exists(FILES.managed) then return managed.new() end
  local file = fs.open(FILES.managed, "r")
  if not file then return managed.new() end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok then return managed.new() end
  return managed.normalize(data)
end

local function saveManaged(store)
  return atomicWrite(FILES.managed, store)
end

local function saveQueue(q)
  return atomicWrite(FILES.queue, q)
end

-- Liveness ping: the startup watchdog restarts the program if these stop landing
-- (a hang the pcall-restart loop can't catch). Fixed-size; overwrites in place.
local function writeHeartbeat(now)
  pcall(atomicWrite, FILES.heartbeat, tostring(now or 0))
end

-- Persist a tiny drain snapshot so `safereboot` can decide whether detaching this
-- computer is safe even after the manager is terminated (the file outlives the
-- process). Fixed-size; overwrites in place (no growth). Fail-safe: best effort.
local function writeCraftState(now, crafting, craftingNames)
  pcall(atomicWrite, FILES.craftstate, {
    at = now,
    lastCraftAt = lastCraftAt,
    crafting = tonumber(crafting) or 0,
    craftingNames = craftingNames or {},
  })
end

-- Smart-mode trend history is wall-clock based (os.epoch), so persisting it lets
-- the drain window survive a reboot instead of restarting from zero each boot.
-- Fail-safe: any problem yields an empty history (smart mode just relearns).
local function loadTrends()
  if not fs.exists(FILES.trends) then return {} end
  local file = fs.open(FILES.trends, "r")
  if not file then return {} end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" then return {} end
  -- Bound on load: suggest.prune otherwise runs ONLY in the throttled save block
  -- (and never when smart mode is off), so a trend file already over the cap (an
  -- older build, a long session persisted then reloaded after a watchdog restart)
  -- would sit oversized in memory + on disk until the first 2-min save tick. Prune
  -- here so the size is bounded from boot regardless of save timing or smart mode.
  return (suggest.prune(data, nowMs(), {
    maxAgeMs = TREND_MAX_AGE_MS, maxWindowMs = TREND_MAX_WINDOW_MS, maxEntries = TREND_MAX_ENTRIES,
  }))
end

local function saveTrends(history)
  return atomicWrite(FILES.trends, history or {})
end

-- Dismissed smart suggestions persist too: now that the trend window survives a
-- reboot, suggestions would otherwise reappear after every restart. Fail-safe.
local function loadDismissed()
  if not fs.exists(FILES.dismissed) then return {} end
  local file = fs.open(FILES.dismissed, "r")
  if not file then return {} end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function saveDismissed(set)
  return atomicWrite(FILES.dismissed, set or {})
end

-- Per-item last-craft results (QUICK-5): own file, own cap, atomicWrite -- so a
-- craft outcome survives reboots and is debuggable from the editor/queue without
-- coupling to the ledger's error semantics.
local function loadCraftResults()
  if not fs.exists(CRAFT_RESULTS.file) then return {} end
  local file = fs.open(CRAFT_RESULTS.file, "r")
  if not file then return {} end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" then return {} end
  -- Bound on load (matching the dismissed-set pattern): pruneResults otherwise
  -- only runs when a craft fires, so a manager that loads an oversized file (left
  -- by an older build, an external edit, or a long no-craft period) and never
  -- fires would hold it un-bounded on the ~1MB disk. Newest-kept, drop-oldest.
  return (cqueue.pruneResults(data, CRAFT_RESULTS.max))
end

local function saveCraftResults(map)
  return atomicWrite(CRAFT_RESULTS.file, map or {})
end

local function ensureCraftResults()
  if craftResults == nil then craftResults = loadCraftResults() end
  return craftResults
end

-- compact "how long ago" for craft-result readouts: 45s / 12m / 3h / 2d
local function agoShort(at, now)
  local s = math.max(0, math.floor(((now or nowMs()) - (tonumber(at) or 0)) / 1000))
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < 86400 then return math.floor(s / 3600) .. "h" end
  return math.floor(s / 86400) .. "d"
end

-- short queue-column token for a name's last-craft result, or "-" if none yet
local function craftResultShort(name, now)
  local r = ensureCraftResults()[name]
  if not r then return "-" end
  return (r.ok and "OK " or "rej ") .. agoShort(r.at, now)
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
  -- setTextScale below resets the monitor (clears it AND fires a monitor_resize) -- an
  -- out-of-band clear the B1 diff-renderer cannot see. Invalidate the diff baseline so
  -- the next render does a FULL repaint; otherwise the post-clear frame diffs as
  -- "unchanged" against the stale prevFrame and every row is skipped -> the screen
  -- stays black even though the buffer is correct. (Root cause of the manager's blank
  -- monitor: the remote viewers never re-scale, so they never tripped this.)
  ui.prevFrame = nil
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

-- B1 double-buffer: route drawing through the frame buffer when one is active (set
-- during a render via present()/the render frame-setup), so the screen diff-renders
-- with NO monitor.clear() flash between frames. ui.frame holds the in-progress buffer
-- (a field on the ui table -- no new top-level local at the manager's cap). When no
-- frame is active (e.g. a direct call outside a render) these write straight through.
local function line(y, text, color, bg)
  if ui.frame then
    uiDraw.bufferWrite(ui.frame, 1, y, uiDraw.fit(text, ui.frame.width), color or colors.white, bg or colors.black)
  else
    uiDraw.line(monitor, y, text, color or colors.white, bg or colors.black)
  end
end

local function mwrite(x, y, text, fg, bg)
  if ui.frame then
    uiDraw.bufferWrite(ui.frame, x, y, text, fg or colors.white, bg or colors.black)
  else
    uiDraw.write(monitor, x, y, text, fg or colors.white, bg or colors.black)
  end
end

-- Build one frame via renderFn (which draws through line()/mwrite()), then diff-render
-- only the rows that changed -- no whole-screen clear flash. Used by the small direct
-- renders (drawWaiting); the main render inlines the same setup/teardown.
local function present(renderFn)
  local w, h = monitor.getSize()
  ui.frame = uiDraw.newBuffer(w, h)
  renderFn()
  ui.prevFrame = uiDraw.renderBuffer(monitor, ui.frame, ui.prevFrame)
  ui.frame = nil
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
    local ttl = cached.v and TTL.craftableTrue or TTL.craftableFalse
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
  if cached and (nowMs() - cached.at) < TTL.crafting then return cached.v end

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

  -- STAB-2: recheck attachment immediately before the mutating craftItem. Firing
  -- craftItem at a half-detached bridge is the precise trigger for the async
  -- AdvancedPeripherals NotAttachedException that crashes the whole server tick
  -- (no Lua pcall can catch it). The read path (scan) already distrusts an offline
  -- bridge; the craft path must too. Treat only an EXPLICIT offline signal as
  -- offline (matching scan's semantics) so builds lacking these methods still
  -- craft; drop the cached handle so the next scan re-acquires it.
  local connected = call(bridge, "isConnected")
  local online = call(bridge, "isOnline")
  if connected == false or online == false then
    bridge = nil
    return false, "bridge offline"
  end

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
    ui.modeConfirm = control.MODE_AUTO -- arm: require a consecutive second chip tap
    return
  end
  ui.modeConfirm = nil
  managedStore = managedStore or loadManaged()
  managed.setSetting(managedStore, "modeOverride", nextMode)
  saveManaged(managedStore)
  ui.pageShownAt = nowMs()
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

-- CTRL-3: the control-center foundation, wired into the console. Off by default
-- (config.controlEnabled). A control command arrives over the "atm10-control-v1"
-- rednet protocol; handleControlMessage authorizes the sender + token and dispatches
-- it through the SAME capability gates as autocraft, then a real redstone output
-- fires. redstoneState tracks each side so a toggle flips it.
local redstoneState = {}
local function handleControlMessage(senderId, message)
  if config.controlEnabled ~= true then return end -- master off-switch (default off)
  -- A1: also carry the autocraft capability so a craft_request is gated by BOTH
  -- controlEnabled AND allowAutocraft (matching the existing security posture).
  local policy = control.policy({
    allowRedstone = config.allowRedstone == true,
    allowExport = config.allowExport == true,
    allowAutocraft = config.allowAutocraft == true,
    token = config.controlToken,
    allowedSenders = config.controlAllowedSenders,
  })
  -- A1: enqueue a one-time craft job. Resolves label + craftFrom from the managed
  -- quota if one exists (so the job inherits the same source-reserve rule), else
  -- bare name. Errors here are pcall-contained by control.dispatch, so a bad request
  -- can't crash the loop. Closures live inside this existing function -> no net new
  -- top-level local (LOCALS CAP is a hard rule).
  local rsActuator = control.redstoneActuator(rs, redstoneState)
  local function craftRequestActuator(cmd)
    local name = cmd.target
    local args = (type(cmd.args) == "table") and cmd.args or {}
    local count = math.floor(tonumber(args.count) or 0)
    if not name or count <= 0 then error("bad craft request", 0) end
    craftQueue = craftQueue or loadQueue()
    managedStore = managedStore or loadManaged()
    local label, craftFrom = name, nil
    local quota = managed.get(managedStore, name)
    if quota then label = quota.label or name; craftFrom = quota.craftFrom end
    cqueue.enqueueJob(craftQueue, {
      name = name, label = label, requested = count,
      force = (args.force == true), craftFrom = craftFrom,
    }, nowMs())
    saveQueue(craftQueue)
    ui.flashMsg = "job: " .. tostring(label) .. " x" .. count
    ui.flashAt = nowMs()
  end
  -- dispatch takes ONE actuator; branch by action so each command reaches its handler.
  local function actuator(cmd, spec)
    if cmd.action == "craft_request" then return craftRequestActuator(cmd) end
    return rsActuator(cmd, spec)
  end
  local result = control.handleMessage(senderId, message, policy, actuator)
  if result and result.ok then
    ui.flashMsg = ui.flashMsg or ("control: " .. tostring(result.action))
  else
    ui.flashMsg = "control denied: " .. tostring(result and result.reason or "?")
  end
  ui.flashAt = nowMs()
end

-- Run the approved craft queue through the gated runner. The runner performs at
-- most one bridge request per approval; nothing crafts unless mode + capability
-- + approval all pass. Returns nothing; prints a short line per request/failure.
local function processCraftQueue(now)
  if not craftQueue then return end
  local stock = config.stockKeeper or {}
  -- A1: recompute each manual job's per-fire batch = remaining (requested - made) so a
  -- job split across cycles by a craftFrom clamp sends only the remainder next pass.
  for _, e in ipairs(cqueue.list(craftQueue)) do
    if cqueue.isManual(e) then
      e.request = math.max(0, (tonumber(e.requested) or tonumber(e.request) or 0) - (tonumber(e.made) or 0))
    end
  end
  local summary = craftrunner.run(craftQueue, {
    policy = buildPolicy(),
    mode = effectiveMode(),
    now = now,
    cooldownMs = (tonumber(stock.cooldownSeconds) or 300) * 1000,
    -- rate-limit ACTUAL bridge requests per cycle (the plan display is uncapped)
    maxPerCycle = tonumber(stock.maxCraftsPerCycle) or 2,
    -- CRAFT-5: reserve part of that cap for compress/overflow rows (0 = pure priority)
    overflowReserve = tonumber(stock.overflowReserve) or 0,
    -- A1: reserve >=1 slot per cycle for manual jobs so a quota flood can't starve them
    manualReserve = tonumber(stock.manualReserve) or 1,
    -- A1: live source amount for a job's craftFrom reserve (getItems is TTL-cached, cheap)
    resolve = function(name) local it = findStoredItem(getItems(), name); return it and itemAmount(it) or 0 end,
    isCrafting = function(name) return isItemCrafting(name) end,
    craft = function(name, amount) return requestCraft(name, amount) end,
    recordRequest = recordCraftRequest,
  })
  -- A1: a manual job that fired its full N completes; drop it (the manager owns
  -- persistence + the completion flash) and persist the change.
  for _, c in ipairs(summary.completed or {}) do
    cqueue.dropJob(craftQueue, c.key)
    ui.flashMsg = "done: " .. tostring(c.name)
    ui.flashAt = now
  end
  if #(summary.completed or {}) > 0 then saveQueue(craftQueue) end
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

  -- QUICK-5: persist the last-craft outcome per item (ok/reason/timestamp) so the
  -- editor + queue can show whether a craft actually succeeded -- craftItem's exact
  -- return shape is unconfirmed in-world, so a persistent result makes the first
  -- real craft debuggable from the screen. Bounded + atomicWrite.
  if #summary.requested > 0 or #summary.failed > 0 then
    ensureCraftResults()
    for _, r in ipairs(summary.requested) do cqueue.recordResult(craftResults, r.name, true, nil, now) end
    for _, f in ipairs(summary.failed) do cqueue.recordResult(craftResults, f.name, false, f.reason, now) end
    cqueue.pruneResults(craftResults, CRAFT_RESULTS.max)
    saveCraftResults(craftResults)
  end

  for _, r in ipairs(summary.requested) do
    firedTimes[#firedTimes + 1] = now
    lastCraftAt = now -- unpruned: marks the start of the AP drain window for safereboot
    print("Craft requested: " .. tostring(r.name) .. " x" .. tostring(r.amount))
  end
  -- keep only the last 60s so #firedTimes == crafts/min (bounds the list too)
  local keptFired = {}
  for _, ts in ipairs(firedTimes) do if now - ts <= 60000 then keptFired[#keptFired + 1] = ts end end
  firedTimes = keptFired
  for _, f in ipairs(summary.failed) do
    print("Craft failed (" .. tostring(f.reason) .. "): " .. tostring(f.name))
  end

  -- Persist the drain snapshot every cycle so `safereboot` (which runs after the
  -- manager is terminated) can tell whether detaching now would crash the server.
  local craftingNames = {}
  for _, e in ipairs(inflight) do craftingNames[#craftingNames + 1] = e.name end
  writeCraftState(now, #inflight, craftingNames)
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

  -- A3 bridge-degraded gating: stash the health module + its consecutive-failure
  -- state on craftingCache (a table only ever keyed by exact mod:item registry
  -- names and never pairs()-iterated, so a reserved __-key can't collide; locals
  -- are at the 186 cap so this avoids a new bare top-level local). The single
  -- per-cycle bridge outcome is fed below; gateCrafts decides fire-vs-hold.
  -- A3 health module is OPTIONAL: pcall the require and fall back to an always-allow
  -- stub, so a not-yet-deployed / missing atm10-health can NEVER crash the manager --
  -- it just degrades to pre-A3 "always fire". require() throws a HARD error in CC if
  -- the file isn't on the computer (it previously crash-looped the whole manager when
  -- the update manifest shipped this caller but not the module). Cached once (nil-check,
  -- not `or`) so a missing module isn't re-required every scan.
  if craftingCache.__health == nil then
    local ok, mod = pcall(require, "atm10-health")
    craftingCache.__health = (ok and mod) or { gateCrafts = function() return true end }
  end
  craftingCache.__bridge = craftingCache.__bridge or {}

  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale() end
  end

  if not bridge then
    bridge, bridgeName = findPeripheral({ "rs_bridge", "rsBridge" }, BRIDGE_NAME)
  end

  if not bridge then
    status = "No RS Bridge found"
    -- no bridge to fire at: count it as a degraded cycle.
    craftingCache.__bridge.allowFire = craftingCache.__health.gateCrafts(craftingCache.__bridge, false)
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
    -- degraded cycle: a stale/offline read must hold back craft-firing.
    craftingCache.__bridge.allowFire = craftingCache.__health.gateCrafts(craftingCache.__bridge, false)
    return nil, "stale"
  end

  local unique = 0
  local totalAmount = 0
  local craftableCount = 0
  local scanned = {}

  itemsByName = {} -- rebuilt each scan so findStoredItem is a local lookup
  for _, item in pairs(items) do
    local amount = itemAmount(item)
    unique = unique + 1
    totalAmount = totalAmount + amount
    if item.isCraftable then craftableCount = craftableCount + 1 end
    if item.name then itemsByName[item.name] = item end
    scanned[#scanned + 1] = item
  end
  lastUnique = unique -- remember a good read so the next empty read is caught as stale

  -- clean read: feed a success to the gate. With recovery hysteresis this does NOT
  -- immediately re-allow firing after a degraded window -- it takes recoverCycles
  -- consecutive clean reads to resume, so a just-reattached bridge isn't crafted at.
  craftingCache.__bridge.allowFire = craftingCache.__health.gateCrafts(craftingCache.__bridge, true)

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
      dismissedSuggestions = suggest.pruneDismissed(loadDismissed(), nowMs(), DISMISSED_OPTS)
      dismissedLoaded = true
    end
    -- track drain for ALL items, not just craftable ones: with the live grid
    -- reporting craftable=0, gating on isCraftable would learn nothing.
    local snapshot = {}
    for _, item in ipairs(scanned) do
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
    -- CRAFT-6: thread the real craft cooldown (buffers a suggested craftTo to last until the next
    -- allowed craft) + the opt-in compress-chain promotion (a managed setting, like smartMode).
    suggestions = suggest.analyze(trendHistory,
      { managed = managedNames, quotas = quotasMap, dismissed = dismissedSuggestions, max = 8,
        cooldownSeconds = (config.stockKeeper or {}).cooldownSeconds,
        compressChains = managed.getSetting(managedStore, "compressChains") == true,
        resurfaceFactor = (config.stockKeeper or {}).resurfaceFactor })
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
    local prev = bridgeStats or {}
    local function keep(key, value)
      if value ~= nil then return value end
      return prev[key]
    end
    local totalItemStorage = call(bridge, "getTotalItemStorage")
    if totalItemStorage == nil then totalItemStorage = call(bridge, "getMaxItemDiskStorage") end
    local storedEnergy = call(bridge, "getStoredEnergy")
    if storedEnergy == nil then storedEnergy = call(bridge, "getEnergyStorage") end
    local energyCapacity = call(bridge, "getEnergyCapacity")
    if energyCapacity == nil then energyCapacity = call(bridge, "getMaxEnergyStorage") end
    bridgeStats = {
      usedItemStorage = keep("usedItemStorage", call(bridge, "getUsedItemStorage")),
      totalItemStorage = keep("totalItemStorage", totalItemStorage),
      availableItemStorage = keep("availableItemStorage", call(bridge, "getAvailableItemStorage")),
      storedEnergy = keep("storedEnergy", storedEnergy),
      energyCapacity = keep("energyCapacity", energyCapacity),
      energyUsage = keep("energyUsage", call(bridge, "getEnergyUsage")),
    }
    bridgeStatsAt = statNow
  end

  return {
    connected = connected,
    online = online,
    items = scanned,
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
    -- CRAFT-3: count quotas missing from the live grid ONCE here (inputs only
    -- change on scan); drawPlanPage reads this instead of re-looping every render.
    notInGrid = managed.countNotInGrid(managedStore, itemsByName),
  }
end

local function compactItems(items, limit, withTrend)
  local compact = {}
  -- route the cap through the tested console.boundedSlice (VIEW-1): payload stays
  -- <= limit no matter how large the grid is.
  for _, item in ipairs(console.boundedSlice(items, limit)) do
    local entry = { name = itemName(item), amount = itemAmount(item), id = item.name }
    -- VIEW-5: attach a compact trend (nil when smart mode is off / no history,
    -- so the viewer just hides it -- no new bridge calls, data already collected).
    if withTrend then entry.trend = suggest.trend(trendHistory, item.name) end
    compact[#compact + 1] = entry
  end
  return compact
end

local function broadcast(data)
  if not BROADCAST_ENABLED or not broadcastReady or not data then return end
  local broadcastItems = console.sortedItems(data.items, "qty", {
    name = itemName,
    amount = itemAmount,
    id = function(it) return it.name end,
  })

  -- The payload table is built OUTSIDE the send pcall so a logic error here still
  -- throws (the pcall must never mask a payload-build bug).
  local payload = {
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
    topItems = compactItems(broadcastItems, BROADCAST_ITEMS.top),
    viewItems = compactItems(broadcastItems, BROADCAST_ITEMS.view, true),
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
  }

  -- The viewer broadcast is a strictly-secondary, best-effort path. rednet.broadcast
  -- can throw if the modem was closed/removed mid-run; that transient must NOT abort
  -- refreshAndDraw before renderCurrent(), which would deny the PRIMARY console its
  -- frame (and make guard() needlessly null a healthy monitor). Genuine runtime
  -- resilience for an optional outbound transport -- the payload is already built,
  -- so this pcall cannot hide a logic bug.
  pcall(rednet.broadcast, payload, BROADCAST_PROTOCOL)
end

local function drawWaiting(message)
  present(function()
    line(1, TITLE, colors.cyan)
    line(3, message, colors.red)
    line(5, "Attach monitor + RS Bridge to this computer.", colors.gray)
  end)
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

  -- CRAFT-3: quotas whose item isn't in the live grid -- computed once in scan()
  -- (its inputs only change on scan) and read here so it doesn't re-loop every
  -- render/touch. See managed.countNotInGrid for why presence-in-grid is the signal.
  local notInGrid = data.notInGrid or 0
  line(planLabelY, "Stock Keeper Plan [" .. tostring(effectiveMode()) ..
    "]   page " .. pg.page .. "/" .. pg.pages ..
    (notInGrid > 0 and ("   " .. notInGrid .. " not in grid") or ""), colors.cyan)
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
  local prev, next = "[ < PREV ]", "[ NEXT > ]"
  local nextX = #prev + 2
  mwrite(1, navY, prev, pg.page > 1 and colors.black or colors.gray,
    pg.page > 1 and colors.cyan or colors.black)
  mwrite(nextX, navY, next, pg.page < pg.pages and colors.black or colors.gray,
    pg.page < pg.pages and colors.cyan or colors.black)
  planNavRegions = {
    { x1 = 1, x2 = #prev, y = navY, delta = -1 },
    { x1 = nextX, x2 = nextX + #next - 1, y = navY, delta = 1 },
  }
  local tally = data.stockTally or {}
  if w >= 40 then
    local tallyX = nextX + #next + 2
    mwrite(tallyX, navY, "+" .. fmt(tally.OK) .. " >" .. fmt(tally.WOULD) ..
      " ~" .. fmt(tally.CRAFTING) .. " x" .. fmt(tally.NO_RECIPE) .. " #" .. fmt(tally.BLOCKED), colors.gray)
  end

  -- footer hint: a recent action flashes a confirmation here, else the tap hint
  local flashing = ui.flashMsg and (nowMs() - ui.flashAt < ui.FLASH_MS)
  if (tally.WOULD or 0) > 0 then
    line(h, flashing and ui.flashMsg or "Tap a > WOULD row to approve.", flashing and colors.white or colors.lime)
    -- bulk: one tap approves EVERY WOULD CRAFT row (all pages), right-aligned so
    -- it never collides with the hint text
    local label = " [ APPROVE ALL ] "
    local bx = w - #label + 1
    if bx > 30 then
      mwrite(bx, h, label, colors.black, colors.lime)
      planActionRegion = { x1 = bx, x2 = bx + #label - 1, y = h }
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
    line(7, uiDraw.fit("ITEM", math.max(16, w - 40)) .. "  REQUEST   GATE      AGE   LAST", colors.gray)
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
    -- A1: a manual job shows made/requested progress instead of the +batch refill amount
    local reqCol
    if cqueue.isManual(e) then
      reqCol = fmt(tonumber(e.made) or 0) .. "/" .. fmt(tonumber(e.requested) or 0)
    else
      reqCol = "+" .. fmt(e.request)
    end
    local text
    if wide then
      text = uiDraw.fit(tostring(e.label or e.name), math.max(16, w - 40)) ..
        "  " .. rjust(reqCol, 7) ..
        "  " .. uiDraw.fit(uiStatus.label(gateState), 8) ..
        "  " .. rjust(ageS .. "s", 4) ..
        "  " .. uiDraw.fit(craftResultShort(e.name, now), 9)
    else
      text = uiDraw.fit(tostring(e.label or e.name) .. " " .. reqCol ..
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
    local flashing = ui.flashMsg and (nowMs() - ui.flashAt < ui.FLASH_MS)
    line(hintY, flashing and ui.flashMsg or "Tap a row to cancel its approval.", flashing and colors.white or colors.gray)
    -- bulk: one tap cancels every approval, right-aligned past the hint text
    local label = " [ CLEAR QUEUE ] "
    local bx = w - #label + 1
    if bx > 34 then
      mwrite(bx, hintY, label, colors.black, colors.red)
      queueActionRegion = { x1 = bx, x2 = bx + #label - 1, y = hintY }
    end
  end
end

-- Browse the live grid and tap any item to set/edit its stock quota (no
-- hand-typed registry IDs). Managed items show their target. Rows are paginated;
-- [< PREV] / [NEXT >] tap targets sit on the bottom line.
local function drawBrowsePage(data)
  local w, h = monitor.getSize()
  local store = managedStore or managed.new()
  local sourceItems = type(data.items) == "table" and data.items or nil
  if ui.browseItemsSource ~= sourceItems or type(ui.browseSortedItems) ~= "table" then
    ui.browseItemsSource = sourceItems
    ui.browseSortedItems = console.sortedItems(sourceItems or {}, "qty",
      { name = itemName, amount = itemAmount, id = function(it) return it.name end })
  end
  local items = ui.browseSortedItems

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
    line(listTop, browseFilter and "No managed quotas yet. Tap MANAGED below to show all items." or
      "Grid is empty or unavailable.", colors.gray)
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
  local prev, next = "[ < PREV ]", "[ NEXT > ]"
  local nextX = #prev + 2
  mwrite(1, navY, prev, pg.page > 1 and colors.black or colors.gray,
    pg.page > 1 and colors.cyan or colors.black)
  mwrite(nextX, navY, next, pg.page < pg.pages and colors.black or colors.gray,
    pg.page < pg.pages and colors.cyan or colors.black)
  browseNavRegions = {
    { x1 = 1, x2 = #prev, y = navY, delta = -1 },
    { x1 = nextX, x2 = nextX + #next - 1, y = navY, delta = 1 },
  }
  -- ALL <-> MANAGED filter toggle (cuts the ~5.9k haystack to your quota'd items).
  -- Hidden while picking a compress target, where tapping it would be a dead no-op.
  if not (editing and editing.pickingInto) then
    local toggle = browseFilter and "[MANAGED]" or "[ALL]"
    local toggleX = nextX + #next + 2
    if toggleX + #toggle - 1 <= w then
      mwrite(toggleX, navY, toggle, colors.black, browseFilter and colors.lime or colors.cyan)
      browseFilterBtn = { x1 = toggleX, x2 = toggleX + #toggle - 1, y = navY }
      local hintX = toggleX + #toggle + 1
      if hintX <= w then
        mwrite(hintX, navY, uiDraw.fit("tap item to set quota", w - hintX + 1), colors.gray, colors.black)
      end
    end
  end
end

-- Render a button row and keep it for hit-testing. specs: {{label,key}}.
local function renderButtonRow(specs, y)
  local row = { buttons = {}, y = y }
  local x = 1
  for _, spec in ipairs(specs or {}) do
    local text = " [ " .. tostring(spec.label) .. " ] "
    local x1 = x
    local x2 = x + #text - 1
    local b = { key = spec.key, label = spec.label, text = text, x1 = x1, x2 = x2, y = y }
    row.buttons[#row.buttons + 1] = b
    mwrite(x1, y, text, colors.black, colors.cyan)
    x = x2 + 3
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
-- Shows the exact integer (not fmt-rounded) whenever width allows, so a small
-- step on a big number is visible (e.g. +100 on 264000 must not display as an
-- unchanged "264.0k").
local function renderFieldRow(label, value, field, y)
  -- placed left-to-right with no hardcoded x: [-] LABEL: value [+]. The [+] sits
  -- right after the (exact-integer) value, so it never overlaps a big number.
  local w = monitor.getSize()
  local text = label .. ": " .. tostring(math.floor(tonumber(value) or 0))
  local minusText, plusText = " [ - ] ", " [ + ] "
  local textX = #minusText + 2
  local maxText = math.max(1, w - textX - #plusText - 1)
  if #text > maxText then text = uiDraw.fit(text, maxText) end
  mwrite(1, y, minusText, colors.black, colors.cyan)
  mwrite(textX, y, text, colors.white, colors.black)
  local plusX = textX + #text + 1
  mwrite(plusX, y, plusText, colors.black, colors.cyan)
  editorRows[#editorRows + 1] = { y = y, buttons = {
    { key = field .. ":-", x1 = 1, x2 = #minusText },
    { key = field .. ":+", x1 = plusX, x2 = plusX + #plusText - 1 },
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

  local stepText = "step: " .. stepLabel(e.step) ..
    (e.step >= STACK and ("  (" .. fmt(e.step) .. ")") or "")
  local stepButton = " [ STEP ] "
  local stepMaxText = math.max(1, w - #stepButton - 1)
  if #stepText > stepMaxText then stepText = uiDraw.fit(stepText, stepMaxText) end
  mwrite(1, 8, stepText, colors.gray, colors.black)
  do
    local stepX = math.max(1, math.min(w - #stepButton + 1, #stepText + 2))
    local r = { y = 8, buttons = {
      { key = "step", label = "STEP", text = stepButton, x1 = stepX, x2 = stepX + #stepButton - 1, y = 8 },
    } }
    for _, b in ipairs(r.buttons) do mwrite(b.x1, 8, b.text, colors.black, colors.cyan) end
    editorRows[#editorRows + 1] = r
  end

  -- QUICK-5: last-craft outcome for this item, so Browse doubles as a craft-debug
  -- lookup (survives reboot + the item leaving the queue).
  do
    ensureCraftResults()
    local lc = craftResults[e.name]
    local now = nowMs()
    local txt, col
    if not lc then
      txt, col = "last craft: never", colors.gray
    elseif lc.ok then
      txt, col = "last craft: OK " .. agoShort(lc.at, now) .. " ago", colors.lime
    else
      txt, col = "last craft: rejected " .. agoShort(lc.at, now) .. " ago - " .. tostring(lc.reason or ""), colors.orange
    end
    line(9, uiDraw.fit(txt, w), col)
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

  -- CRAFT-3: a quota whose item isn't in the live grid does nothing useful. Flag it
  -- distinctly from a recognized item (presence in getItems is the reliable signal;
  -- isCraftable reads blind here -- see the Plan-page note).
  if not itemsByName[e.name] then
    line(15, uiDraw.fit("NOT IN GRID: 0 stored - typo/version-drift ID, or never stocked.", w), colors.orange)
  end

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

  if ui.presetStatus then
    line(start + rows + 1, uiDraw.fit(ui.presetStatus, w), colors.lime)
  end
  local flashing = ui.flashMsg and (nowMs() - ui.flashAt < ui.FLASH_MS)
  line(h, flashing and ui.flashMsg or "Applied quotas appear on Plan; approve them there (or use auto mode).",
    flashing and colors.white or colors.gray)
end

-- Smart mode (opt-in): suggests recurring quotas from observed drain.
local function drawSmartPage(data)
  local w, h = monitor.getSize()
  local on = data.smartMode == true
  -- a recent tap (enable/disable/clear) flashes its confirmation on the footer hint
  local flashing = ui.flashMsg and (nowMs() - ui.flashAt < ui.FLASH_MS)

  line(6, "Smart Mode: " .. (on and "ON" or "OFF") .. "   (suggests quotas from drain)",
    on and colors.lime or colors.gray)
  do
    local specs = { { label = on and "DISABLE" or "ENABLE", key = "smarttoggle" } }
    if on and #(data.suggestions or {}) > 0 then specs[#specs + 1] = { label = "CLEAR", key = "smartclear" } end
    local r = console.buttonRow(specs, 7, 1)
    for _, b in ipairs(r.buttons) do mwrite(b.x1, 7, b.text, colors.cyan, colors.black) end
    smartButtons = r
  end

  if not on then
    line(9, "Off by default. Enable here, or apply the zoozo-late-game profile.", colors.gray)
    line(10, "When on, items that keep draining are suggested as recurring quotas.", colors.gray)
    if flashing then line(h, ui.flashMsg, colors.white) end
    return
  end

  local sugg = data.suggestions or {}
  if #sugg == 0 then
    line(9, "No suggestions yet - watching consumption...", colors.gray)
    line(10, "Items that decline over time will appear here to review + accept.", colors.gray)
    if flashing then line(h, ui.flashMsg, colors.white) end
    return
  end

  line(9, "Suggested quotas (tap to review + save):", colors.cyan)
  local start = 10
  local rows = math.min(#sugg, math.max(0, h - start - 1))
  local kindTag = { quota = "STOCK", raise = "RAISE", cap = "CAP", compress = "COMPRESS" }
  for i = 1, rows do
    local s = sugg[i]
    local y = start + (i - 1)
    local detail
    if s.kind == "cap" then detail = "cap " .. fmt(s.ceiling)
    elseif s.kind == "compress" then detail = "band " .. fmt(s.target) .. "-" .. fmt(s.ceiling) .. ", set INTO"
    else detail = "keep " .. fmt(s.target) .. "/" .. fmt(s.craftTo) end
    -- append a compact rate + confidence hint so the operator can judge how strongly the
    -- suggestion is observed (conf) and the rate they're being asked to keep up with (perMin).
    local reason = tostring(s.reason)
    if s.perMin and s.perMin > 0 then reason = reason .. ", ~" .. fmt(math.floor(s.perMin)) .. "/min" end
    local cl = suggest.confLabel(s.conf)
    if cl then reason = reason .. ", conf " .. cl end
    if s.spiky then reason = reason .. ", spiky" end
    line(y, uiDraw.fit("[" .. (kindTag[s.kind] or "?") .. "] " .. s.label .. " -> " .. detail ..
      "  (" .. reason .. ")", w), colors.white)
    smartRowRegions[#smartRowRegions + 1] = { y = y, entry = s }
  end
  line(h, flashing and ui.flashMsg or "Tapping opens the editor pre-filled; SAVE to apply.",
    flashing and colors.white or colors.gray)
end

-- Global reboot-safety chip: tells the operator, on every page, whether detaching
-- this computer now (reboot / shutdown / update) is safe or would risk the AP
-- craft-job server crash. Mirrors control.rebootSafety / the `safereboot` command.
local function rebootChip()
  local crafting = 0
  for _, e in ipairs(cqueue.list(craftQueue or cqueue.new())) do
    if e.state == cqueue.CRAFTING then crafting = crafting + 1 end
  end
  local v = control.rebootSafety({ now = nowMs(), lastCraftAt = lastCraftAt, crafting = crafting })
  if v.safe then return "reboot ok", colors.gray end
  return "DO NOT REBOOT" .. (v.secondsLeft and (" " .. v.secondsLeft .. "s") or ""), colors.red
end

-- HEALTH page (MON-1): "is it functioning, and is it keeping up?" Derives from the
-- atm10-monitor lib over the existing queue/results/trend snapshots. Read-only; the
-- monitor lib is required defensively + named `monlib` so it never shadows the
-- `monitor` PERIPHERAL. Internal helpers stay function-local (manager locals cap).
local function drawHealthPage(data)
  local w, h = monitor.getSize()
  local ok, monlib = pcall(require, "atm10-monitor")
  if not ok or not monlib then
    line(6, "atm10-monitor not deployed -- run `update`.", colors.orange)
    return
  end
  local now = nowMs()

  -- FUNCTIONING --------------------------------------------------------------
  local ch = monlib.craft(data.craftQueue, craftResults, #firedTimes, now, {})
  local btxt, bcol = "ONLINE", colors.lime
  if data.online == false then
    btxt, bcol = "OFFLINE", colors.red
  elseif craftingCache.__bridge and craftingCache.__bridge.allowFire == false then
    btxt, bcol = "HELD (bridge degraded)", colors.red
  end
  line(6, "SYSTEM HEALTH", colors.cyan)
  mwrite(1, 7, "Bridge: ", colors.gray)
  mwrite(9, 7, btxt, bcol)
  line(8, "Crafts: " .. ch.ratePerMin .. "/min   " .. ch.inFlight .. " in-flight" ..
    (#ch.stuck > 0 and ("   " .. #ch.stuck .. " STUCK") or ""),
    #ch.stuck > 0 and colors.orange or colors.white)
  line(9, "Recent: " .. ch.recentOk .. " ok   " .. ch.recentFail .. " failed (30m)",
    ch.recentFail > 0 and colors.orange or colors.gray)

  local function eta(m)
    if not m or m <= 0 then return "" end
    if m >= 120 then return "  ~" .. math.floor(m / 60) .. "h" end
    return "  ~" .. math.floor(m) .. "m"
  end
  local function row(r)
    return "  " .. uiDraw.fit(tostring(r.label), 16) .. " v" .. fmt(math.floor(r.perMin)) .. "/min" .. eta(r.etaMin)
  end

  local y = 11
  if #ch.stuck > 0 then
    line(y, "STUCK JOBS (" .. #ch.stuck .. "):", colors.red); y = y + 1
    for i = 1, math.min(#ch.stuck, 3) do
      line(y, "  " .. uiDraw.fit(tostring(ch.stuck[i].label), 18) .. " " .. math.floor(ch.stuck[i].ageMin) .. "m", colors.red)
      y = y + 1
    end
    y = y + 1
  end

  -- KEEPING UP ---------------------------------------------------------------
  if next(trendHistory) == nil then
    line(y, "Enable Smart mode (SMART tab) to track demand.", colors.gray)
    return
  end
  local craftable = {}
  for _, p in ipairs(data.stockPlans or {}) do
    if p.name then craftable[p.name] = (p.action ~= "NOT CRAFTABLE") end
  end
  local dm = monlib.demand(trendHistory, craftable, { top = 5 })

  line(y, "FALLING BEHIND (crafting can't keep up):", colors.orange); y = y + 1
  if #dm.fallingBehind == 0 then
    line(y, "  none -- managed items holding", colors.lime); y = y + 1
  else
    for _, r in ipairs(dm.fallingBehind) do line(y, row(r), colors.orange); y = y + 1 end
  end
  y = y + 1
  line(y, "SOURCE MORE (mine/farm -- inputs draining):", colors.yellow); y = y + 1
  if #dm.sourceMore == 0 then
    line(y, "  none flagged", colors.gray); y = y + 1
  else
    for _, r in ipairs(dm.sourceMore) do line(y, row(r), colors.yellow); y = y + 1 end
  end
end

local function draw(data)
  if not monitor then return end

  if not data then
    drawWaiting(status)
    return
  end

  -- B1: draw into a fresh frame buffer (line()/mwrite() target it); diff-rendered at
  -- the end of this function instead of a whole-screen monitor.clear() flash.
  local rw, rh = monitor.getSize()
  ui.frame = uiDraw.newBuffer(rw, rh)
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

  line(1, TITLE .. "  " .. pageName, colors.black, colors.cyan)

  -- tappable tab strip (right-click a tab to switch pages). Use short labels when
  -- the full strip would run off this monitor, so SMART is never cut off/untappable.
  local tabW = select(1, monitor.getSize())
  tabStrip = console.tabs(PAGES, 2)
  if (tabStrip.tabs[#tabStrip.tabs] and tabStrip.tabs[#tabStrip.tabs].x2 or 0) > tabW then
    tabStrip = console.tabs(PAGES_SHORT, 2)
  end
  -- active tab is highlighted (inverted) so "you are here" + tap targets are clear
  for _, tab in ipairs(tabStrip.tabs) do
    local active = tab.page == pageIndex
    mwrite(tab.x1, tabStrip.y, "[" .. tab.label .. "]",
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
    local chip = "[ " .. mode .. (ui.modeConfirm == control.MODE_AUTO and " AUTO?" or "") .. " ]"
    local modeBg = colors.cyan
    if ui.modeConfirm == control.MODE_AUTO then modeBg = colors.orange
    elseif mode == control.MODE_AUTO then modeBg = colors.lime
    elseif mode == control.MODE_DRY_RUN then modeBg = colors.yellow
    elseif mode == control.MODE_MONITOR then modeBg = colors.gray end
    mwrite(1, 4, chip, colors.black, modeBg)
    modeChip = { x1 = 1, x2 = #chip, y = 4 }
    local x = #chip + 2
    local craftChip = craftLive and "[CRAFT ON]" or "[CRAFT off]"
    mwrite(x, 4, craftChip, craftLive and colors.black or colors.lightGray,
      craftLive and colors.lime or colors.black)
    x = x + #craftChip + 1
    if data.bridgeDegraded then
      local held = "[BRIDGE HELD]"
      mwrite(x, 4, held, colors.black, colors.orange)
      x = x + #held + 1
    end
    mwrite(x, 4, "Queue: " .. cqueue.count(craftQueue), colors.gray, colors.black)
    -- right-aligned reboot-safety chip (warns before a detach that could crash the
    -- server); only drawn when the monitor is wide enough to avoid clobbering above
    local rbText, rbColor = rebootChip()
    local rbx = tabW - #rbText + 1
    if rbx > x + 12 then
      mwrite(rbx, 4, rbText, rbText == "reboot ok" and colors.lightGray or colors.black,
        rbText == "reboot ok" and colors.black or rbColor)
    end
  end

  -- the quota editor is a modal: it renders over any tab when open (unless we're
  -- picking a compress target, which needs the grid list)
  if editing and not editing.pickingInto then
    drawEditor()
  elseif editing and editing.pickingInto then
    drawBrowsePage(data)
  elseif pageName == "QUEUE" then
    drawQueuePage(data)
  elseif pageName == "HEALTH" then
    drawHealthPage(data)
  elseif pageName == "BROWSE" then
    drawBrowsePage(data)
  elseif pageName == "PRESETS" then
    drawPresetsPage(data)
  elseif pageName == "SMART" then
    drawSmartPage(data)
  else
    drawPlanPage(data)
  end

  -- B1: flush the frame -- diff-render only the changed rows (no clear() flash).
  ui.prevFrame = uiDraw.renderBuffer(monitor, ui.frame, ui.prevFrame)
  ui.frame = nil
end

local function setPage(i)
  pageIndex = ((i - 1) % #PAGES) + 1
  editing = nil -- any page change exits the quota editor
  ui.modeConfirm = nil -- and cancels a pending auto-mode confirm
  ui.pageShownAt = nowMs() -- a manual page change resets the auto-rotate timer
end

-- Only the dashboard pages auto-rotate; Browse/Presets are interactive and held.
local AUTO_PAGES = { PLAN = true, QUEUE = true, HEALTH = true }

local function advancePageIfDue()
  if PAGE_SECONDS <= 0 then return end -- auto-rotation disabled
  local nowT = nowMs()
  if not ui.pageShownAt then ui.pageShownAt = nowT end
  if not AUTO_PAGES[PAGES[pageIndex]] then
    ui.pageShownAt = nowT -- manual page: don't auto-rotate away
    return
  end
  if console.autoRotateDue(PAGES[pageIndex], AUTO_PAGES, ui.pageShownAt, ui.lastInteractionAt, nowT, PAGE_SECONDS) then
    local nextIndex = pageIndex
    for _ = 1, #PAGES do
      nextIndex = nextIndex % #PAGES + 1
      if AUTO_PAGES[PAGES[nextIndex]] then break end
    end
    pageIndex = nextIndex
    ui.pageShownAt = nowT
  end
end

local function renderCurrent()
  local ok, err = pcall(draw, lastData)
  if not ok then
    print("render error: " .. tostring(err))
    monitor = nil
    paletteApplied = false
    ui.prevFrame = nil
    ui.frame = nil
  end
end

-- Approve a planned/selected craft into the queue. The gated craft runner issues
-- the actual request on a later cycle, and only if mode + capability + approval
-- all pass; approving here never crafts directly.
local function approve(entry)
  if not entry or not entry.name then return end
  craftQueue = cqueue.approve(craftQueue or loadQueue(),
    -- CRAFT-5: carry `kind` so a single-tapped compress row stays a compress entry. Without
    -- it copyPlanFields queues kind=nil and the runner's overflow reserve never protects it
    -- (manual single-tap is the primary approval flow; the auto/bulk paths pass the plan row
    -- directly and already preserve kind).
    { name = entry.name, label = entry.label, request = entry.request, key = entry.key, kind = entry.kind,
      priority = entry.priority, amount = entry.amount, target = entry.target, category = entry.category,
      craftTo = entry.craftTo, banded = entry.banded, adjusted = entry.adjusted, reason = entry.reason }, nowMs())
  saveQueue(craftQueue)
  ui.pageShownAt = nowMs()
  ui.flashMsg = "+ Approved " .. tostring(entry.label or entry.name); ui.flashAt = nowMs()
  print("Approved: " .. tostring(entry.label or entry.name) .. " x" .. tostring(entry.request))
end

-- Cancel a queued approval. Removes intent only; the runner crafts at most once
-- per approval, so a canceled-but-already-requested item just stops being shown.
local function cancelEntry(entry)
  if not entry or not entry.name then return end
  craftQueue = cqueue.cancel(craftQueue or loadQueue(), entry.key or entry.name)
  saveQueue(craftQueue)
  ui.pageShownAt = nowMs()
  ui.flashMsg = "x Canceled " .. tostring(entry.label or entry.name); ui.flashAt = nowMs()
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
  ui.pageShownAt = nowMs()
  ui.flashMsg = "+ Approved all (" .. n .. ")"; ui.flashAt = nowMs()
  print("Approved all WOULD CRAFT: " .. n)
end

-- Bulk cancel: clear every approval at once. Removes intent only (an item already
-- requested keeps crafting in RS); the runner fires at most once per approval.
local function clearQueue()
  craftQueue = cqueue.new()
  saveQueue(craftQueue)
  ui.pageShownAt = nowMs()
  ui.flashMsg = "x Queue cleared"; ui.flashAt = nowMs()
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
  ui.pageShownAt = nowMs()
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
  ui.flashMsg = "+ Saved " .. tostring(editing.label); ui.flashAt = nowMs()
  editing = nil
end

local function removeEditing()
  local removedLabel = editing.label
  managedStore = managed.remove(managedStore or loadManaged(), editing.name)
  saveManaged(managedStore)
  print("Quota removed: " .. tostring(removedLabel))
  ui.flashMsg = "x Removed " .. tostring(removedLabel); ui.flashAt = nowMs()
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
  if settings.compressChains then
    managed.setSetting(managedStore, "compressChains", true)
    extra = extra .. " + compress chains ON"
  end
  saveManaged(managedStore)
  ui.presetStatus = "Applied " .. tostring(p.label) .. ": " .. n .. " quotas." .. extra
  ui.flashMsg = "+ Applied " .. tostring(p.label); ui.flashAt = nowMs()
  ui.pageShownAt = nowMs()
  print("Applied preset " .. tostring(p.label) .. " (" .. n .. " quotas)" .. extra)
end

-- Toggle smart mode on/off (persisted on the managed store).
local function toggleSmart()
  managedStore = managedStore or loadManaged()
  local on = not (managed.getSetting(managedStore, "smartMode") == true)
  managed.setSetting(managedStore, "smartMode", on)
  saveManaged(managedStore)
  ui.flashMsg = on and "+ Smart mode ON" or "x Smart mode off"; ui.flashAt = nowMs()
  ui.pageShownAt = nowMs()
  print("Smart mode " .. (on and "ENABLED" or "disabled"))
end

-- Touch handling while the quota editor is open.
local function handleEditorTouch(x, y)
  -- tabs still navigate (and exit the editor)
  local page = console.tabHit(tabStrip, x, y, 1)
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
      ui.pageShownAt = nowMs()
      renderCurrent()
      return
    end
  end
end

-- Touch handling while picking a compress-into target from the Browse grid.
local function handlePickIntoTouch(x, y)
  local page = console.tabHit(tabStrip, x, y, 1)
  if page then setPage(page); renderCurrent(); return end -- tab cancels the whole edit

  for _, nav in ipairs(browseNavRegions) do
    if y == nav.y and x >= nav.x1 and x <= nav.x2 then
      browsePage = math.max(1, browsePage + nav.delta)
      ui.pageShownAt = nowMs(); renderCurrent(); return
    end
  end

  local pick = console.rowHit(browseRowRegions, y, 1)
  if pick then
    editing.into = { name = pick.name, label = pick.label }
    editing.pickingInto = false
    if editing.ceiling <= 0 then editing.ceiling = math.max(0, math.floor(editing.amount or 0)) end
    ui.pageShownAt = nowMs()
    renderCurrent()
  end
end

local function handleTouch(x, y)
  ui.lastInteractionAt = nowMs()
  if editing and editing.pickingInto then
    handlePickIntoTouch(x, y)
    return
  end
  if editing then
    handleEditorTouch(x, y)
    return
  end

  -- any tap clears the auto-mode arm; only a consecutive chip tap re-confirms it
  local autoArmed = (ui.modeConfirm == control.MODE_AUTO)
  ui.modeConfirm = nil

  -- header mode chip: cycle the control mode (available on every page)
  if modeChip and y == modeChip.y and x >= modeChip.x1 and x <= modeChip.x2 then
    cycleMode(autoArmed)
    renderCurrent()
    return
  end

  local page = console.tabHit(tabStrip, x, y, 1)
  if page then
    setPage(page)
    renderCurrent()
    return
  end

  -- Plan page: [< PREV] / [NEXT >] paging, then tap a WOULD CRAFT row to approve
  for _, nav in ipairs(planNavRegions) do
    if y == nav.y and x >= nav.x1 and x <= nav.x2 then
      planPage = math.max(1, planPage + nav.delta)
      ui.pageShownAt = nowMs()
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

  local planEntry = console.rowHit(planRowRegions, y, 1)
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

  local queueEntry = console.rowHit(queueRowRegions, y, 1)
  if queueEntry then
    cancelEntry(queueEntry)
    renderCurrent()
    return
  end

  local presetEntry = console.rowHit(presetRowRegions, y, 1)
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
    local clearedAt = nowMs()
    for _, s in ipairs((lastData and lastData.suggestions) or {}) do
      -- CRAFT-6: record the drain rate at dismissal so analyze can re-surface this item if its
      -- drain later materially accelerates (legacy bare-timestamp entries never re-surface).
      if s.name then dismissedSuggestions[s.name] = { ts = clearedAt, baseline = tonumber(s.perMin) or 0 } end
    end
    dismissedSuggestions = suggest.pruneDismissed(dismissedSuggestions, clearedAt, DISMISSED_OPTS)
    saveDismissed(dismissedSuggestions)
    ui.pageShownAt = nowMs()
    renderCurrent()
    return
  end
  local smartEntry = console.rowHit(smartRowRegions, y, 1)
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
    ui.pageShownAt = nowMs()
    renderCurrent()
    return
  end
  for _, nav in ipairs(browseNavRegions) do
    if y == nav.y and x >= nav.x1 and x <= nav.x2 then
      browsePage = math.max(1, browsePage + nav.delta)
      ui.pageShownAt = nowMs()
      renderCurrent()
      return
    end
  end

  local browseEntry = console.rowHit(browseRowRegions, y, 1)
  if browseEntry then
    openEditor(browseEntry)
    renderCurrent()
    return
  end

  -- Nothing matched: flash the tap's coords so a "dead" tap is VISIBLE (taps on this
  -- monitor are finicky; this shows exactly where a miss landed, to tune targets).
  ui.flashMsg = "tap " .. x .. "," .. y .. " - no target"
  ui.flashAt = nowMs()
  renderCurrent()
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
      -- A3 bridge-degraded back-off: when consecutive bridge-read failures have
      -- crossed the threshold, SKIP the whole craft phase this cycle. A flaky
      -- bridge intermittently answering reads is the half-attached state in which
      -- the mutating craftItem is the uncatchable AP crash trigger; holding it
      -- back is the core reliability win. We still hold the last-good display.
      -- gateCrafts uses RECOVERY HYSTERESIS: after a degraded window the gate stays
      -- held until recoverCycles consecutive clean scans, so craft-firing does not
      -- resume on the bridge's first (still-settling) clean read -- it auto-resumes
      -- once the bridge has been stably clean (no manual clear).
      if craftingCache.__bridge and craftingCache.__bridge.allowFire == false then
        data.bridgeDegraded = true -- for the (pinned, in-game-visual) header chip
      else
        -- in auto mode, enqueue craftable deficits so the runner can maintain quotas
        -- unattended; a no-op in monitor/dry-run/manual (those need a manual tap)
        autoApprovePlans(data.stockPlans)
        -- drive the gated craft runner, then refresh the queue snapshot so the page
        -- reflects this cycle's state transitions (APPROVED -> CRAFTING) immediately
        processCraftQueue(nowMs())
      end
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
    status = tostring(data)
    if craftingCache.__health and craftingCache.__bridge then
      craftingCache.__bridge.allowFire = craftingCache.__health.gateCrafts(craftingCache.__bridge, false)
    end
    if lastData then
      lastData.stale = "Scan error - holding last plan: " .. status
      lastData.bridgeDegraded = true
    else
      lastData = nil
    end
  end
  renderCurrent()
end

-- Every loop step is guarded: an event/control error must NOT freeze the console.
-- Only display/peripheral-sensitive callers ask to drop the monitor handle; render
-- failures are handled inside renderCurrent(), where the failing surface is known.
local function guard(fn, ...)
  local resetDisplay = false
  if type(fn) == "table" then
    resetDisplay = fn.resetDisplay == true
    fn = fn[1]
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    print("loop error: " .. tostring(err))
    if resetDisplay then
      monitor = nil
      paletteApplied = false
      ui.prevFrame = nil
      ui.frame = nil
    end
  end
end

-- Boot: resolve any leftover .tmp from a crashed atomicWrite -- discard orphans whose
-- main file survived, recover a tmp whose main file is gone. Without this, a rarely-
-- written file's orphan lingers on the ~1MB disk until that file's next write. Own
-- do-scope (no new top-level local; manager is at the locals cap) + defensive require
-- so a missing atm10-health can't block startup.
do
  local ok, hmod = pcall(require, "atm10-health")
  if ok and hmod and hmod.sweepTmps then
    hmod.sweepTmps(fs, { FILES.queue, FILES.managed, FILES.trends, FILES.dismissed, FILES.ledger, CRAFT_RESULTS.file })
  end
end

-- TOUCH-DECOUPLE: the heavy RS scan (refreshAndDraw -> bridge.getItems over a huge
-- network) blocks the single CC thread; in a single os.pullEvent loop, a tap arriving
-- mid-scan is dead until the scan returns. Split into two coroutines via
-- parallel.waitForAny: the scan/render loop sleeps between scans (yielding the thread),
-- and an independent input loop services monitor_touch/redstone/resize/control the
-- whole time -- including WHILE the scan is parked inside getItems (which yields
-- internally, so CC keeps the input coroutine responsive). Behavior of every handler
-- is unchanged; only the dispatch is decoupled. (`parallel` is a CC global; the
-- off-CC smokes stub it.) No new top-level locals -- both loops are anonymous.
parallel.waitForAny(
  function()
    -- scan/render loop: refresh FIRST, then sleep the operator-tunable interval
    -- (config.refreshSeconds, falling back to the constant before first load). A
    -- completed refresh pings the watchdog -- a hang inside refreshAndDraw stops the
    -- pings, and the startup watchdog restarts us.
    while true do
      guard(advancePageIfDue)
      guard({ refreshAndDraw, resetDisplay = true })
      writeHeartbeat(nowMs())
      sleep((config and config.refreshSeconds) or REFRESH_SECONDS)
    end
  end,
  function()
    -- input loop: services taps/redstone/resize/control independently of the scan,
    -- so a tap during a scan is handled the moment the scan yields, not after it
    -- returns. Every dispatch is guarded so a malformed event can't freeze the loop.
    while true do
      local ev = { os.pullEvent() }
      local kind = ev[1]
      if kind == "monitor_touch" then
        guard(handleTouch, ev[3], ev[4])
      elseif kind == "redstone" then
        guard(handleRedstone)
      elseif kind == "monitor_resize" then
        guard({ function()
          if monitor then pickTextScale() end
          renderCurrent()
        end, resetDisplay = true })
      elseif kind == "rednet_message" and ev[4] == control.PROTOCOL then
        -- CTRL-3: inbound control command (off unless config.controlEnabled).
        guard(handleControlMessage, ev[2], ev[3])
      end
    end
  end
)
