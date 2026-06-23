local PROTOCOL = "atm10-power-v1"
local HOSTNAME = "display"
local MODEM_SIDE = "top"
local MONITOR_SIDE = "right"
local TEXT_SCALE = "auto"

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on " .. MONITOR_SIDE) end

rednet.open(MODEM_SIDE)
pcall(function() rednet.host(PROTOCOL, HOSTNAME) end)

local function pickTextScale()
  if type(TEXT_SCALE) == "number" then
    mon.setTextScale(TEXT_SCALE)
    return TEXT_SCALE
  end

  local scales = {5, 4, 3, 2.5, 2, 1.5, 1, 0.5}
  for _, scale in ipairs(scales) do
    mon.setTextScale(scale)
    local w, h = mon.getSize()
    if w >= 34 and h >= 13 then return scale end
  end

  mon.setTextScale(0.5)
  return 0.5
end

local textScale = pickTextScale()

local history = {}
local last = nil
local lastSeen = nil

local function now()
  if os.epoch then return math.floor(os.epoch("utc") / 1000) end
  return os.clock()
end

local function fmt(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1000000000000 then return string.format("%.2f TFE", n / 1000000000000) end
  if a >= 1000000000 then return string.format("%.2f GFE", n / 1000000000) end
  if a >= 1000000 then return string.format("%.2f MFE", n / 1000000) end
  if a >= 1000 then return string.format("%.1f kFE", n / 1000) end
  return tostring(math.floor(n)) .. " FE"
end

local function colorForPercent(p)
  if p < 15 then return colors.red end
  if p < 35 then return colors.orange end
  if p < 65 then return colors.yellow end
  return colors.lime
end

local function line(y, text, color)
  local _, h = mon.getSize()
  if y > h then return end

  mon.setCursorPos(1, y)
  mon.setTextColor(color or colors.white)
  mon.setBackgroundColor(colors.black)
  mon.clearLine()
  mon.write(text)
end

local function drawBar(y, label, pct)
  local w = mon.getSize()
  local barW = math.max(10, w - #label - 8)
  local filled = math.floor(barW * math.max(0, math.min(100, pct)) / 100)

  mon.setCursorPos(1, y)
  mon.setTextColor(colors.white)
  mon.setBackgroundColor(colors.black)
  mon.clearLine()
  mon.write(label .. " [")

  for i = 1, barW do
    mon.setBackgroundColor(i <= filled and colorForPercent(pct) or colors.gray)
    mon.write(" ")
  end

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.write("] " .. string.format("%3.0f%%", pct))
end

local function drawGraph(top, height, pctHistory)
  if height < 2 then return end

  local w = mon.getSize()
  local left = 2
  local width = w - 2

  for x = 1, width do
    local sample = pctHistory[#pctHistory - width + x]
    local pct = sample or 0
    local filled = math.floor((pct / 100) * height)

    for y = 0, height - 1 do
      mon.setCursorPos(left + x - 1, top + height - y - 1)
      if sample and y < filled then
        mon.setBackgroundColor(colorForPercent(pct))
      else
        mon.setBackgroundColor(colors.black)
      end
      mon.write(" ")
    end
  end
  mon.setBackgroundColor(colors.black)
end

local function draw()
  local _, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  line(1, "ATM10 POWER MANAGEMENT", colors.cyan)

  if not last then
    line(3, "Waiting for power computer...", colors.yellow)
    line(5, "Protocol: " .. PROTOCOL, colors.gray)
    return
  end

  local pct = last.percent or 0
  local net = (last.input or 0) - (last.output or 0)
  local age = now() - (lastSeen or now())

  line(3, "Stored: " .. fmt(last.energy) .. " / " .. fmt(last.maxEnergy), colors.white)
  drawBar(4, "Matrix", pct)

  line(6, "Full:   " .. string.format("%.2f%%", pct), colorForPercent(pct))
  line(8, "Input:  " .. fmt(last.input) .. "/t", colors.lime)
  line(9, "Output: " .. fmt(last.output) .. "/t", colors.red)

  local netColor = colors.white
  if net > 0 then netColor = colors.lime elseif net < 0 then netColor = colors.red end
  line(10, "Net:    " .. fmt(net) .. "/t", netColor)

  local status = "OK"
  local statusColor = colors.lime
  if age > 10 then status, statusColor = "STALE DATA", colors.orange
  elseif pct < 15 then status, statusColor = "CRITICAL", colors.red
  elseif pct < 35 then status, statusColor = "LOW", colors.orange
  elseif net < 0 then status, statusColor = "DRAINING", colors.yellow end

  line(12, "Status: " .. status .. "   age " .. math.floor(age) .. "s", statusColor)

  if h >= 16 then
    line(14, "Stored Energy History", colors.cyan)
    local graphTop = 15
    local graphHeight = h - graphTop
    drawGraph(graphTop, graphHeight, history)
  else
    line(h, "Scale " .. tostring(textScale) .. " auto", colors.gray)
  end
end

while true do
  local _, msg = rednet.receive(PROTOCOL, 1)
  if type(msg) == "table" and msg.kind == "power_sample" then
    last = msg
    lastSeen = now()

    history[#history + 1] = msg.percent or 0
    while #history > 120 do table.remove(history, 1) end
  end

  draw()
end
