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
-- tol (optional) widens the vertical hit window: a tap within `tol` rows of the
-- strip still counts (the tab strip's neighbour rows are non-interactive, so this
-- is a free precision boost on a finicky monitor). x must still be within a tab.
function console.tabHit(tabStrip, x, y, tol)
  if type(tabStrip) ~= "table" then return nil end
  if math.abs(y - tabStrip.y) > (tonumber(tol) or 0) then return nil end
  for _, t in ipairs(tabStrip.tabs or {}) do
    if x >= t.x1 and x <= t.x2 then return t.page end
  end
  return nil
end

-- rows: array of { y = <screen row>, entry = <opaque> }. Returns the entry whose
-- row matches y, or nil. The renderer only adds rows that are actionable.
-- tol (optional, default 0 = exact) makes a near-miss SNAP to the nearest actionable
-- row within `tol` rows -- so a tap a row or two off a list item still selects it.
-- Ties resolve to the first row encountered (deterministic).
function console.rowHit(rows, y, tol)
  tol = tonumber(tol) or 0
  local best, bestDist
  for _, r in ipairs(rows or {}) do
    local d = math.abs(r.y - y)
    if d <= tol and (not bestDist or d < bestDist) then
      best, bestDist = r.entry, d
    end
  end
  return best
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

-- ===========================================================================
-- A2 REQUEST-PANEL helpers. Pure browse/quantity/job-row logic for the new
-- craft-request touch program (inventory/request.lua). No peripherals; unit
-- tested in tests/run.lua. The program does the rendering + hit-testing; these
-- supply the data shapes + the filtering/clamping/formatting math.
-- ===========================================================================

-- Case-insensitive substring filter over BOTH the display name and the registry
-- id. An empty/nil query returns the list UNCHANGED (a NEW array; never mutates
-- the input). `acc` supplies non-default accessors (same shape as sortItems).
function console.filterItems(items, query, acc)
  if type(items) ~= "table" then return {} end
  acc = acc or {}
  local getName = acc.name or function(it) return it.name end
  local getId = acc.id or function(it) return it.id or it.name end

  local out = {}
  local q = (type(query) == "string") and query:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
  if q == "" then
    for i = 1, #items do out[i] = items[i] end
    return out
  end

  for _, it in ipairs(items) do
    local name = tostring(getName(it) or ""):lower()
    local id = tostring(getId(it) or ""):lower()
    if name:find(q, 1, true) or id:find(q, 1, true) then
      out[#out + 1] = it
    end
  end
  return out
end

-- Clamp a request quantity into [min, max]. opts.min (default 1) / opts.max
-- (default 99999) override. A non-numeric `current` snaps to min, then delta is
-- applied. Mirrors the paginate clamp discipline.
function console.stepQuantity(current, delta, opts)
  opts = opts or {}
  local min = math.floor(tonumber(opts.min) or 1)
  local max = math.floor(tonumber(opts.max) or 99999)
  if max < min then max = min end
  local n = math.floor(tonumber(current) or min)
  n = n + math.floor(tonumber(delta) or 0)
  if n < min then n = min end
  if n > max then n = max end
  return n
end

-- The quantity step buttons offered on the detail screen.
console.quantitySteps = { 1, 8, 16, 64, 256, 1024 }

-- Build the quantity picker button row: [-1024][-64]...[-1] [qty] [+1]...[+1024]
-- [SUBMIT], laid out via buttonRow so buttonHit works unchanged. Decrement keys
-- are "dec:<n>", increments "inc:<n>", the SUBMIT key is "submit"; the current
-- quantity is a non-actionable display cell (key "qty"). `qty` is rendered into
-- the display cell's label. Layout only -- the program does the draw call.
function console.quantityButtonRow(qty, y, startX)
  local specs = {}
  for i = #console.quantitySteps, 1, -1 do
    specs[#specs + 1] = { label = "-" .. console.quantitySteps[i], key = "dec:" .. console.quantitySteps[i] }
  end
  specs[#specs + 1] = { label = tostring(math.floor(tonumber(qty) or 1)), key = "qty" }
  for i = 1, #console.quantitySteps do
    specs[#specs + 1] = { label = "+" .. console.quantitySteps[i], key = "inc:" .. console.quantitySteps[i] }
  end
  specs[#specs + 1] = { label = "SUBMIT", key = "submit" }
  return console.buttonRow(specs, y, startX or 1)
end

-- Map a craftQueue / manual-job entry to a short live-progress status label.
-- Recognizes the manual-job made/requested progress (A1) and the queue states.
-- Pure; the program colors it via console.jobRowFormat's colorKey.
function console.requestStatusLabel(entry)
  if type(entry) ~= "table" then return "queued" end
  if entry.error or entry.failed then
    return "FAILED: " .. tostring(entry.error or entry.reason or "no recipe")
  end
  local requested = tonumber(entry.requested)
  local made = tonumber(entry.made)
  if requested and requested > 0 then
    if (made or 0) >= requested then return "done" end
    if entry.state == "CRAFTING" then return "crafting " .. (made or 0) .. "/" .. requested end
    return "queued " .. (made or 0) .. "/" .. requested
  end
  if entry.state == "CRAFTING" then return "crafting" end
  if entry.state == "APPROVED" then return "queued" end
  if entry.state == "done" then return "done" end
  return tostring(entry.state or "queued"):lower()
end

-- Format one live-progress row "<label>  +<request>  <STATUS>" fitted to width.
-- Returns { text, colorKey } where colorKey is one of "error"/"crafting"/
-- "done"/"queued" -> the program maps it to a uiStatus color at draw time.
function console.jobRowFormat(entry, width)
  width = math.max(1, math.floor(tonumber(width) or 1))
  entry = entry or {}
  local label = tostring(entry.label or entry.name or "?")
  local status = console.requestStatusLabel(entry)

  local colorKey = "queued"
  if entry.error or entry.failed or status:find("FAILED", 1, true) then colorKey = "error"
  elseif status:find("crafting", 1, true) then colorKey = "crafting"
  elseif status == "done" then colorKey = "done" end

  local request = tonumber(entry.request) or tonumber(entry.requested) or 0
  local text = label .. "  +" .. tostring(math.floor(request)) .. "  " .. status
  if #text > width then text = string.sub(text, 1, width) end
  return { text = text, colorKey = colorKey }
end

-- The one-line config file holding the control token this panel sends with each
-- craft request. Same pattern as resolveProfile/atm10-display: read the file,
-- skip comment lines (# or --), trim whitespace; missing => nil (the panel then
-- sends no token and the manager denies if it requires one -- safe default).
console.controlTokenFile = "atm10-control-token"

function console.resolveControlToken()
  if not (fs and fs.exists and fs.exists(console.controlTokenFile)) then return nil end
  local file = fs.open(console.controlTokenFile, "r")
  if not file then return nil end
  local raw = file.readAll() or ""
  file.close()
  for chunk in string.gmatch(raw, "[^\r\n]+") do
    local line = chunk:gsub("%-%-.*$", ""):gsub("#.*$", "")
    local token = line:gsub("^%s+", ""):gsub("%s+$", "")
    if token ~= "" then return token end
  end
  return nil
end

return console
