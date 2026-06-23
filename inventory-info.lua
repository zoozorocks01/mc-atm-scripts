local TITLE = "ATM10 INVENTORY INFO"
local MONITOR_SIDE = "auto"
local BRIDGE_NAME = "auto"
local TEXT_SCALE = "auto"
local REFRESH_SECONDS = 5
local TOP_ITEM_COUNT = 8
local BROADCAST_ENABLED = true
local BROADCAST_MODEM_SIDE = "auto"
local BROADCAST_PROTOCOL = "atm10-inventory-v1"

local LOW_STOCK = {
  { label = "Glass", name = "minecraft:glass", target = 512 },
  { label = "Redstone", name = "minecraft:redstone", target = 1024 },
  { label = "Iron Ingots", name = "minecraft:iron_ingot", target = 512 },
  { label = "Quartz", name = "minecraft:quartz", target = 256 },
}

local monitor = nil
local bridge = nil
local bridgeName = nil
local status = "Starting"
local broadcastReady = false

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

local function isCraftable(registryName, item)
  if type(item) == "table" and item.isCraftable ~= nil then return item.isCraftable end

  local result = call(bridge, "isCraftable", { name = registryName })
  if result ~= nil then return result == true end

  result = call(bridge, "isItemCraftable", { name = registryName })
  return result == true
end

local function scan()
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
  for _, target in ipairs(LOW_STOCK) do
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

  return {
    connected = connected,
    online = online,
    items = sorted,
    unique = unique,
    totalAmount = totalAmount,
    craftableCount = craftableCount,
    warnings = warnings,
    usedItemStorage = call(bridge, "getUsedItemStorage"),
    totalItemStorage = call(bridge, "getTotalItemStorage") or call(bridge, "getMaxItemDiskStorage"),
    availableItemStorage = call(bridge, "getAvailableItemStorage"),
    storedEnergy = call(bridge, "getStoredEnergy") or call(bridge, "getEnergyStorage"),
    energyCapacity = call(bridge, "getEnergyCapacity") or call(bridge, "getMaxEnergyStorage"),
    energyUsage = call(bridge, "getEnergyUsage"),
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
    warnings = data.warnings,
    topItems = compactItems(data.items, TOP_ITEM_COUNT),
    usedItemStorage = data.usedItemStorage,
    totalItemStorage = data.totalItemStorage,
    availableItemStorage = data.availableItemStorage,
    storedEnergy = data.storedEnergy,
    energyCapacity = data.energyCapacity,
    energyUsage = data.energyUsage,
  }, BROADCAST_PROTOCOL)
end

local function drawWaiting(message)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  line(1, TITLE, colors.cyan)
  line(3, message, colors.red)
  line(5, "Attach monitor + RS Bridge to this computer.", colors.gray)
end

local function draw(data)
  if not monitor then return end

  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  line(1, TITLE, colors.cyan)
  line(2, "Bridge: " .. tostring(bridgeName or "?"), colors.gray)

  if not data then
    drawWaiting(status)
    return
  end

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
  if #data.warnings == 0 then
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
  if h < topY + 2 then topY = 14 + math.min(4, #data.warnings) end

  line(topY, "Top Stored Items", colors.cyan)
  local maxRows = math.min(TOP_ITEM_COUNT, h - topY)
  for i = 1, maxRows do
    local item = data.items[i]
    if item then
      line(topY + i, tostring(i) .. ". " .. itemName(item) .. "  " .. fmt(itemAmount(item)), colors.white)
    end
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
      draw(data)
      broadcast(data)
    else
      drawWaiting(tostring(data))
    end
  else
    print("No monitor found. Retrying...")
  end

  sleep(REFRESH_SECONDS)
end
