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
