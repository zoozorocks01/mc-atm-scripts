local PROTOCOL = "atm10-power-v1"
local HOSTNAME = "display"
local MODEM_SIDE = "top"
local MONITOR_SIDE = "right"

local TITLE = "ATM10 POWER MANAGEMENT"
local TEXT_SCALE = "auto"
local HISTORY_LIMIT = 180
local HISTORY_FILE = ".atm10-power-history"
local HISTORY_SAVE_SECONDS = 60
local SHOW_NET_GRAPH = true
local SHOW_STORED_GRAPH = true
-- POWER-GRAPH: net-flow graph y-scaling. "auto" tracks the visible peak (fills the height but
-- the graph can jump as the peak changes); "fixed" pins the y-max to NET_SCALE_FIXED (FE/t) so
-- a transient spike does not rescale everything -- set both to pin the scale. Scale math is the
-- unit-tested power.computeScale.
local NET_SCALE_MODE = "auto"
local NET_SCALE_FIXED = nil
local CRITICAL_PERCENT = 15
local LOW_PERCENT = 35
local STALE_SECONDS = 10
-- QUICK-3: alarm on ENTRY to an alarming status. A speaker beep is harmless so it defaults ON
-- when a speaker is attached; redstone output drives external contraptions, so it stays OFF
-- until ALARM_REDSTONE_SIDE is set to a side ("back"/"top"/...). Edge-triggered (no chatter).
local ALARM_ENABLED = true
local ALARM_REDSTONE_SIDE = nil
local ALARM_SOUND = true

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")
local power = require("atm10-power") -- QUICK-2: pure FE/duration/percent/net math (tested off-CC)
local healthOk, health = pcall(require, "atm10-health")

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
local alarmActive = false -- QUICK-3: carries the alarm edge-state across frames
local speaker = (peripheral and peripheral.find) and peripheral.find("speaker") or nil
local frame = nil      -- D1: current render buffer, set during present()
local prevFrame = nil  -- D1: previous frame for diff-rendering

local function now()
  if os.epoch then return math.floor(os.epoch("utc") / 1000) end
  return os.clock()
end

-- PWR-1: retain a small paired graph window across a watchdog/program restart.
-- Save infrequently (not every 1s sample) and use the same rollback replacement
-- helper as manager state, so a failed write leaves the prior history intact.
local function loadHistory()
  if not fs.exists(HISTORY_FILE) then return {}, {} end
  local file = fs.open(HISTORY_FILE, "r")
  if not file then return {}, {} end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok then return {}, {} end
  return power.historyPair(data, HISTORY_LIMIT)
end

local function saveHistory()
  if not healthOk or not health or type(health.replaceFile) ~= "function" then return false end
  local ok, text = pcall(textutils.serialize, { history = history, netHistory = netHistory })
  if not ok or type(text) ~= "string" then return false end
  local tmp = HISTORY_FILE .. ".tmp"
  if fs.exists(tmp) then pcall(fs.delete, tmp) end
  local file = fs.open(tmp, "w")
  if not file then return false end
  if not pcall(function() file.write(text); file.close() end) then pcall(fs.delete, tmp); return false end
  return health.replaceFile(fs, HISTORY_FILE, tmp) == true
end

history, netHistory = loadHistory()
local lastHistorySaveAt = now()

-- QUICK-2: math moved to the tested atm10-power lib. Thin aliases keep the call
-- sites unchanged; estimateTime maps the lib's state string to a display color.
local fmt = power.fmt
local effectiveNet = power.effectiveNet

local function estimateTime(energy, maxEnergy, net)
  local text, state = power.estimateTime(energy, maxEnergy, net)
  local color = (state == "empty" and colors.red) or (state == "full" and colors.lime) or colors.gray
  return text, color
end

local function colorForPercent(p)
  if p < 15 then return colors.red end
  if p < 35 then return colors.orange end
  if p < 65 then return colors.yellow end
  return colors.lime
end

local function line(y, text, color, bg)
  if frame then
    uiDraw.bufferWrite(frame, 1, y, uiDraw.fit(text, frame.width), color or colors.white, bg or colors.black)
  else
    uiDraw.line(mon, y, text, color or colors.white, bg or colors.black)
  end
end

local function cell(x, y, bg)
  if frame then
    uiDraw.bufferWrite(frame, x, y, " ", colors.white, bg or colors.black)
    return
  end
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg or colors.black)
  mon.write(" ")
end

