local TITLE = "ATM10 INVENTORY REMOTE"
local MONITOR_SIDE = "auto"
local MODEM_SIDE = "auto"
local TEXT_SCALE = "auto"
local PROTOCOL = "atm10-inventory-v1"
local STALE_SECONDS = 15

local monitor = nil
local last = nil
local lastSeen = nil
local modemsOpen = false

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
  local _, h = monitor.getSize()
  if y > h then return end
  monitor.setCursorPos(1, y)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(color or colors.white)
  monitor.clearLine()
  monitor.write(text)
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

  line(12, "Low Stock", colors.cyan)
  if not data.warnings or #data.warnings == 0 then
    line(13, "All watched items are above target.", colors.lime)
  else
    for i = 1, math.min(4, #data.warnings) do
      local warn = data.warnings[i]
      local craft = warn.craftable and " craftable" or ""
      line(12 + i, warn.label .. ": " .. fmt(warn.amount) .. " / " .. fmt(warn.target) .. craft, colors.orange)
    end
  end

  local _, h = monitor.getSize()
  local topY = 18
  if h < topY + 2 then topY = 14 + math.min(4, data.warnings and #data.warnings or 0) end

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
