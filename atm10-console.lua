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

return console
