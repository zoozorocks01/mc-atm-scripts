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

-- analyze(history, ctx) -> array of suggestions:
--   { kind = "quota", name, label, target, craftTo, reason }
-- ctx: { managed = {[name]=true}, dismissed = {[name]=true},
--        minDrain = 64, minWindowMs = 60000, max = 8 }
-- A suggestion fires when an UNMANAGED item has net-declined by >= minDrain over a
-- window of >= minWindowMs. Proposed quota holds near the observed low with a
-- ~5-minute refill buffer above it.
function suggest.analyze(history, ctx)
  ctx = ctx or {}
  local managedSet = ctx.managed or {}
  local dismissed = ctx.dismissed or {}
  local minDrain = tonumber(ctx.minDrain) or 64
  local minWindow = tonumber(ctx.minWindowMs) or 60000

  local out = {}
  for name, h in pairs(history or {}) do
    if not managedSet[name] and not dismissed[name] then
      local span = (h.tN or 0) - (h.t0 or 0)
      local decline = (h.a0 or 0) - (h.aN or 0)
      if span >= minWindow and decline >= minDrain then
        local perMin = decline / (span / 60000)
        local target = math.max(0, math.floor(h.minA or 0))
        local craftTo = target + math.max(minDrain, math.floor(perMin * 5))
        out[#out + 1] = {
          kind = "quota",
          name = name,
          label = h.label or name,
          target = target,
          craftTo = craftTo,
          reason = "down " .. decline .. " in " .. math.max(1, math.floor(span / 60000)) .. "m",
          _rank = decline,
        }
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
