-- Smart-mode suggestion engine. Tracks item amounts over time and proposes
-- recurring quotas for items that keep draining. Pure logic: no peripherals/fs.
-- The manager feeds snapshots each scan and keeps the history in memory.
--
-- OFF BY DEFAULT: the manager only records + analyzes when smart mode is enabled
-- (via the zoozo-late-game profile or a manual toggle), so a generic install does
-- nothing here. Suggestions are advisory — accepting one just opens the normal
-- quota editor, pre-seeded; nothing is auto-applied unless the operator confirms.
local suggest = {}

-- history: { [name] = { label, t0, a0, tN, aN, minA, n } }
-- record one snapshot. snapshot: array of { name, label, amount }.
function suggest.record(history, snapshot, now)
  history = history or {}
  now = tonumber(now) or 0
  for _, it in ipairs(snapshot or {}) do
    local name = it.name
    if name then
      local amt = tonumber(it.amount) or 0
      local h = history[name]
      if not h then
        history[name] = { label = it.label or name, t0 = now, a0 = amt, tN = now, aN = amt, minA = amt, n = 1 }
      else
        h.tN = now
        h.aN = amt
        h.n = h.n + 1
        if amt < h.minA then h.minA = amt end
        if it.label then h.label = it.label end
      end
    end
  end
  return history
end

