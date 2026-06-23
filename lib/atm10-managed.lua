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

  store.items[name] = item
  return store
end

function managed.remove(store, name)
  store = managed.normalize(store)
  store.items[name] = nil
  return store
end

-- Drop just the overflow/compress config, keeping the floor quota.
function managed.clearOverflow(store, name)
  store = managed.normalize(store)
  local e = store.items[name]
  if e then e.ceiling, e.into, e.ratio = nil, nil, nil end
  return store
end

-- Items that have a configured overflow chain (ceiling + into), for the balancer.
function managed.overflowItems(store)
  local out = {}
  for _, e in ipairs(managed.list(store)) do
    if e.ceiling and type(e.into) == "table" and e.into.name then out[#out + 1] = e end
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
    }
  end
  return { label = label or "Tapped", items = categoryItems }
end

return managed
