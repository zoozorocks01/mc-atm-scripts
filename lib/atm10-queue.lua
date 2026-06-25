-- Manual-mode craft queue: a persistent record of craft requests the operator
-- has approved. Pure logic (no peripherals/fs); the manager owns persistence.
--
-- IMPORTANT: in the current build NOTHING crafts. Approving an item only records
-- intent here. The craft chokepoint (requestCraft) stays inert until the safety
-- gates ship, so this queue is the staging area that proves the manual flow.
local queue = {}

queue.APPROVED = "APPROVED" -- operator approved; awaiting the craft request
queue.CRAFTING = "CRAFTING" -- craft request accepted by RS; awaiting completion

local function copyPlanFields(dest, entry)
  dest.label = entry.label or dest.label or entry.name or dest.name
  dest.request = tonumber(entry.request) or dest.request or 0
  dest.priority = tonumber(entry.priority) or 0
  dest.amount = tonumber(entry.amount)
  dest.target = tonumber(entry.target)
  dest.category = entry.category
  dest.craftTo = tonumber(entry.craftTo)
  dest.banded = entry.banded == true
  dest.adjusted = entry.adjusted == true
  dest.reason = entry.reason
  dest.kind = entry.kind or dest.kind -- preserve compress/void row identity (e.g. "compress")
  return dest
end

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

-- Approve (or refresh) a craft request. Deduped by `key` (defaults to the
-- registry name). A distinct key lets two requests that craft the SAME item not
-- alias each other -- e.g. a refill (key=name) and a compress/overflow request
-- (key="compress:<name>") both craft `name` but stay separate queue entries.
function queue.approve(q, entry, now)
  q = queue.normalize(q)
  local name = entry and entry.name
  if not name then return q end
  local key = entry.key or name

  q.entries[key] = copyPlanFields({
    key = key,
    name = name,
    state = queue.APPROVED,
    approvedAt = tonumber(now) or 0,
  }, entry)
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

-- The entry stored under a key (defaults to the registry name), or nil. Read-only
-- lookup so callers can branch on an entry's state without reaching into .entries.
function queue.get(q, name)
  q = queue.normalize(q)
  if name == nil then return nil end
  return q.entries[name]
end

-- AUTO MODE: approve every craftable deficit in one pass. For each plan row whose
-- action is "WOULD CRAFT" with a positive request, approve it UNLESS it is already
-- APPROVED-and-waiting (re-approving would only churn its timestamp + reorder the
-- queue every cycle). An absent entry is approved; a CRAFTING entry is re-armed --
-- a row that reads WOULD CRAFT again means RS finished it and the quota still wants
-- the next batch. Returns the queue and the number of entries (re)approved.
--
-- Pure: the manager owns the mode gate, the ledger COOLDOWN (which keeps an item
-- from reading WOULD CRAFT again until its window passes, bounding re-fire), and
-- persistence. plans rows are the stock/balance planner shape {action,name,label,
-- request,key?}.
function queue.autoApprove(q, plans, now)
  q = queue.normalize(q)
  local n = 0
  for _, p in ipairs(plans or {}) do
    if p and p.action == "WOULD CRAFT" and p.name and (tonumber(p.request) or 0) > 0 then
      local key = p.key or p.name
      local cur = q.entries[key]
      if not cur or cur.state ~= queue.APPROVED then
        queue.approve(q, p, now)
        n = n + 1
      else
        copyPlanFields(cur, p)
      end
    end
  end
  return q, n
end

function queue.count(q)
  q = queue.normalize(q)
  local n = 0
  for _ in pairs(q.entries) do n = n + 1 end
  return n
end

-- Entries as an array, newest approvals first (stable tiebreak by name). When
-- opts.priority is true, APPROVED entries with a higher deficit priority sort
-- first so the craft runner's per-cycle cap fires the most urgent quotas.
function queue.list(q, opts)
  q = queue.normalize(q)
  opts = opts or {}
  local out = {}
  for _, e in pairs(q.entries) do out[#out + 1] = e end
  table.sort(out, function(a, b)
    if opts.priority == true then
      local aa, ba = a.state == queue.APPROVED, b.state == queue.APPROVED
      if aa ~= ba then return aa end
      if aa and ba then
        local ap, bp = tonumber(a.priority) or 0, tonumber(b.priority) or 0
        if ap ~= bp then return ap > bp end
      end
    end
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

-- Per-item last-craft RESULT tracking (QUICK-5). Separate from the approval queue:
-- a bounded map { [name] = { ok=bool, reason=string?, at=ms } } the manager persists
-- so the operator can see whether an item's last craft request actually succeeded --
-- the approval entry itself is transient (it leaves on completion / the 30-min prune).
-- Pure: the manager owns the file.
function queue.recordResult(results, name, ok, reason, at)
  if type(results) ~= "table" or not name then return results or {} end
  local entry = { ok = ok == true, at = tonumber(at) or 0 }
  if not entry.ok then entry.reason = reason and tostring(reason) or "rejected" end
  results[name] = entry
  return results
end

-- Keep the newest `max` results by `at` (drop-oldest), bounding the on-disk file.
-- max <= 0 disables the cap. Returns results and the count removed.
function queue.pruneResults(results, max)
  if type(results) ~= "table" then return {}, 0 end
  max = tonumber(max) or 0
  if max <= 0 then return results, 0 end
  local arr, total = {}, 0
  for name, r in pairs(results) do
    total = total + 1
    arr[#arr + 1] = { name = name, at = tonumber(r and r.at) or 0 }
  end
  if total <= max then return results, 0 end
  table.sort(arr, function(a, b) return a.at > b.at end) -- newest first
  local removed = 0
  for i = max + 1, total do
    results[arr[i].name] = nil
    removed = removed + 1
  end
  return results, removed
end

return queue
