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

-- Display profiles for read-only viewer (inventory-remote) screens. A viewer
-- computer picks one via a one-line `atm10-display` file (installed once, survives
-- updates), like the theme file. Resolves to the default ("view") when missing or
-- invalid; comment lines (# or --) are skipped.
console.PROFILES = { view = true, autocraft = true, alerts = true }
console.defaultProfile = "view"
console.profileFile = "atm10-display"

function console.resolveProfile(override)
  if type(override) == "string" and console.PROFILES[override] then
    return override
  end

  if fs and fs.exists and fs.exists(console.profileFile) then
    local file = fs.open(console.profileFile, "r")
    if file then
      local raw = file.readAll() or ""
      file.close()
      for chunk in string.gmatch(raw, "[^\r\n]+") do
        local name = chunk:gsub("%-%-.*$", ""):gsub("#.*$", ""):gsub("%s+", "")
        if name ~= "" and console.PROFILES[name] then
          return name
        end
      end
    end
  end

  return console.defaultProfile
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

-- Bounded array slice (VIEW-1): the first min(limit, #list) elements as a new
-- array. Caps a broadcast payload regardless of grid size (~5.9k items), so the
-- viewer gets a fuller list than the 8-item teaser without flooding rednet.
function console.boundedSlice(list, limit)
  local out = {}
  if type(list) ~= "table" then return out end
  local n = math.min(math.max(0, math.floor(tonumber(limit) or 0)), #list)
  for i = 1, n do out[i] = list[i] end
  return out
end

-- Selectable viewer/Browse sort modes (VIEW-3). "Craftable" is intentionally
-- omitted: isCraftable reads blind on this pack (see CRAFT-3), so it can't be a
-- trustworthy sort key.
console.SORT_MODES = { "qty", "az", "mod" }
local SORT_LABELS = { qty = "Qty", az = "A-Z", mod = "Mod" }

function console.sortLabel(mode) return SORT_LABELS[mode] or "Qty" end

-- The next mode in the cycle (wraps). Unknown -> first mode.
function console.nextSort(mode)
  for i, m in ipairs(console.SORT_MODES) do
    if m == mode then return console.SORT_MODES[(i % #console.SORT_MODES) + 1] end
  end
  return console.SORT_MODES[1]
end

-- Sort an item list IN PLACE by mode. `acc` supplies accessors for non-default
-- item shapes; defaults read it.name / it.amount / it.id (the compactItems
-- broadcast shape). qty: amount desc (default). az: display name asc.
-- mod: registry namespace asc, then name.
function console.sortItems(items, mode, acc)
  if type(items) ~= "table" then return items end
  acc = acc or {}
  local getName = acc.name or function(it) return it.name end
  local getAmount = acc.amount or function(it) return it.amount end
  local getId = acc.id or function(it) return it.id or it.name end
  local function lname(it) return tostring(getName(it) or ""):lower() end
  local function ns(it) local id = tostring(getId(it) or ""); return (id:match("^([^:]+):") or id):lower() end

  if mode == "az" then
    table.sort(items, function(a, b) return lname(a) < lname(b) end)
  elseif mode == "mod" then
    table.sort(items, function(a, b)
      local na, nb = ns(a), ns(b)
      if na ~= nb then return na < nb end
      return lname(a) < lname(b)
    end)
  else
    table.sort(items, function(a, b) return (tonumber(getAmount(a)) or 0) > (tonumber(getAmount(b)) or 0) end)
  end
  return items
end

return console
