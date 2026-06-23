local PROTOCOL = "atm10-power-v1"
local HOSTNAME = "display"
local MODEM_SIDE = "top"
local MONITOR_SIDE = "right"

local TITLE = "ATM10 POWER MANAGEMENT"
local TEXT_SCALE = "auto"
local HISTORY_LIMIT = 180
local SHOW_NET_GRAPH = true
local SHOW_STORED_GRAPH = true
local CRITICAL_PERCENT = 15
local LOW_PERCENT = 35
local STALE_SECONDS = 10

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on " .. MONITOR_SIDE) end

local paletteApplied = false

rednet.open(MODEM_SIDE)
pcall(function() rednet.host(PROTOCOL, HOSTNAME) end)

local function pickTextScale()
  if not paletteApplied then
    pcall(uiPalette.apply, mon)
    paletteApplied = true
  end

  if type(TEXT_SCALE) == "number" then
    mon.setTextScale(TEXT_SCALE)
    return TEXT_SCALE
  end

  local scales = {5, 4, 3, 2.5, 2, 1.5, 1, 0.5}
  for _, scale in ipairs(scales) do
    mon.setTextScale(scale)
    local w, h = mon.getSize()
    if w >= 34 and h >= 18 then return scale end
  end

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
local netHistory = {}
local last = nil
local lastSeen = nil
local lastNonzeroInput = 0
local lastNonzeroOutput = 0

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

local function fmtDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds >= 86400 then return string.format("%.1fd", seconds / 86400) end
  if seconds >= 3600 then return string.format("%.1fh", seconds / 3600) end
  if seconds >= 60 then return string.format("%dm", math.floor(seconds / 60)) end
  return tostring(seconds) .. "s"
end

local function estimateTime(energy, maxEnergy, net)
  energy = tonumber(energy) or 0
  maxEnergy = tonumber(maxEnergy) or 0
  net = tonumber(net) or 0

  if math.abs(net) < 1 then return "Time: stable", colors.gray end

  if net < 0 then
    return "Empty in " .. fmtDuration(energy / math.abs(net) / 20), colors.red
  end

  return "Full in  " .. fmtDuration((maxEnergy - energy) / net / 20), colors.lime
end

local function effectiveNet(sample)
  local input = tonumber(sample.input) or 0
  local output = tonumber(sample.output) or 0
  local reported = tonumber(sample.reportedNet) or (input - output)
  local estimated = tonumber(sample.estimatedNet) or 0

  if input == 0 and output == 0 and math.abs(estimated) > 1 then
    return estimated, "estimated"
  end

  return reported, "reported"
end

local function colorForPercent(p)
  if p < 15 then return colors.red end
  if p < 35 then return colors.orange end
  if p < 65 then return colors.yellow end
  return colors.lime
end

local function line(y, text, color)
  uiDraw.line(mon, y, text, color or colors.white, colors.black)
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
    local filled = 0
    if sample and pct > 0 then
      filled = math.max(1, math.ceil((pct / 100) * height))
    end

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

