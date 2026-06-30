local TITLE = "ATM10 INVENTORY REMOTE"
local MONITOR_SIDE = "auto"
local MODEM_SIDE = "auto"
local TEXT_SCALE = "auto"
local PROTOCOL = "atm10-inventory-v1"
local STALE_SECONDS = 15

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")
local console = require("atm10-console")

-- Which screen this viewer shows: view (inventory) / autocraft / alerts.
-- Set per computer in a one-line `atm10-display` file; defaults to "view".
local PROFILE = console.resolveProfile()

local monitor = nil
local last = nil
local lastSeen = nil
local modemsOpen = false
local paletteApplied = false
local viewPage = 1     -- VIEW-2: current page of the paginated stored-items list
local viewNavRow = nil -- VIEW-2: [< PREV]/[NEXT >]/[SORT] button row, rebuilt each draw
local viewSort = "qty" -- VIEW-3: current sort mode (qty / az / mod)
local viewFilter = ""   -- VIEW-4: keyboard-free filter chip state
local viewFilterRow = nil
local viewRowRegions = {}
local viewSelected = nil -- VIEW-6: read-only detail card selection
local frame = nil      -- UI-1: current render buffer (set during present())
local prevFrame = nil  -- UI-1: last rendered buffer, for diff (flicker-free redraw)

local MIN_WIDTH = 42
local MIN_HEIGHT = 18
local VIEW_FILTERS = {
  { label = "ALL", key = "" },
  { label = "A-F", key = "range:a:f" },
  { label = "G-L", key = "range:g:l" },
  { label = "M-R", key = "range:m:r" },
  { label = "S-Z", key = "range:s:z" },
  { label = "DUST", key = "dust" },
  { label = "ESS", key = "essence" },
}

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

local function openModems()
  if modemsOpen then return end

  if MODEM_SIDE ~= "auto" then
    if peripheralTypeMatches(peripheral.getType(MODEM_SIDE), "modem") then
      rednet.open(MODEM_SIDE)
      modemsOpen = true
    end
    return
  end

  for _, side in ipairs(rs.getSides()) do
    if peripheralTypeMatches(peripheral.getType(side), "modem") then
      rednet.open(side)
      modemsOpen = true
    end
  end
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

