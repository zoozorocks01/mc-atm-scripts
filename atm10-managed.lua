-- Operator-set stock quotas, built by tapping items on the console (no hand-edited
-- registry IDs). Persisted by the manager like the queue/ledger. Pure logic: no
-- peripherals/fs, so it is unit-tested off-CC (see tests/run.lua).
--
-- This store is MERGED INTO the planner alongside the hand-edited config (as a
-- synthetic "Tapped" category) so the two sources coexist and config is never
-- clobbered. Presence of any managed item is enough to enable planning.
local managed = {}

function managed.new()
  return { items = {} }
end

-- Coerce a loaded/garbage value into shape (fail-safe).
function managed.normalize(store)
  if type(store) ~= "table" or type(store.items) ~= "table" then
    return { items = {} }
  end
  return store
end

-- Add or update a quota. target/craftTo are clamped to sane values
-- (target >= 0, craftTo >= max(target, 1)) so a saved quota always plans a
-- positive request when below target. Deduped by registry name. No-op without a name.
function managed.set(store, entry, now)
  store = managed.normalize(store)
  local name = entry and entry.name
  if not name then return store end

  -- Merge over any existing entry so a partial edit (e.g. floor only) preserves
  -- the overflow config, and vice versa.
  local prev = store.items[name] or {}
  local target = math.max(0, math.floor(tonumber(entry.target) or prev.target or 0))
  local craftTo = math.max(target, 1, math.floor(tonumber(entry.craftTo) or prev.craftTo or 0))

  local item = {
    name = name,
    label = entry.label or prev.label or name,
    target = target,
    craftTo = craftTo,
    addedAt = tonumber(now) or prev.addedAt or 0,
  }

  -- Optional overflow/compress config: ceiling + the denser "into" item it
  -- compresses to, with `ratio` source units per crafted unit. Update if
  -- provided, otherwise carry forward.
  local ceiling = entry.ceiling
  if ceiling == nil then ceiling = prev.ceiling end
  if ceiling ~= nil then item.ceiling = math.max(0, math.floor(tonumber(ceiling) or 0)) end

  local into = entry.into
  if into == nil then into = prev.into end
  if type(into) == "table" and into.name then
    item.into = { name = into.name, label = into.label or into.name }
    item.ratio = math.max(1, math.floor(tonumber(entry.ratio) or prev.ratio or 1))
  end

  item.adjusted = nil
  item.invalid = nil
  if item.ceiling and item.ceiling > 0 and item.into and item.into.name then
    if item.ceiling <= item.target then
      item.invalid = "ceiling must be greater than target"
    elseif item.craftTo >= item.ceiling then
      item.adjusted = {
        field = "craftTo",
        from = item.craftTo,
        to = item.ceiling - 1,
        reason = "craftTo lowered below ceiling",
      }
      item.craftTo = item.ceiling - 1
    end
  end

  store.items[name] = item
  return store
end

function managed.remove(store, name)
  store = managed.normalize(store)
  store.items[name] = nil
  return store
end

-- Profile-level settings (e.g. smartMode), persisted alongside the quotas.
function managed.getSetting(store, key)
  store = managed.normalize(store)
  return type(store.settings) == "table" and store.settings[key] or nil
end

function managed.setSetting(store, key, value)
  store = managed.normalize(store)
  if type(store.settings) ~= "table" then store.settings = {} end
  store.settings[key] = value
  return store
end

-- Drop just the overflow/compress config, keeping the floor quota.
function managed.clearOverflow(store, name)
  store = managed.normalize(store)
  local e = store.items[name]
  if e then e.ceiling, e.into, e.ratio, e.adjusted, e.invalid = nil, nil, nil, nil, nil end
  return store
end

-- Items that have a configured overflow chain (ceiling + into), for the balancer.
function managed.overflowItems(store)
  local out = {}
  for _, e in ipairs(managed.list(store)) do
    if not e.invalid and e.ceiling and type(e.into) == "table" and e.into.name then out[#out + 1] = e end
  end
  return out
end

function managed.get(store, name)
  store = managed.normalize(store)
  return store.items[name]
end

function managed.has(store, name)
  return managed.get(store, name) ~= nil
end

function managed.count(store)
  store = managed.normalize(store)
  local n = 0
  for _ in pairs(store.items) do n = n + 1 end
  return n
end

-- CRAFT-3 helper: how many managed quotas reference an item that is NOT in the
-- live grid (itemsByName, keyed by registry name). Presence in getItems is the
-- only trustworthy "exists" signal (the CC export reports craftable_rows=0 even
-- for items that craft fine), so a quota missing here is a typo / version-drift
-- ID or an item never stocked. Pure: itemsByName is { [name] = item }. Hoisted
-- out of the per-render PLAN draw -- its inputs only change on scan.
function managed.countNotInGrid(store, itemsByName)
  store = managed.normalize(store)
  itemsByName = itemsByName or {}
  local n = 0
  for _, e in pairs(store.items) do
    if e.name and not itemsByName[e.name] then n = n + 1 end
  end
  return n
end

-- Items as an array, sorted by label then name (stable display order).
function managed.list(store)
  store = managed.normalize(store)
  local out = {}
  for _, e in pairs(store.items) do out[#out + 1] = e end
  table.sort(out, function(a, b)
    local la, lb = tostring(a.label or a.name), tostring(b.label or b.name)
    if la ~= lb then return la < lb end
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

-- A planner category for the managed items, or nil when the store is empty.
function managed.toCategory(store, label)
  local items = managed.list(store)
  if #items == 0 then return nil end
  local categoryItems = {}
  for _, e in ipairs(items) do
    categoryItems[#categoryItems + 1] = {
      name = e.name, label = e.label, target = e.target, craftTo = e.craftTo,
      ceiling = e.ceiling, into = e.into, ratio = e.ratio,
      adjusted = e.adjusted, invalid = e.invalid,
    }
  end
  return { label = label or "Tapped", items = categoryItems }
end

-- CRAFT-4: from a combined quota list (config categories + the tapped store), which
-- items RS cannot craft yet -- i.e. patterns you still need to build. Pure:
--   items       = { { name, label, category } ... }
--   isCraftable = function(name) -> bool
-- Returns the non-craftable subset, sorted by category then label -- a shrinking
-- checklist of patterns to encode.
function managed.patternsNeeded(items, isCraftable)
  isCraftable = isCraftable or function() return false end
  local out, seen = {}, {}
  for _, it in ipairs(items or {}) do
    -- dedup by registry name; FIRST occurrence wins, so callers that list config
    -- categories before the tapped store keep the categorized (overflow-aware) entry.
    if it and it.name and not seen[it.name] and not isCraftable(it.name) then
      seen[it.name] = true
      out[#out + 1] = { name = it.name, label = it.label or it.name, category = it.category or "Uncategorized" }
    end
  end
  table.sort(out, function(a, b)
    if a.category ~= b.category then return tostring(a.category) < tostring(b.category) end
    return tostring(a.label):lower() < tostring(b.label):lower()
  end)
  return out
end

return managed
