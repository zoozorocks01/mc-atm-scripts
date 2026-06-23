local TITLE = "ATM10 INVENTORY REMOTE"
local MONITOR_SIDE = "auto"
local MODEM_SIDE = "auto"
local TEXT_SCALE = "auto"
local PROTOCOL = "atm10-inventory-v1"
local STALE_SECONDS = 15

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")

local monitor = nil
local last = nil
local lastSeen = nil
local modemsOpen = false
local paletteApplied = false

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

local function line(y, text, color)
  uiDraw.line(monitor, y, text, color or colors.white, colors.black)
end

local function bar(y, label, used, total)
  local w = monitor.getSize()
  local p = pct(used, total)
  local barWidth = math.max(10, w - #label - 12)
  local filled = math.floor((p / 100) * barWidth)

  monitor.setCursorPos(1, y)
  monitor.setTextColor(colors.white)
  monitor.setBackgroundColor(colors.black)
  monitor.clearLine()
  monitor.write(label .. " [")

  for i = 1, barWidth do
    monitor.setBackgroundColor(i <= filled and colorForPercent(p) or colors.gray)
    monitor.write(" ")
  end

  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
  monitor.write("] " .. string.format("%3.0f%%", p))
end

local function drawWaiting(message)
  if not monitor then return end
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  line(1, TITLE, colors.cyan)
  line(3, message, colors.yellow)
  line(5, "Needs modem on " .. PROTOCOL, colors.gray)
end

local function draw(data)
  if not monitor then return end

  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  line(1, TITLE, colors.cyan)

  if not data then
    drawWaiting("Waiting for inventory source...")
    return
  end

  local age = os.clock() - (lastSeen or os.clock())
  local ageColor = age > STALE_SECONDS and colors.orange or colors.gray
  line(2, "Source: " .. tostring(data.source or "?") .. "   age " .. math.floor(age) .. "s", ageColor)

  local onlineText = "unknown"
  local onlineColor = colors.yellow
  if data.online == true then onlineText, onlineColor = "ONLINE", colors.lime
  elseif data.online == false then onlineText, onlineColor = "OFFLINE", colors.red end

  line(4, "Grid: " .. onlineText .. "   Types: " .. fmt(data.unique) .. "   Items: " .. fmt(data.totalAmount), onlineColor)
  line(5, "Managed: " .. fmt(data.managedItemCount) .. "   Listed: " .. fmt(data.listedItemCount) .. "   Default: " .. tostring(data.defaultHandling or "unmanaged"), colors.gray)

  if data.usedItemStorage and data.totalItemStorage then
    line(6, "Item Storage: " .. fmt(data.usedItemStorage) .. " / " .. fmt(data.totalItemStorage), colors.white)
    bar(7, "Items", data.usedItemStorage, data.totalItemStorage)
  else
    line(6, "Item Storage: capacity unavailable", colors.gray)
  end

  if data.storedEnergy and data.energyCapacity then
    line(9, "RS Energy: " .. fmt(data.storedEnergy) .. " / " .. fmt(data.energyCapacity) .. " FE", colors.white)
  end
  if data.energyUsage then
    line(10, "RS Usage:  " .. fmt(data.energyUsage) .. " FE/t", colors.white)
  end

  if data.configError then
    line(11, data.configError, colors.orange)
  else
    line(11, "Mode: " .. tostring(data.configMode or "dry-run"), colors.gray)
  end

  local _, h = monitor.getSize()
  local w = monitor.getSize()

  line(12, "Category Summary   + ok  > would  ~ craft  . wait  x recipe  # block", colors.cyan)
  local summaryRows = math.min(4, h - 12)
  for i = 1, summaryRows do
    local summary = data.categorySummaries and data.categorySummaries[i]
    if summary then
      line(12 + i, formatCategorySummary(summary, w), uiStatus.color(categorySummaryStatus(summary)))
    end
  end

  local planY = 18
  line(planY, "Stock Keeper Plan [dry-run]", colors.cyan)
  if w >= 72 then
    line(planY + 1, uiDraw.fit("ITEM", math.max(18, w - 39)) .. "     HAVE   TARGET    PLAN   STATUS", colors.gray)
  end

  local planStart = w >= 72 and planY + 2 or planY + 1
  local planRows = math.min(7, h - planStart)
  for i = 1, planRows do
    local plan = data.stockPlans and data.stockPlans[i]
    if plan then
      line(planStart + i - 1, formatPlanRow(plan, w), uiStatus.color(plan.action))
    end
  end

  local tally = data.stockTally or {}
  local tallyY = planStart + planRows
  if tallyY < h then
    line(tallyY, "+ " .. fmt(tally.OK) ..
      "  > " .. fmt(tally.WOULD) ..
      "  ~ " .. fmt(tally.CRAFTING) ..
      "  . " .. fmt(tally.COOLDOWN) ..
      "  x " .. fmt(tally.NO_RECIPE) ..
      "  # " .. fmt(tally.BLOCKED) ..
      "   apply disabled", colors.gray)
  end

  local lowY = 28
  if h < lowY + 2 then lowY = tallyY + 2 end

  line(lowY, "Low Stock", colors.cyan)
  if not data.warnings or #data.warnings == 0 then
    line(lowY + 1, "All watched items are above target.", colors.lime)
  else
    for i = 1, math.min(4, #data.warnings) do
      local warn = data.warnings[i]
      local craft = warn.craftable and " craftable" or ""
      line(lowY + i, warn.label .. ": " .. fmt(warn.amount) .. " / " .. fmt(warn.target) .. craft, colors.orange)
    end
  end

  local topY = lowY + math.min(5, data.warnings and #data.warnings + 1 or 1) + 1
  line(topY, "Top Stored Items", colors.cyan)
  local maxRows = math.min(8, h - topY)
  for i = 1, maxRows do
    local item = data.topItems and data.topItems[i]
    if item then
      line(topY + i, tostring(i) .. ". " .. tostring(item.name) .. "  " .. fmt(item.amount), colors.white)
    end
  end
end

while true do
  openModems()

  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale() end
  end

  if not modemsOpen then
    if monitor then drawWaiting("No modem found") else print("No modem found") end
    sleep(2)
  elseif monitor then
    local _, msg = rednet.receive(PROTOCOL, 1)
    if type(msg) == "table" and msg.kind == "inventory_snapshot" then
      last = msg
      lastSeen = os.clock()
    end
    draw(last)
  else
    print("No monitor found. Retrying...")
    sleep(2)
  end
end
