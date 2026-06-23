-- Pure hit-testing for the management console: map a monitor_touch (x, y) to a
-- page tab or a rendered row. No peripherals; testable off-CC. The renderer
-- builds the regions while drawing and hands them back here on a touch.
local console = {}

-- Build a header tab strip like "[PLAN] [QUEUE]".
-- Returns { tabs = { {page, label, x1, x2, y} }, text = "...", y = y } so the
-- renderer draws `text` at (1, y) and keeps the result for hit-testing.
function console.tabs(pageNames, y, startX)
  y = y or 2
  local x = startX or 1
  local tabs = {}
  local parts = {}

  for i, name in ipairs(pageNames or {}) do
    local label = "[" .. tostring(name) .. "]"
    local x1 = x
    local x2 = x + #label - 1
    tabs[#tabs + 1] = { page = i, label = name, x1 = x1, x2 = x2, y = y }
    parts[#parts + 1] = label
    x = x2 + 2 -- one space between tabs
  end

  return { tabs = tabs, text = table.concat(parts, " "), y = y }
end

-- Which page index (if any) was tapped on the tab strip.
function console.tabHit(tabStrip, x, y)
  if type(tabStrip) ~= "table" or y ~= tabStrip.y then return nil end
  for _, t in ipairs(tabStrip.tabs or {}) do
    if x >= t.x1 and x <= t.x2 then return t.page end
  end
  return nil
end

-- rows: array of { y = <screen row>, entry = <opaque> }. Returns the entry whose
-- row matches y, or nil. The renderer only adds rows that are actionable.
function console.rowHit(rows, y)
  for _, r in ipairs(rows or {}) do
    if r.y == y then return r.entry end
  end
  return nil
end

-- Lay out a row of labeled buttons like "[-1] [+1] [SAVE]" at (startX, y).
-- specs: array of { label, key }. Returns { buttons = {{key,label,text,x1,x2,y}}, y }
-- for the renderer to draw `text` at (x1, y) and to keep for hit-testing.
function console.buttonRow(specs, y, startX, gap)
  y = y or 1
  local x = startX or 1
  gap = gap or 1
  local buttons = {}
  for _, spec in ipairs(specs or {}) do
    local text = "[" .. tostring(spec.label) .. "]"
    local x1 = x
    local x2 = x + #text - 1
    buttons[#buttons + 1] = { key = spec.key, label = spec.label, text = text, x1 = x1, x2 = x2, y = y }
    x = x2 + 1 + gap
  end
  return { buttons = buttons, y = y }
end

-- Which button key (if any) was tapped on a button row.
function console.buttonHit(row, x, y)
  if type(row) ~= "table" or y ~= row.y then return nil end
  for _, b in ipairs(row.buttons or {}) do
    if x >= b.x1 and x <= b.x2 then return b.key end
  end
  return nil
end

-- Page math for a scrollable list. Clamps `page` into range and returns the
-- 1-based slice [from, to] to render (an empty list yields from=1, to=0 so a
-- `for i = from, to` loop runs zero times).
function console.paginate(total, perPage, page)
  total = math.max(0, math.floor(tonumber(total) or 0))
  perPage = math.max(1, math.floor(tonumber(perPage) or 1))
  page = math.floor(tonumber(page) or 1)

  local pages = math.max(1, math.ceil(total / perPage))
  if page < 1 then page = 1 end
  if page > pages then page = pages end

  local from = (page - 1) * perPage + 1
  local to = math.min(total, page * perPage)
  return { page = page, pages = pages, perPage = perPage, from = from, to = to, total = total }
end

return console
