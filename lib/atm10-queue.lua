-- Manual-mode craft queue: a persistent record of craft requests the operator
-- has approved. Pure logic (no peripherals/fs); the manager owns persistence.
--
-- IMPORTANT: in the current build NOTHING crafts. Approving an item only records
-- intent here. The craft chokepoint (requestCraft) stays inert until the safety
-- gates ship, so this queue is the staging area that proves the manual flow.
local queue = {}

queue.APPROVED = "APPROVED" -- operator approved; awaiting the craft request
queue.CRAFTING = "CRAFTING" -- craft request accepted by RS; awaiting completion

function queue.new()
  return { entries = {} }
end

-- Coerce a loaded/garbage value into the expected shape (fail-safe).
function queue.normalize(q)
  if type(q) ~= "table" or type(q.entries) ~= "table" then
    return { entries = {} }
  end
  return q
end

-- Approve (or refresh) a craft request for an item. Deduped by registry name.
function queue.approve(q, entry, now)
  q = queue.normalize(q)
  local name = entry and entry.name
  if not name then return q end

  q.entries[name] = {
    name = name,
    label = entry.label or name,
    request = tonumber(entry.request) or 0,
    state = queue.APPROVED,
    approvedAt = tonumber(now) or 0,
  }
  return q
end

function queue.cancel(q, name)
  q = queue.normalize(q)
  q.entries[name] = nil
  return q
end

-- Mark an entry as in-flight (craft request accepted). Clears any prior error.
-- No-op if the entry is absent.
function queue.markCrafting(q, name, now)
  q = queue.normalize(q)
  local e = q.entries[name]
  if not e then return q end
  e.state = queue.CRAFTING
  e.craftingAt = tonumber(now) or 0
  e.error = nil
  return q
end

-- Record a failed craft attempt. The entry stays APPROVED (so it retries after
-- the runner's backoff); triedAt stamps the backoff start. No-op if absent.
function queue.markError(q, name, now, reason)
  q = queue.normalize(q)
  local e = q.entries[name]
  if not e then return q end
  e.triedAt = tonumber(now) or 0
  e.error = reason and tostring(reason) or "craft failed"
  return q
end

function queue.has(q, name)
  q = queue.normalize(q)
  return q.entries[name] ~= nil
end

function queue.count(q)
  q = queue.normalize(q)
  local n = 0
  for _ in pairs(q.entries) do n = n + 1 end
  return n
end

-- Entries as an array, newest approvals first (stable tiebreak by name).
function queue.list(q)
  q = queue.normalize(q)
  local out = {}
  for _, e in pairs(q.entries) do out[#out + 1] = e end
  table.sort(out, function(a, b)
    if (a.approvedAt or 0) ~= (b.approvedAt or 0) then
      return (a.approvedAt or 0) > (b.approvedAt or 0)
    end
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

-- Drop entries whose item is now satisfied (stock recovered / no longer planned).
-- `satisfied` is a set { [name] = true }. Returns the queue and the count removed.
function queue.reconcile(q, satisfied)
  q = queue.normalize(q)
  satisfied = satisfied or {}
  local removed = 0
  for name in pairs(q.entries) do
    if satisfied[name] then
      q.entries[name] = nil
      removed = removed + 1
    end
  end
  return q, removed
end

-- Age out stale approvals so the queue stays bounded. maxAgeMs <= 0 disables it.
-- Returns the queue and the count removed.
function queue.prune(q, now, maxAgeMs)
  q = queue.normalize(q)
  now = tonumber(now) or 0
  maxAgeMs = tonumber(maxAgeMs) or 0
  if maxAgeMs <= 0 then return q, 0 end

  local removed = 0
  for name, e in pairs(q.entries) do
    if (now - (e.approvedAt or 0)) > maxAgeMs then
      q.entries[name] = nil
      removed = removed + 1
    end
  end
  return q, removed
end

return queue
