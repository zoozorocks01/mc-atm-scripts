local TITLE = "ATM10 CRAFT REQUEST"
local MONITOR_SIDE = "auto"
local MODEM_SIDE = "auto"
local TEXT_SCALE = "auto"
local INV_PROTOCOL = "atm10-inventory-v1" -- listen for the snapshot broadcast
local STALE_SECONDS = 15
local JOB_LINGER_SECONDS = 8 -- keep a finished job visible briefly after it drops from the queue

local uiStatus = require("atm10-status")
local uiDraw = require("atm10-draw")
local uiPalette = require("atm10-palette")
local console = require("atm10-console")
local control = require("atm10-control")

-- The control token sent with every craft_request (one-line atm10-control-token
-- file; missing => nil, manager denies if it requires one). Resolved once at boot.
local controlToken = console.resolveControlToken()

-- One UI-state table (keeps top-level locals tidy + the state testable).
local ui = {
  mode = "browse",   -- "browse" | "detail"
  query = "",        -- reserved for a future on-screen search (sort/pagination ship first)
  page = 1,
  sort = "qty",
  selected = nil,    -- the item picked on the browse screen
  qty = 1,
  jobs = {},         -- name -> { name, label, request, requested, made, state, error, seenAt, sentAt }
  navRow = nil,      -- browse [< PREV][NEXT >][SORT] row
  detailRow = nil,   -- detail [BACK] row
  qtyRow = nil,      -- detail quantity picker row
  listRows = nil,    -- browse actionable item rows {{y, entry}}
  jobRows = nil,     -- jobs-strip [CANCEL] buttons keyed by name
  flash = nil,
  flashAt = 0,
}

local monitor = nil
local last = nil          -- last inventory_snapshot
local lastSeen = nil
local managerId = nil     -- learned from the snapshot's source / sender
local modemsOpen = false
local paletteApplied = false
local frame = nil
local prevFrame = nil

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

-- UI-1: write through the frame buffer when one is active, else straight to the
-- monitor (defensive fallback). Identical posture to remote.lua.
local function line(y, text, color)
  if frame then
    uiDraw.bufferWrite(frame, 1, y, uiDraw.fit(text, frame.width), color or colors.white, colors.black)
  else
    uiDraw.line(monitor, y, text, color or colors.white, colors.black)
  end
end

local function present(renderFn)
  if not monitor then return end
  local w, h = monitor.getSize()
  frame = uiDraw.newBuffer(w, h)
  renderFn(w, h)
  prevFrame = uiDraw.renderBuffer(monitor, frame, prevFrame)
  frame = nil
end

local function setFlash(msg)
  ui.flash = msg
  ui.flashAt = os.clock()
end

local function drawWaiting(message)
  present(function()
    line(1, TITLE, colors.cyan)
    line(3, message, colors.yellow)
    line(5, "Needs modem on " .. INV_PROTOCOL, colors.gray)
  end)
end

-- Map a jobRowFormat colorKey to a status color.
local function jobColor(colorKey)
  if colorKey == "error" then return uiStatus.color(uiStatus.BLOCKED) end
  if colorKey == "crafting" then return uiStatus.color(uiStatus.CRAFTING) end
  if colorKey == "done" then return uiStatus.color(uiStatus.OK) end
  return uiStatus.color(uiStatus.WOULD)
end