-- Bound the (now persisted) history so it neither grows without limit nor lets an
-- item's window stretch over its whole lifetime. Call before saving.
--   maxAgeMs    : drop an entry not seen within this window (item left the grid)
--   maxWindowMs : restart an entry's window (t0/a0/minA/n) once its span exceeds
--                 this, so analyze() measures recent behavior, not all-time drain
--   maxEntries  : hard cap; drop the least-recently-seen beyond it
-- Returns history and the number of entries removed. (0 for any option disables it.)
function suggest.prune(history, now, opts)
  history = history or {}
  opts = opts or {}
  now = tonumber(now) or 0
  local maxAgeMs = tonumber(opts.maxAgeMs) or 0
  local maxWindowMs = tonumber(opts.maxWindowMs) or 0
  local maxEntries = tonumber(opts.maxEntries) or 0
  local removed = 0

  for name, h in pairs(history) do
    if maxAgeMs > 0 and (now - (h.tN or 0)) > maxAgeMs then
      history[name] = nil
      removed = removed + 1
    elseif maxWindowMs > 0 and ((h.tN or 0) - (h.t0 or 0)) > maxWindowMs then
      -- restart the window at the latest sample so drain reflects recent time
      h.t0, h.a0, h.minA, h.n = h.tN or now, h.aN or 0, h.aN or 0, 1
    end
  end

  if maxEntries > 0 then
    local arr = {}
    for name, h in pairs(history) do arr[#arr + 1] = { name = name, tN = h.tN or 0, n = h.n or 0 } end
    if #arr > maxEntries then
      -- keep the most-SAMPLED entries (consistently-present items carry the real
      -- drain signal); recency breaks ties. This bounds the persisted file on the
      -- CC computer's ~1MB disk -- a base has thousands of items, only a fraction move.
      table.sort(arr, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.tN > b.tN
      end)
      for i = maxEntries + 1, #arr do
        history[arr[i].name] = nil
        removed = removed + 1
      end
    end
  end

  return history, removed
end

-- Bound the operator's dismissed-suggestion set the same way the trend history is
-- bounded: it persists on the same ~1MB CC disk and would otherwise grow forever
-- (each "clear all" only ever ADDS names). Values are dismissal timestamps; legacy
-- boolean-true entries are normalized to `now`. Age out entries older than maxAgeMs
-- (drain may have changed -> let the suggestion return) and, if still over
-- maxEntries, drop the OLDEST. Returns a NEW set and the number removed. (0 for an
-- option disables it.)
function suggest.pruneDismissed(set, now, opts)
  opts = opts or {}
  now = tonumber(now) or 0
  local maxAgeMs = tonumber(opts.maxAgeMs) or 0
  local maxEntries = tonumber(opts.maxEntries) or 0

  local total, kept = 0, {}
  for name, ts in pairs(set or {}) do
    total = total + 1
    if type(ts) ~= "number" then ts = now end -- legacy boolean `true` -> timestamp
    if maxAgeMs <= 0 or (now - ts) <= maxAgeMs then
      kept[#kept + 1] = { name = name, ts = ts }
    end
  end

  if maxEntries > 0 and #kept > maxEntries then
    table.sort(kept, function(a, b) return a.ts > b.ts end) -- newest first
    for i = #kept, maxEntries + 1, -1 do kept[i] = nil end  -- keep the newest maxEntries
  end

  local out, count = {}, 0
  for _, e in ipairs(kept) do out[e.name] = e.ts; count = count + 1 end
  return out, total - count
end

-- VIEW-5: compact per-item trend from the recorded history. Returns
-- { dir = "up"|"down"|"flat", perMin = number } or nil when there's no usable
-- history, so callers HIDE it rather than error (smart mode off / item unseen).
-- up = filling, down = draining. Reuses the same data analyze() already collects --
-- no new bridge calls.
function suggest.trend(history, name, opts)
  local h = history and history[name]
  if type(h) ~= "table" then return nil end
  local span = (tonumber(h.tN) or 0) - (tonumber(h.t0) or 0)
  if span <= 0 then return nil end
  opts = opts or {}
  local flat = tonumber(opts.flatPerMin) or 1
  local delta = (tonumber(h.aN) or 0) - (tonumber(h.a0) or 0)
  local perMin = delta / (span / 60000)
  local dir = "flat"
  if perMin >= flat then dir = "up" elseif perMin <= -flat then dir = "down" end
  return { dir = dir, perMin = perMin }
end

local function mins(span) return math.max(1, math.floor(span / 60000)) end

-- analyze(history, ctx) -> array of suggestions (each seeded for the editor):
--   { kind, name, label, seeded=true, target, craftTo, ceiling?, reason }
-- ctx: { managed = {[name]=true}, quotas = {[name]={target,craftTo}},
--        dismissed = {[name]=true}, minDrain = 64, minWindowMs = 60000, max = 8 }
--
-- Over a window of >= minWindowMs:
--   * UNMANAGED + net decline >= minDrain  -> "quota": keep it stocked.
--   * UNMANAGED + net growth  >= minDrain  -> "cap":   set a compress ceiling.
--   * MANAGED (has quota) + below target the whole window + still draining
--                                          -> "raise": refill can't keep up.
function suggest.analyze(history, ctx)
  ctx = ctx or {}
  local managedSet = ctx.managed or {}
  local quotas = ctx.quotas or {}
  local dismissed = ctx.dismissed or {}
  local minDrain = tonumber(ctx.minDrain) or 64
  local minWindow = tonumber(ctx.minWindowMs) or 60000

  local out = {}
  for name, h in pairs(history or {}) do
    if not dismissed[name] then
      local span = (h.tN or 0) - (h.t0 or 0)
      if span >= minWindow then
        local decline = (h.a0 or 0) - (h.aN or 0)
        local perMin = math.abs(decline) / (span / 60000)
        local q = quotas[name]
        local isManaged = managedSet[name] == true or q ~= nil

        if not isManaged and decline >= minDrain then
          local target = math.max(0, math.floor(h.minA or 0))
          out[#out + 1] = {
            kind = "quota", name = name, label = h.label or name, seeded = true,
            target = target, craftTo = target + math.max(minDrain, math.floor(perMin * 5)),
            reason = "down " .. decline .. " in " .. mins(span) .. "m", _rank = decline,
          }
        elseif not isManaged and -decline >= minDrain then
          out[#out + 1] = {
            kind = "cap", name = name, label = h.label or name, seeded = true,
            target = 0, craftTo = 0, ceiling = math.max(0, math.floor(h.aN or 0)),
            reason = "up " .. (-decline) .. " in " .. mins(span) .. "m", _rank = -decline,
          }
        elseif q and decline >= minDrain
            and (h.aN or 0) < (q.target or 0) and (h.a0 or 0) < (q.target or 0) then
          local proposed = (q.target or 0) + math.max(minDrain, math.floor(perMin * 5))
          if proposed > (q.craftTo or 0) then
            out[#out + 1] = {
              kind = "raise", name = name, label = h.label or name, seeded = true,
              target = q.target, craftTo = proposed,
              reason = "below target, still draining", _rank = decline,
            }
          end
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a._rank ~= b._rank then return a._rank > b._rank end
    return tostring(a.name) < tostring(b.name)
  end)

  local max = tonumber(ctx.max) or 8
  while #out > max do table.remove(out) end
  for _, s in ipairs(out) do s._rank = nil end
  return out
end

return suggest