local function fmt(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1000000000000 then return string.format("%.2fT", n / 1000000000000) end
  if a >= 1000000000 then return string.format("%.2fG", n / 1000000000) end
  if a >= 1000000 then return string.format("%.2fM", n / 1000000) end
  if a >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
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

local function summaryValue(summary, key, oldKey)
  return summary[key] or (oldKey and summary[oldKey]) or 0
end

local function formatCategorySummary(summary, width)
  local text = tostring(summary.label or "?") ..
    ": +" .. fmt(summaryValue(summary, "ok")) ..
    " >" .. fmt(summaryValue(summary, "would", "action")) ..
    " ~" .. fmt(summaryValue(summary, "crafting")) ..
    " ." .. fmt(summaryValue(summary, "cooldown", "waiting")) ..
    " x" .. fmt(summaryValue(summary, "noRecipe")) ..
    " #" .. fmt(summaryValue(summary, "blocked"))

  return uiDraw.fit(text, width)
end

local function categorySummaryStatus(summary)
  if summaryValue(summary, "noRecipe") > 0 then return uiStatus.NO_RECIPE end
  if summaryValue(summary, "blocked") > 0 then return uiStatus.BLOCKED end
  if summaryValue(summary, "would", "action") > 0 then return uiStatus.WOULD end
  if summaryValue(summary, "crafting") > 0 then return uiStatus.CRAFTING end
  if summaryValue(summary, "cooldown", "waiting") > 0 then return uiStatus.COOLDOWN end
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

local function pct(used, total)
  used = tonumber(used) or 0
  total = tonumber(total) or 0
  if total <= 0 then return 0 end
  return math.max(0, math.min(100, (used / total) * 100))
end

local function colorForPercent(value)
  if value >= 90 then return colors.red end
  if value >= 75 then return colors.orange end
  if value >= 50 then return colors.yellow end
  return colors.lime
end

-- UI-1: write through the frame buffer when one is active (the flicker-free path),
-- else straight to the monitor (defensive fallback).
local function line(y, text, color, bg)
  if frame then
    uiDraw.bufferWrite(frame, 1, y, uiDraw.fit(text, frame.width), color or colors.white, bg or colors.black)
  else
    uiDraw.line(monitor, y, text, color or colors.white, bg or colors.black)
  end
end

local function writeAt(x, y, text, color, bg)
  if frame then
    uiDraw.bufferWrite(frame, x, y, text, color or colors.white, bg or colors.black)
  else
    uiDraw.write(monitor, x, y, text, color or colors.white, bg or colors.black)
  end
end

local function drawPanel(title, lines, y, height, fg)
  local w = frame and frame.width or monitor.getSize()
  local panelW = math.min(w, math.max(28, math.min(54, w - 2)))
  local panelH = math.max(3, height or (#(lines or {}) + 2))
  panelH = math.min(panelH, (frame and frame.height or select(2, monitor.getSize())) - y + 1)
  if panelH < 3 then return end
  local x = math.max(1, math.floor((w - panelW) / 2) + 1)
  uiDraw.box(frame or monitor, x, y, panelW, panelH, title, fg or colors.cyan, colors.black)
  for i, text in ipairs(lines or {}) do
    if i > panelH - 2 then break end
    writeAt(x + 2, y + i, uiDraw.fit(text, panelW - 4), colors.white, colors.black)
  end
end

local function drawGauge(x, y, width, used, total)
  local p = pct(used, total)
  local gaugeWidth = math.max(8, math.min(width, 24))
  uiDraw.gauge(frame or monitor, x, y, gaugeWidth, p, colorForPercent(p))
  writeAt(x + gaugeWidth + 1, y, string.format("%3.0f%%", p), colors.white, colors.black)
end

local function itemFilterKey(item)
  local text = tostring((item and (item.name or item.id)) or ""):lower()
  return text:match("^[^:]+:(.+)$") or text
end

local function filterLabel()
  if not viewFilter or viewFilter == "" then return "all" end
  if viewFilter:match("^range:") then return viewFilter:sub(7):upper():gsub(":", "-") end
  return viewFilter
end

local function filteredViewItems(items)
  if not viewFilter or viewFilter == "" then return console.filterItems(items, "") end
  local first, last = viewFilter:match("^range:([a-z]):([a-z])$")
  if not first then return console.filterItems(items, viewFilter) end
  local out = {}
  for _, item in ipairs(items or {}) do
    local ch = itemFilterKey(item):sub(1, 1)
    if ch >= first and ch <= last then out[#out + 1] = item end
  end
  return out
end

local function drawItemDetail(item, y, w)
  if not item or y < 1 then return end
  uiDraw.box(frame or monitor, 1, y, w, 4, "Item Detail", colors.cyan, colors.black)
  local label = tostring(item.name or item.id or "?")
  local amount = "count " .. fmt(item.amount)
  writeAt(3, y + 1, uiDraw.fit(label, math.max(8, w - #amount - 7)), colors.white, colors.black)
  writeAt(math.max(3, w - #amount - 2), y + 1, amount, colors.lime, colors.black)
  local trend = ""
  if type(item.trend) == "table" then
    local arrow = (item.trend.dir == "up" and "^") or (item.trend.dir == "down" and "v") or "-"
    trend = "   trend " .. arrow .. fmt(math.abs(item.trend.perMin or 0)) .. "/m"
  end
  writeAt(3, y + 2, uiDraw.fit("id " .. tostring(item.id or item.name or "?") .. trend, w - 4), colors.gray, colors.black)
end

-- UI-1: render a frame through the diff double-buffer. The renderFn draws via
-- line()/writeAt() into `frame`; renderBuffer rewrites only the rows that changed
-- (blit), so there is no whole-screen monitor.clear flash between frames.
local function present(renderFn)
  if not monitor then return end
  local w, h = monitor.getSize()
  frame = uiDraw.newBuffer(w, h)
  renderFn(w, h)
  prevFrame = uiDraw.renderBuffer(monitor, frame, prevFrame)
  frame = nil
end

local function drawWaiting(message)
  present(function(_, h)
    line(1, TITLE, colors.cyan)
    local panelY = math.max(3, math.floor((h - 4) / 2))
    drawPanel("Waiting", {
      message,
      "Protocol: " .. PROTOCOL,
    }, panelY, 4, colors.yellow)
  end)
end

-- VIEW profile: the inventory viewer (storage, RS energy, top stored items).
local function drawView(data)
  local w, h = monitor.getSize()
  line(4, "Managed: " .. fmt(data.managedItemCount) .. "   Listed: " .. fmt(data.listedItemCount) ..
    "   Default: " .. tostring(data.defaultHandling or "unmanaged"), colors.gray)

  local headerY = 11
  if data.usedItemStorage and data.totalItemStorage then
    -- QUICK-6: surface free headroom alongside used/total
    local free = data.availableItemStorage or (data.totalItemStorage - data.usedItemStorage)
    if w >= 70 then
      local boxW = math.floor((w - 3) / 2)
      uiDraw.box(frame or monitor, 1, 5, boxW, 4, "Storage", colors.cyan, colors.black)
      writeAt(3, 6, uiDraw.fit(fmt(data.usedItemStorage) .. " / " .. fmt(data.totalItemStorage), boxW - 4), colors.white)
      writeAt(3, 7, uiDraw.fit("free " .. fmt(free), math.max(6, boxW - 32)), colors.gray)
      drawGauge(math.max(3, boxW - 27), 7, 18, data.usedItemStorage, data.totalItemStorage)
    else
      uiDraw.box(frame or monitor, 1, 5, w, 3, "Storage", colors.cyan, colors.black)
      writeAt(3, 6, uiDraw.fit(fmt(data.usedItemStorage) .. " / " .. fmt(data.totalItemStorage) ..
        " free " .. fmt(free), math.max(8, w - 30)), colors.white)
      drawGauge(math.max(3, w - 27), 6, 16, data.usedItemStorage, data.totalItemStorage)
      headerY = 12
    end
  else
    -- QUICK-6: fallback so the section never degrades to a single gray line when the disk
    -- capacity API is unavailable -- show what we DO know (unique type count + total count)
    uiDraw.box(frame or monitor, 1, 5, w >= 70 and math.floor((w - 3) / 2) or w, 3, "Storage", colors.cyan, colors.black)
    writeAt(3, 6, uiDraw.fit(fmt(data.unique or data.listedItemCount or 0) .. " types   " ..
      fmt(data.totalAmount or 0) .. " items", (w >= 70 and math.floor((w - 3) / 2) or w) - 4), colors.white)
  end

  local energyX = (w >= 70) and (math.floor((w - 3) / 2) + 3) or 1
  local energyY = (w >= 70) and 5 or 8
  local energyW = (w >= 70) and (w - energyX + 1) or w
  uiDraw.box(frame or monitor, energyX, energyY, energyW, 3, "Energy", colors.cyan, colors.black)
  if data.storedEnergy and data.energyCapacity then
    writeAt(energyX + 2, energyY + 1,
      uiDraw.fit(fmt(data.storedEnergy) .. " / " .. fmt(data.energyCapacity) .. " FE", math.max(8, energyW - 30)),
      colors.white)
    drawGauge(math.max(energyX + 2, energyX + energyW - 27), energyY + 1, 16,
      data.storedEnergy, data.energyCapacity)
  else
    writeAt(energyX + 2, energyY + 1, uiDraw.fit("No energy capacity in snapshot", energyW - 4), colors.gray)
  end
  if data.energyUsage then
    writeAt(energyX + 2, energyY + 2, uiDraw.fit("Usage " .. fmt(data.energyUsage) .. " FE/t", energyW - 4), colors.gray)
  end

  -- VIEW-2: paginated, touch-scrollable stored-items list (consumes VIEW-1's bounded
  -- viewItems; falls back to the 8-item summary if an older source is broadcasting).
  local sourceItems = data.viewItems or data.topItems or {}
  local items = filteredViewItems(sourceItems)
  console.sortItems(items, viewSort) -- VIEW-3: re-sort per the tappable sort chip
  local navY = h
  local filterY = headerY + 1
  local listStart = filterY + 1
  local detailTop = viewSelected and math.max(listStart + 1, h - 4) or nil
  local listEnd = detailTop and (detailTop - 1) or (navY - 1)
  local perPage = math.max(1, listEnd - listStart + 1)
  local pg = console.paginate(#items, perPage, viewPage)
  viewPage = pg.page
  line(headerY, "Stored Items   " .. #items .. "/" .. #sourceItems .. " shown   page " ..
    pg.page .. "/" .. pg.pages .. "   sort:" .. console.sortLabel(viewSort) ..
    "   filter:" .. filterLabel(), colors.cyan)
  viewFilterRow = console.buttonRow(VIEW_FILTERS, filterY, 1)
  for _, b in ipairs(viewFilterRow.buttons) do
    local active = b.key == (viewFilter or "")
    writeAt(b.x1, b.y, b.text, active and colors.black or colors.cyan, active and colors.cyan or colors.black)
  end
  -- QUICK-6: magnitude bar per row, scaled to the largest amount in the list (the #1), so
  -- quantities are scannable at a glance. Monochrome uiDraw.barText fits the single-color
  -- line(); shown only when the monitor is wide enough, else the row degrades to name+amount.
  local maxAmt = 0
  for _, it in ipairs(items) do local a = tonumber(it.amount) or 0; if a > maxAmt then maxAmt = a end end
  viewRowRegions = {}
  if #items == 0 then
    drawPanel("No Items", {
      "No items match filter: " .. filterLabel(),
      "Tap ALL or another filter chip.",
    }, listStart + 1, math.min(5, math.max(3, navY - listStart - 1)), colors.gray)
  else
    for i = pg.from, pg.to do
      local item = items[i]
      if item then
        local y = listStart + (i - pg.from)
        -- VIEW-5: per-item trend arrow + per-min rate (hidden when no trend data)
        local trend = ""
        if type(item.trend) == "table" then
          local arrow = (item.trend.dir == "up" and "^") or (item.trend.dir == "down" and "v") or "-"
          trend = " " .. rjust(arrow .. fmt(math.abs(item.trend.perMin or 0)) .. "/m", 8)
        end
        local mag = ""
        if w >= 50 and maxAmt > 0 then
          mag = " " .. uiDraw.barText((tonumber(item.amount) or 0) / maxAmt * 100, 6)
        end
        local nameW = (mag ~= "") and math.max(6, w - 34) or math.max(8, w - 27)
        local bg = ((i - pg.from) % 2 == 1) and colors.gray or colors.black
        line(y, rjust(i, 4) .. ". " .. uiDraw.fit(tostring(item.name), nameW) ..
          mag .. "  " .. rjust(fmt(item.amount), 10) .. trend, colors.white, bg)
        viewRowRegions[#viewRowRegions + 1] = { y = y, entry = item }
      end
    end
  end
  if viewSelected and detailTop then drawItemDetail(viewSelected, detailTop, w) end
  -- nav row (reuses the tested console.buttonRow / buttonHit)
  viewNavRow = console.buttonRow({
    { label = "< PREV", key = "prev" },
    { label = "NEXT >", key = "next" },
    { label = "SORT:" .. console.sortLabel(viewSort), key = "sort" },
  }, navY, 1)
  for _, b in ipairs(viewNavRow.buttons) do
    local enabled = (b.key == "prev" and pg.page > 1) or (b.key == "next" and pg.page < pg.pages) or (b.key == "sort")
    writeAt(b.x1, navY, b.text, enabled and colors.cyan or colors.gray, colors.black)
  end
end

-- AUTOCRAFT profile: category summary, stock plan, tally, and the craft queue.
local function drawAutocraft(data)
  local w, h = monitor.getSize()
  line(4, "Mode: " .. tostring(data.configMode or "manual") ..
    (data.configError and ("   " .. data.configError) or ""),
    data.configError and colors.orange or colors.gray)

  line(5, "Category  + ok > would ~ craft . wait x recipe # block", colors.cyan)
  local summaries = data.categorySummaries or {}
  local sRows = math.min(4, #summaries)
  for i = 1, sRows do
    line(5 + i, formatCategorySummary(summaries[i], w), uiStatus.color(categorySummaryStatus(summaries[i])))
  end

  local planY = 5 + sRows + 1
  line(planY, "Stock Keeper Plan", colors.cyan)
  local headerRows = 0
  if w >= 72 then
    line(planY + 1, uiDraw.fit("ITEM", math.max(18, w - 39)) .. "     HAVE   TARGET    PLAN   STATUS", colors.gray)
    headerRows = 1
  end

  local plans = data.stockPlans or {}
  local queue = data.craftQueue or {}
  local planStart = planY + 1 + headerRows
  local reserve = 1 + (#queue > 0 and (1 + math.min(3, #queue)) or 0) -- tally + queue block
  local planRows = math.max(0, math.min(#plans, h - planStart - reserve))
  for i = 1, planRows do
    line(planStart + i - 1, formatPlanRow(plans[i], w), uiStatus.color(plans[i].action))
  end

  local tally = data.stockTally or {}
  local tallyY = planStart + planRows
  line(tallyY, "+ " .. fmt(tally.OK) .. "  > " .. fmt(tally.WOULD) .. "  ~ " .. fmt(tally.CRAFTING) ..
    "  . " .. fmt(tally.COOLDOWN) .. "  x " .. fmt(tally.NO_RECIPE) .. "  # " .. fmt(tally.BLOCKED), colors.gray)

  if #queue > 0 then
    local qy = tallyY + 1
    line(qy, "Queue: " .. #queue .. " approved", colors.cyan)
    for i = 1, math.min(3, #queue) do
      if qy + i > h then break end
      local e = queue[i]
      line(qy + i, uiDraw.fit(tostring(e.label or e.name) .. " +" .. fmt(e.request) .. " " .. tostring(e.state), w),
        uiStatus.color(uiStatus.WOULD))
    end
  end
end

-- ALERTS profile: errors, stale data, low stock, and craft problems only.
local function drawAlerts(data)
  local w, h = monitor.getSize()
  local y = 5

  if data.configError then line(y, "CONFIG: " .. data.configError, colors.orange); y = y + 1 end
  if data.ledgerError then line(y, "LEDGER: " .. data.ledgerError, colors.red); y = y + 1 end
  local age = os.clock() - (lastSeen or os.clock())
  if age > STALE_SECONDS then line(y, "STALE: no update for " .. math.floor(age) .. "s", colors.orange); y = y + 1 end

  line(y, "Low Stock", colors.cyan); y = y + 1
  local warnings = data.warnings or {}
  if #warnings == 0 then
    line(y, "All watched items above target.", colors.lime); y = y + 1
  else
    for i = 1, #warnings do
      if y > h then break end
      local warn = warnings[i]
      local craft = warn.craftable and " (craftable)" or ""
      line(y, warn.label .. ": " .. fmt(warn.amount) .. " / " .. fmt(warn.target) .. craft, colors.orange)
      y = y + 1
    end
  end

  local probs = {}
  for _, p in ipairs(data.stockPlans or {}) do
    local n = uiStatus.normalize(p.action)
    if n == uiStatus.NO_RECIPE or n == uiStatus.BLOCKED then probs[#probs + 1] = p end
  end
  if y < h then
    y = y + 1
    line(y, "Craft Problems (" .. #probs .. ")", colors.cyan); y = y + 1
    for i = 1, #probs do
      if y > h then break end
      line(y, uiDraw.fit(uiStatus.label(probs[i].action) .. "  " .. tostring(probs[i].label), w),
        uiStatus.color(probs[i].action))
      y = y + 1
    end
  end
end

local function draw(data)
  if not monitor then return end

  if not data then
    drawWaiting("Waiting for inventory source...")
    return
  end

  present(function()
    line(1, TITLE .. "  [" .. PROFILE .. "]", colors.cyan)

    local w, h = monitor.getSize()
    if w < MIN_WIDTH or h < MIN_HEIGHT then
      drawPanel("Monitor Too Small", {
        "Current: " .. tostring(w) .. "x" .. tostring(h),
        "Need: >= " .. MIN_WIDTH .. "x" .. MIN_HEIGHT,
      }, math.max(3, math.floor((h - 4) / 2)), 4, colors.orange)
      return
    end

    -- Readiness banner: say plainly whether this screen is live or reconnecting, so
    -- a frozen-looking display is never mistaken for current data.
    local age = os.clock() - (lastSeen or os.clock())
    if not lastSeen then
      line(2, "STARTING - waiting for source...", colors.yellow)
    elseif age > STALE_SECONDS then
      line(2, "RECONNECTING - last update " .. math.floor(age) .. "s ago", colors.orange)
    else
      line(2, "LIVE - source " .. tostring(data.source or "?") .. "   updated " .. math.floor(age) .. "s ago", colors.lime)
    end

    local onlineText, onlineColor = "unknown", colors.yellow
    if data.online == true then onlineText, onlineColor = "ONLINE", colors.lime
    elseif data.online == false then onlineText, onlineColor = "OFFLINE", colors.red end
    line(3, "Grid: " .. onlineText .. "   Types: " .. fmt(data.unique) .. "   Items: " .. fmt(data.totalAmount), onlineColor)

    if PROFILE == "autocraft" then
      drawAutocraft(data)
    elseif PROFILE == "alerts" then
      drawAlerts(data)
    else
      drawView(data)
    end
  end)
end

-- VIEW-2: redraw + touch paging helpers.
local function redraw()
  -- A render error (e.g. a malformed broadcast) logs and self-heals on the next
  -- tick instead of crashing the display.
  local ok, err = pcall(draw, last)
  if not ok then
    print("draw error: " .. tostring(err))
    pcall(drawWaiting, "Render error; retrying")
  end
end

local function handleViewTouch(x, y)
  if PROFILE ~= "view" then return end -- only the inventory list paginates
  local filterKey = viewFilterRow and console.buttonHit(viewFilterRow, x, y)
  if filterKey ~= nil then
    viewFilter = filterKey
    viewPage = 1
    viewSelected = nil
    return
  end

  local key = viewNavRow and console.buttonHit(viewNavRow, x, y)
  if key == "prev" then viewPage = math.max(1, viewPage - 1)
  elseif key == "next" then viewPage = viewPage + 1 -- paginate() clamps to the last page
  elseif key == "sort" then viewSort = console.nextSort(viewSort); viewPage = 1 end
  if key ~= nil then return end

  local entry = console.rowHit(viewRowRegions, y)
  if entry then viewSelected = entry end
end

-- Event-driven loop: touch paging (monitor_touch) works alongside rednet updates;
-- a periodic timer ages the readiness banner even with no new broadcast.
local refreshTimer = nil
while true do
  openModems()

  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale(); prevFrame = nil end -- fresh buffer baseline on (re)acquire
  end

  if not modemsOpen then
    if monitor then drawWaiting("No modem found") else print("No modem found") end
    sleep(2)
  elseif not monitor then
    print("No monitor found. Retrying...")
    sleep(2)
  else
    if not refreshTimer then refreshTimer = os.startTimer(1) end
    local ev = { os.pullEvent() }
    local kind = ev[1]
    if kind == "rednet_message" and ev[4] == PROTOCOL then
      local msg = ev[3]
      if type(msg) == "table" and msg.kind == "inventory_snapshot" then
        last = msg
        lastSeen = os.clock()
      end
      redraw()
    elseif kind == "monitor_touch" then
      handleViewTouch(ev[3], ev[4])
      redraw()
    elseif kind == "timer" and ev[2] == refreshTimer then
      redraw()
      refreshTimer = os.startTimer(1)
    end
  end
end