local function drawBar(y, label, pct)
  local w = frame and frame.width or mon.getSize()
  local barW = math.max(10, w - #label - 8)
  local filled = math.floor(barW * math.max(0, math.min(100, pct)) / 100)

  line(y, "", colors.white)
  if frame then
    uiDraw.bufferWrite(frame, 1, y, label .. " [", colors.white, colors.black)
  else
    mon.setCursorPos(1, y)
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(colors.black)
    mon.write(label .. " [")
  end

  for i = 1, barW do
    cell(#label + 3 + i - 1, y, i <= filled and colorForPercent(pct) or colors.gray)
  end

  if frame then
    uiDraw.bufferWrite(frame, #label + 3 + barW, y, "] " .. string.format("%3.0f%%", pct), colors.white, colors.black)
  else
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.write("] " .. string.format("%3.0f%%", pct))
  end
end

local function present(renderFn)
  local w, h = mon.getSize()
  frame = uiDraw.newBuffer(w, h)
  renderFn(w, h)
  prevFrame = uiDraw.renderBuffer(mon, frame, prevFrame)
  frame = nil
end

local function drawGraph(top, height, pctHistory)
  if height < 2 then return end

  local w = frame and frame.width or mon.getSize()
  local left = 2
  local width = w - 2

  -- POWER-GRAPH: aggregate the WHOLE history into `width` buckets (pure, tested) so the full
  -- window shows even when there are more samples than columns. Each column fills to the
  -- bucket's MAX (so peaks stay visible); the average row sits a shade brighter so the column
  -- reads as a min..max range, not a flat bar. Stored % is implicitly 0-100.
  local buckets = power.downsample(pctHistory, width)

  for x = 1, width do
    local bk = buckets[x]
    local hasData = bk and bk.n > 0
    local maxRows = 0
    local avgRows = 0
    if hasData and bk.max > 0 then
      maxRows = math.max(1, math.ceil((bk.max / 100) * height))
    end
    if hasData and bk.avg > 0 then
      avgRows = math.max(1, math.ceil((bk.avg / 100) * height))
    end

    for y = 0, height - 1 do
      local bg
      if hasData and y < maxRows then
        -- the range cap (between avg and max) is dimmed; the solid body (<= avg) is full color
        if y < avgRows then
          bg = colorForPercent(bk.avg)
        else
          bg = colors.gray
        end
      else
        bg = colors.black
      end
      cell(left + x - 1, top + height - y - 1, bg)
    end
  end
  if not frame then mon.setBackgroundColor(colors.black) end
end

local function drawCompactGraph(y, pctHistory)
  local w = frame and frame.width or mon.getSize()
  if y < 1 then return end

  line(y, "", colors.white)

  for x = 1, w do
    local sample = pctHistory[#pctHistory - w + x]
    cell(x, y, sample and colorForPercent(sample) or colors.black)
  end

  if not frame then mon.setBackgroundColor(colors.black) end
end

local function drawNetGraph(top, height, values)
  if height < 3 then return end

  local w = frame and frame.width or mon.getSize()
  local left = 2
  local width = w - 2
  local mid = top + math.floor(height / 2)

  -- POWER-GRAPH: aggregate the WHOLE history into `width` buckets (pure, tested) so the full
  -- net-flow window shows; draw each column as a min..max RANGE around the zero line (a real
  -- sparkline showing volatility, not a 1px line). Y-scale is the unit-tested power.computeScale:
  -- "auto" tracks the visible peak, "fixed" pins it so the graph stops jumping per frame.
  local buckets = power.downsample(values, width)
  local scaleVals = {}
  for i = 1, #buckets do
    local bk = buckets[i]
    if bk.n > 0 then
      scaleVals[#scaleVals + 1] = bk.max
      scaleVals[#scaleVals + 1] = bk.min
    end
  end
  local maxAbs = power.computeScale(scaleVals, NET_SCALE_MODE, NET_SCALE_FIXED)

  local positiveRows = math.max(1, mid - top)
  local negativeRows = math.max(1, top + height - 1 - mid)

  for x = 1, width do
    local bk = buckets[x]
    local hasData = bk and bk.n > 0
    -- positive extent reaches the bucket MAX; negative extent reaches the bucket MIN, so the
    -- filled span between them is the column's range (a bucket straddling zero fills both sides).
    local posRows, negRows = 0, 0
    local avgPosRows, avgNegRows = 0, 0
    if hasData then
      if bk.max > 0 then posRows = math.max(1, math.ceil((bk.max / maxAbs) * positiveRows)) end
      if bk.min < 0 then negRows = math.max(1, math.ceil((math.abs(bk.min) / maxAbs) * negativeRows)) end
      if bk.avg > 0 then avgPosRows = math.max(1, math.ceil((bk.avg / maxAbs) * positiveRows)) end
      if bk.avg < 0 then avgNegRows = math.max(1, math.ceil((math.abs(bk.avg) / maxAbs) * negativeRows)) end
    end

    for y = top, top + height - 1 do
      local bg
      if y == mid then
        bg = colors.gray
      elseif hasData and y < mid and y >= mid - posRows then
        -- above zero: solid lime up to avg, dimmed (range to max) above it
        bg = y >= mid - avgPosRows and colors.lime or colors.green
      elseif hasData and y > mid and y <= mid + negRows then
        -- below zero: solid red down to avg, dimmed (range to min) below it
        bg = y <= mid + avgNegRows and colors.red or colors.brown
      else
        bg = colors.black
      end
      cell(left + x - 1, y, bg)
    end
  end

  if not frame then mon.setBackgroundColor(colors.black) end
end

local function drawCompactNetGraph(y, values)
  local w = frame and frame.width or mon.getSize()
  if y < 1 then return end

  line(y, "", colors.white)

  for x = 1, w do
    local sample = values[#values - w + x]
    local bg
    if sample and sample > 0 then bg = colors.lime
    elseif sample and sample < 0 then bg = colors.red
    elseif sample then bg = colors.gray
    else bg = colors.black end
    cell(x, y, bg)
  end

  if not frame then mon.setBackgroundColor(colors.black) end
end

local function draw()
  present(function(_, h)
    line(1, TITLE, colors.cyan)

    if not last then
      line(3, "Waiting for power computer...", colors.yellow)
      line(5, "Protocol: " .. PROTOCOL, colors.gray)
      return
    end

    -- QUICK-4: the probe reached us but its induction port is not responding -- show a SENSOR
    -- state rather than the fabricated 0/0/0% an unreachable port would otherwise read as.
    if last.sensorOk == false then
      line(3, "SENSOR UNREACHABLE", colors.orange)
      line(5, "The induction port is not responding to reads.", colors.gray)
      line(6, "Showing no data instead of a fabricated 0%.", colors.gray)
      line(8, "Check the matrix / port placement on the probe.", colors.gray)
      line(10, "Last contact age " .. math.floor(now() - (lastSeen or now())) .. "s", colors.gray)
      return
    end

    local pct = last.percent or 0
    local net, netSource = effectiveNet(last)
    local age = now() - (lastSeen or now())
    local timeText, timeColor = estimateTime(last.energy, last.maxEnergy, net)

    line(3, "Stored: " .. fmt(last.energy) .. " / " .. fmt(last.maxEnergy), colors.white)
    drawBar(4, "Matrix", pct)

    line(6, "Full:   " .. string.format("%.2f%%", pct), colorForPercent(pct))
  -- QUICK-1: surface input/output as a fraction of the matrix's per-tick transfer cap
  -- (transferCap is already on the wire from the probe). headroom() hides it when cap is 0.
    local cap = last.transferCap or 0
    local inHead = power.headroom(last.input, cap)
    local outHead = power.headroom(last.output, cap)
    line(7, "Input:  " .. fmt(last.input) .. "/t" .. (inHead and string.format("  %3.0f%% cap", inHead) or ""), colors.lime)
    line(8, "Output: " .. fmt(last.output) .. "/t" .. (outHead and string.format("  %3.0f%% cap", outHead) or ""), colors.red)

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

  -- QUICK-3: edge-triggered alarm (decision unit-tested in atm10-power). Redstone is held while
  -- alarming and cleared when it clears; the beep fires once on entry so it can't chatter.
    if ALARM_ENABLED then
      local fire
      fire, alarmActive = power.alarmDecision(statusText, alarmActive)
      if ALARM_REDSTONE_SIDE and redstone then pcall(redstone.setOutput, ALARM_REDSTONE_SIDE, alarmActive) end
      if fire and ALARM_SOUND and speaker then pcall(speaker.playNote, "bell", 3, 12) end
    end

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
  end)
end

while true do
  local _, msg = rednet.receive(PROTOCOL, 1)
  if type(msg) == "table" and msg.kind == "power_sample" then
    last = msg
    lastSeen = now()
    if msg.lastNonzeroInput and msg.lastNonzeroInput > 0 then lastNonzeroInput = msg.lastNonzeroInput end
    if msg.lastNonzeroOutput and msg.lastNonzeroOutput > 0 then lastNonzeroOutput = msg.lastNonzeroOutput end

    -- QUICK-4: never push a fabricated 0% into the graphs while the sensor is unreachable
    if msg.sensorOk ~= false then
      history[#history + 1] = msg.percent or 0
      local net = effectiveNet(msg)
      netHistory[#netHistory + 1] = net

      while #history > HISTORY_LIMIT do table.remove(history, 1) end
      while #netHistory > HISTORY_LIMIT do table.remove(netHistory, 1) end
      if now() - lastHistorySaveAt >= HISTORY_SAVE_SECONDS then
        pcall(saveHistory)
        lastHistorySaveAt = now()
      end
    end
  end

  -- A render error (e.g. a malformed packet) logs and self-heals on the next
  -- tick instead of crashing the loop and losing the history buffer.
  local ok, err = pcall(draw)
  if not ok then
    print("draw error: " .. tostring(err))
    pcall(function()
      prevFrame = nil
      mon.setBackgroundColor(colors.black)
      mon.clear()
      line(1, TITLE, colors.cyan)
      line(3, "Render error; retrying", colors.orange)
      line(5, tostring(err), colors.gray)
    end)
  end
end