-- The jobs strip at the bottom: each tracked job + a [CANCEL] button. Returns the
-- first row it used so the caller can size the list above it. Registers cancel
-- buttons into ui.jobRows for hit-testing.
local function drawJobsStrip(w, h)
  ui.jobRows = {}
  -- order: most-recently-touched first; cap to a few rows
  local jobs = {}
  for _, j in pairs(ui.jobs) do jobs[#jobs + 1] = j end
  table.sort(jobs, function(a, b) return (a.sentAt or 0) > (b.sentAt or 0) end)

  local maxRows = math.min(4, #jobs)
  local stripTop = h - maxRows -- the "Jobs" header sits here
  if #jobs == 0 then return h end -- nothing to show; list can use the whole area

  line(stripTop, "Jobs (" .. #jobs .. ")", colors.cyan)
  for i = 1, maxRows do
    local job = jobs[i]
    local y = stripTop + i
    if y > h then break end
    -- [CANCEL] button on the right; job text fills the rest
    local cancel = console.buttonRow({ { label = "CANCEL", key = "cancel" } }, y, math.max(1, w - 8))
    local cb = cancel.buttons[1]
    local rowInfo = console.jobRowFormat(job, math.max(1, cb.x1 - 2))
    line(y, rowInfo.text, jobColor(rowInfo.colorKey))
    uiDraw.write(monitor, cb.x1, y, cb.text, colors.red, colors.black)
    ui.jobRows[#ui.jobRows + 1] = { row = cancel, name = job.name }
  end
  return stripTop
end

local function drawFlash(y)
  if ui.flash and (os.clock() - (ui.flashAt or 0)) < 4 then
    line(y, ui.flash, colors.yellow)
  end
end

local function drawBrowse()
  local w, h = monitor.getSize()
  local items = (last and last.viewItems) or {}
  console.sortItems(items, ui.sort)

  line(4, "Tap an item to request a craft.  (any item; no-recipe surfaces as a job error)", colors.gray)

  local stripTop = drawJobsStrip(w, h)
  local headerY = 6
  local navY = stripTop - 1
  local listStart = headerY + 1
  local perPage = math.max(1, navY - listStart)
  local pg = console.paginate(#items, perPage, ui.page)
  ui.page = pg.page

  line(headerY, "Craftable Items   " .. #items .. " shown   page " .. pg.page .. "/" .. pg.pages ..
    "   sort:" .. console.sortLabel(ui.sort), colors.cyan)

  ui.listRows = {}
  for i = pg.from, pg.to do
    local item = items[i]
    if item then
      local y = listStart + (i - pg.from)
      line(y, rjust(i, 4) .. ". " .. uiDraw.fit(tostring(item.name), math.max(8, w - 18)) ..
        "  " .. rjust(fmt(item.amount), 10), colors.white)
      ui.listRows[#ui.listRows + 1] = { y = y, entry = item }
    end
  end

  ui.navRow = console.buttonRow({
    { label = "< PREV", key = "prev" },
    { label = "NEXT >", key = "next" },
    { label = "SORT:" .. console.sortLabel(ui.sort), key = "sort" },
  }, navY, 1)
  for _, b in ipairs(ui.navRow.buttons) do
    local enabled = (b.key == "prev" and pg.page > 1) or (b.key == "next" and pg.page < pg.pages) or (b.key == "sort")
    uiDraw.write(monitor, b.x1, navY, b.text, enabled and colors.cyan or colors.gray, colors.black)
  end

  drawFlash(h)
end

local function drawDetail()
  local w, h = monitor.getSize()
  local sel = ui.selected or {}

  line(4, "Item:  " .. uiDraw.fit(tostring(sel.name or "?"), math.max(8, w - 8)), colors.white)
  line(5, "Stored: " .. fmt(sel.amount), colors.gray)
  line(7, "Quantity to craft: " .. tostring(ui.qty), colors.cyan)

  ui.qtyRow = console.quantityButtonRow(ui.qty, 9, 1)
  for _, b in ipairs(ui.qtyRow.buttons) do
    local color = colors.cyan
    if b.key == "qty" then color = colors.white
    elseif b.key == "submit" then color = colors.lime end
    uiDraw.write(monitor, b.x1, b.y, b.text, color, colors.black)
  end

  local stripTop = drawJobsStrip(w, h)
  ui.detailRow = console.buttonRow({ { label = "< BACK", key = "back" } }, math.min(11, stripTop - 1), 1)
  local bb = ui.detailRow.buttons[1]
  uiDraw.write(monitor, bb.x1, bb.y, bb.text, colors.orange, colors.black)

  drawFlash(h)
end

local function draw()
  if not monitor then return end

  if not last then
    drawWaiting("Waiting for inventory source...")
    return
  end

  present(function()
    line(1, TITLE, colors.cyan)
    local age = os.clock() - (lastSeen or os.clock())
    if not lastSeen then
      line(2, "STARTING - waiting for source...", colors.yellow)
    elseif age > STALE_SECONDS then
      line(2, "RECONNECTING - last update " .. math.floor(age) .. "s ago", colors.orange)
    else
      line(2, "LIVE - source " .. tostring(managerId or "?") .. "   updated " .. math.floor(age) .. "s ago", colors.lime)
    end

    if ui.mode == "detail" then
      drawDetail()
    else
      drawBrowse()
    end
  end)
end

local function redraw()
  local ok, err = pcall(draw)
  if not ok then
    print("draw error: " .. tostring(err))
    pcall(drawWaiting, "Render error; retrying")
  end
end

-- Reconcile ui.jobs against the latest craftQueue: refresh state/made/requested
-- for jobs still in the queue; mark jobs that have left the queue as done and let
-- them linger briefly before dropping. Matches by registry name.
local function reconcileJobs()
  local now = os.clock()
  local inQueue = {}
  for _, e in ipairs((last and last.craftQueue) or {}) do
    if e.name then inQueue[e.name] = e end
  end

  for name, job in pairs(ui.jobs) do
    local e = inQueue[name]
    if e then
      job.state = e.state
      job.request = e.request or job.request
      job.requested = e.requested or job.requested
      job.made = e.made or job.made
      job.error = e.error or job.error
      job.seenAt = now
    elseif job.seenAt then
      -- it was in the queue and is now gone -> completed; linger then drop
      if not job.doneAt then job.doneAt = now; job.state = "done" end
      if (now - job.doneAt) > JOB_LINGER_SECONDS then ui.jobs[name] = nil end
    elseif job.sentAt and (now - job.sentAt) > STALE_SECONDS then
      -- never appeared in the queue after STALE_SECONDS -> likely denied/no-recipe
      if not job.error then job.error = "not accepted (no recipe?)" end
    end
  end
end

-- Send a craft_request command to the manager and optimistically track it.
local function submitJob()
  local sel = ui.selected
  if not sel or not sel.name then setFlash("no item selected"); return end
  if not managerId then setFlash("no manager source yet"); return end

  local cmd = control.command({
    action = "craft_request",
    target = sel.name,
    args = { count = ui.qty, force = false },
    token = controlToken,
  })
  rednet.send(managerId, cmd, control.PROTOCOL)

  ui.jobs[sel.name] = {
    name = sel.name, label = sel.name, request = ui.qty, requested = ui.qty,
    made = 0, state = "APPROVED", sentAt = os.clock(),
  }
  setFlash("sent: " .. sel.name .. " x" .. ui.qty)
end

-- Cancel: A1 ships only craft_request, so the manager default-denies an unknown
-- craft_cancel action. Send it anyway (forward-compatible) and surface whatever
-- the manager replies; never silently no-op.
local function cancelJob(name)
  if not name then return end
  if managerId then
    local cmd = control.command({ action = "craft_cancel", target = name, token = controlToken })
    rednet.send(managerId, cmd, control.PROTOCOL)
  end
  ui.jobs[name] = nil
  setFlash("cancel sent: " .. name)
end

local function handleTouch(x, y)
  -- jobs strip cancel buttons (both screens)
  for _, jr in ipairs(ui.jobRows or {}) do
    if console.buttonHit(jr.row, x, y) == "cancel" then cancelJob(jr.name); return end
  end

  if ui.mode == "detail" then
    if ui.detailRow and console.buttonHit(ui.detailRow, x, y) == "back" then
      ui.mode = "browse"; return
    end
    local key = ui.qtyRow and console.buttonHit(ui.qtyRow, x, y)
    if key == "submit" then
      submitJob()
    elseif type(key) == "string" then
      local sign, step = key:match("^(%a+):(%d+)$")
      if sign == "inc" then ui.qty = console.stepQuantity(ui.qty, tonumber(step))
      elseif sign == "dec" then ui.qty = console.stepQuantity(ui.qty, -tonumber(step)) end
    end
    return
  end

  -- browse
  local navKey = ui.navRow and console.buttonHit(ui.navRow, x, y)
  if navKey == "prev" then ui.page = math.max(1, ui.page - 1); return
  elseif navKey == "next" then ui.page = ui.page + 1; return
  elseif navKey == "sort" then ui.sort = console.nextSort(ui.sort); ui.page = 1; return end

  local entry = console.rowHit(ui.listRows, y)
  if entry then
    ui.selected = entry
    ui.qty = 1
    ui.mode = "detail"
  end
end

-- Event-driven loop (template from remote.lua): rednet snapshots + control acks,
-- monitor_touch routing, and a 1s timer to age the banner / linger finished jobs.
local refreshTimer = nil
while true do
  openModems()

  if not monitor then
    monitor = findPeripheral({ "monitor" }, MONITOR_SIDE)
    if monitor then pickTextScale(); prevFrame = nil end
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
    if kind == "rednet_message" and ev[4] == INV_PROTOCOL then
      local msg = ev[3]
      if type(msg) == "table" and msg.kind == "inventory_snapshot" then
        last = msg
        lastSeen = os.clock()
        managerId = msg.source or ev[2] or managerId
        reconcileJobs()
      end
      redraw()
    elseif kind == "rednet_message" and ev[4] == control.PROTOCOL then
      local reply = ev[3]
      if type(reply) == "table" and reply.reason then
        setFlash("manager: " .. tostring(reply.reason))
      end
      redraw()
    elseif kind == "monitor_touch" then
      handleTouch(ev[3], ev[4])
      redraw()
    elseif kind == "timer" and ev[2] == refreshTimer then
      reconcileJobs()
      redraw()
      refreshTimer = os.startTimer(1)
    end
  end
end