local function drawCompactGraph(y, pctHistory)
  local w = mon.getSize()
  if y < 1 then return end

  mon.setCursorPos(1, y)
  mon.clearLine()

  for x = 1, w do
    local sample = pctHistory[#pctHistory - w + x]
    if sample then
      mon.setBackgroundColor(colorForPercent(sample))
    else
      mon.setBackgroundColor(colors.black)
    end
    mon.write(" ")
  end

  mon.setBackgroundColor(colors.black)
end

local function maxAbsVisible(values, width)
  local maxAbs = 1
  for x = 1, width do
    local sample = values[#values - width + x]
    if sample then maxAbs = math.max(maxAbs, math.abs(sample)) end
  end
  return maxAbs
end

local function drawNetGraph(top, height, values)
  if height < 3 then return end

  local w = mon.getSize()
  local left = 2
  local width = w - 2
  local mid = top + math.floor(height / 2)
  local maxAbs = maxAbsVisible(values, width)

  for x = 1, width do
    local sample = values[#values - width + x]
    local v = sample or 0
    local positiveRows = math.max(1, mid - top)
    local negativeRows = math.max(1, top + height - 1 - mid)
    local rows = 0

    if sample then
      if v > 0 then rows = math.max(1, math.ceil((v / maxAbs) * positiveRows))
      elseif v < 0 then rows = math.max(1, math.ceil((math.abs(v) / maxAbs) * negativeRows)) end
    end

    for y = top, top + height - 1 do
      mon.setCursorPos(left + x - 1, y)
      if y == mid then
        mon.setBackgroundColor(colors.gray)
      elseif sample and v > 0 and y >= mid - rows and y < mid then
        mon.setBackgroundColor(colors.lime)
      elseif sample and v < 0 and y <= mid + rows and y > mid then
        mon.setBackgroundColor(colors.red)
      else
        mon.setBackgroundColor(colors.black)
      end
      mon.write(" ")
    end
  end

  mon.setBackgroundColor(colors.black)
end

local function drawCompactNetGraph(y, values)
  local w = mon.getSize()
  if y < 1 then return end

  mon.setCursorPos(1, y)
  mon.clearLine()

  for x = 1, w do
    local sample = values[#values - w + x]
    if sample and sample > 0 then mon.setBackgroundColor(colors.lime)
    elseif sample and sample < 0 then mon.setBackgroundColor(colors.red)
    elseif sample then mon.setBackgroundColor(colors.gray)
    else mon.setBackgroundColor(colors.black) end
    mon.write(" ")
  end

  mon.setBackgroundColor(colors.black)
end

local function draw()
  local _, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  line(1, TITLE, colors.cyan)

  if not last then
    line(3, "Waiting for power computer...", colors.yellow)
    line(5, "Protocol: " .. PROTOCOL, colors.gray)
    return
  end

  local pct = last.percent or 0
  local net, netSource = effectiveNet(last)
  local age = now() - (lastSeen or now())
  local timeText, timeColor = estimateTime(last.energy, last.maxEnergy, net)

  line(3, "Stored: " .. fmt(last.energy) .. " / " .. fmt(last.maxEnergy), colors.white)
  drawBar(4, "Matrix", pct)

  line(6, "Full:   " .. string.format("%.2f%%", pct), colorForPercent(pct))
  line(7, "Input:  " .. fmt(last.input) .. "/t", colors.lime)
  line(8, "Output: " .. fmt(last.output) .. "/t", colors.red)

  local netColor = colors.white
  if net > 0 then netColor = colors.lime elseif net < 0 then netColor = colors.red end
  line(9, "Net:    " .. fmt(net) .. "/t " .. netSource, netColor)

  if (last.input or 0) == 0 and (last.output or 0) == 0 and (lastNonzeroInput > 0 or lastNonzeroOutput > 0) then
    line(10, "Last IO: " .. fmt(lastNonzeroInput) .. "/t in  " .. fmt(lastNonzeroOutput) .. "/t out", colors.gray)
  else
    line(10, timeText, timeColor)
  end

  -- Status label and color come from the shared vocabulary (atm10-status), so
  -- power and inventory speak one language. Thresholds are unchanged.
  local statusText = "OK"
  if age > STALE_SECONDS then statusText = "STALE DATA"
  elseif pct < CRITICAL_PERCENT then statusText = "CRITICAL"
  elseif pct < LOW_PERCENT then statusText = "LOW"
  elseif net < 0 then statusText = "DRAINING" end

  if (last.input or 0) == 0 and (last.output or 0) == 0 and (lastNonzeroInput > 0 or lastNonzeroOutput > 0) then
    line(11, timeText, timeColor)
  end

  line(12, "Status: " .. uiStatus.label(statusText) .. "   age " .. math.floor(age) .. "s", uiStatus.color(statusText))

  if SHOW_NET_GRAPH and SHOW_STORED_GRAPH and h >= 21 then
    line(13, "Net Flow History", colors.cyan)
    local netHeight = math.max(3, math.floor((h - 15) / 2))
    drawNetGraph(14, netHeight, netHistory)

    local storedLabel = 14 + netHeight
    line(storedLabel, "Stored Energy History", colors.cyan)
    drawGraph(storedLabel + 1, h - storedLabel, history)
  elseif SHOW_NET_GRAPH and h >= 16 then
    line(13, "Net Flow History", colors.cyan)
    drawNetGraph(14, h - 13, netHistory)
  elseif SHOW_STORED_GRAPH and h >= 15 then
    line(13, "Stored Energy History", colors.cyan)
    drawGraph(14, h - 13, history)
  elseif SHOW_NET_GRAPH and h >= 13 then
    drawCompactNetGraph(13, netHistory)
  elseif SHOW_STORED_GRAPH and h >= 13 then
    drawCompactGraph(13, history)
  else
    line(h, "Scale " .. tostring(textScale) .. " auto", colors.gray)
  end
end

while true do
  local _, msg = rednet.receive(PROTOCOL, 1)
  if type(msg) == "table" and msg.kind == "power_sample" then
    last = msg
    lastSeen = now()
    if msg.lastNonzeroInput and msg.lastNonzeroInput > 0 then lastNonzeroInput = msg.lastNonzeroInput end
    if msg.lastNonzeroOutput and msg.lastNonzeroOutput > 0 then lastNonzeroOutput = msg.lastNonzeroOutput end

    history[#history + 1] = msg.percent or 0
    local net = effectiveNet(msg)
    netHistory[#netHistory + 1] = net

    while #history > HISTORY_LIMIT do table.remove(history, 1) end
    while #netHistory > HISTORY_LIMIT do table.remove(netHistory, 1) end
  end

  -- A render error (e.g. a malformed packet) logs and self-heals on the next
  -- tick instead of crashing the loop and losing the history buffer.
  local ok, err = pcall(draw)
  if not ok then
    print("draw error: " .. tostring(err))
    pcall(function()
      mon.setBackgroundColor(colors.black)
      mon.clear()
      line(1, TITLE, colors.cyan)
      line(3, "Render error; retrying", colors.orange)
      line(5, tostring(err), colors.gray)
    end)
  end
end
