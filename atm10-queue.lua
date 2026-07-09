-- Manual-mode craft queue: a persistent record of craft requests the operator
-- has approved. Pure logic (no peripherals/fs); the manager owns persistence.
--
-- IMPORTANT: in the current build NOTHING crafts. Approving an item only records
-- intent here. The craft chokepoint (requestCraft) stays inert until the safety
-- gates ship, so this queue is the staging area that proves the manual flow.
local queue = {}

queue.APPROVED = "APPROVED" -- operator approved; awaiting the craft request
queue.CRAFTING = "CRAFTING" -- craft request accepted by RS; awaiting completion

-- A1: a transient "make N then done" job the operator requested explicitly. Tagged
-- kind=MANUAL; flows through the SAME approve -> list -> runner path as a quota refill
-- but carries job bookkeeping (requested = immutable target N, made = units fired so
-- far). craftFrom is still honored unless force is set. The runner leads with these.
queue.MANUAL = "manual" -- kind tag for a manual/oneshot craft job

local HARD_FAILURES = {
  MISSING_ITEMS = true,
  NOT_CRAFTABLE = true,
  UNKNOWN_ERROR = true,
}

function queue.isHardFailure(reasonOrEntry)
  local reason = reasonOrEntry
  if type(reasonOrEntry) == "table" then reason = reasonOrEntry.error end
  if reason == nil then return false end
  return HARD_FAILURES[string.upper(tostring(reason))] == true
end

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
  -- A1 manual-job fields: requested is the immutable target N; made accumulates units
  -- actually fired; force opts out of the craftFrom reserve; craftFrom is the source
  -- reserve rule the runner enforces (the planner never runs for a manual job). These
  -- carry through approve/autoApprove/copyPlanFields so a re-approve never resets made.
  dest.requested = tonumber(entry.requested) or dest.requested
  dest.made = tonumber(entry.made) or dest.made or 0
  dest.force = (entry.force == true) or dest.force == true or nil
  dest.manual = entry.manual == true or dest.manual == true or nil
  dest.craftFrom = entry.craftFrom or dest.craftFrom
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

  -- A1: carry forward a manual job's accumulated `made` (and target `requested`) from
  -- the existing entry under this key when the incoming refresh doesn't override them,
  -- so the manager re-approving a partial job each cycle never resets its progress.
  local prev = q.entries[key]
  local dest = {
    key = key,
    name = name,
    state = queue.APPROVED,
    approvedAt = tonumber(now) or 0,
  }
  if prev then
    dest.made = prev.made
    dest.requested = prev.requested
  end
  q.entries[key] = copyPlanFields(dest, entry)
  return q
end

function queue.cancel(q, name)
  q = queue.normalize(q)
  q.entries[name] = nil
  return q
end

-- A1: is this entry a manual/oneshot job? One place to change the tag test so the
-- runner + fireOrder + manager all agree on what a manual lane entry is.
function queue.isManual(e)
  return type(e) == "table" and e.kind == queue.MANUAL
end

-- A1: enqueue a manual job. The key defaults to "manual:<name>" so a job NEVER aliases
-- a quota of the same item (key=<name>): the two stay separate entries and the job
-- makes N EXTRA on top of the quota floor. requested is the target N; request (the
-- per-fire batch the runner sends) starts at the full remaining (requested - made).
-- Reuses queue.approve so all storage stays in one place. Returns q, key.
function queue.enqueueJob(q, entry, now)
  q = queue.normalize(q)
  entry = entry or {}
  local name = entry.name
  if not name then return q, nil end
  local requested = math.max(0, math.floor(tonumber(entry.requested) or tonumber(entry.request) or 0))
  local made = math.max(0, math.floor(tonumber(entry.made) or 0))
  local key = entry.key or ("manual:" .. tostring(name))
  queue.approve(q, {
    key = key,
    name = name,
    label = entry.label,
    kind = queue.MANUAL,
    manual = true,
    requested = requested,
    made = made,
    request = math.max(0, requested - made),
    force = (entry.force == true) or nil,
    craftFrom = entry.craftFrom,
  }, now)
  return q, key
end

-- A1: record that `n` units of a manual job actually fired (the runner calls this
-- after a successful bridge request). Accumulates made; no-op on a non-manual/absent
-- entry. Returns q.
function queue.recordMade(q, key, n, now)
  q = queue.normalize(q)
  local e = q.entries[key]
  if not queue.isManual(e) then return q end
  e.made = (tonumber(e.made) or 0) + (tonumber(n) or 0)
  e.lastMadeAt = tonumber(now) or 0
  return q
end

-- A1: has a manual job fired its full target? Pure predicate the runner/manager use
-- to drop the entry. True only for a manual entry whose made >= requested.
function queue.jobComplete(q, key)
  q = queue.normalize(q)
  local e = q.entries[key]
  if not queue.isManual(e) then return false end
  return (tonumber(e.made) or 0) >= (tonumber(e.requested) or 0)
end

-- A1: drop a job entry (alias of cancel, named for intent). Returns q and the dropped
-- entry so the manager can flash a completion line.
function queue.dropJob(q, key)
  q = queue.normalize(q)
  local e = q.entries[key]
  q.entries[key] = nil
  return q, e
end

-- Mark an entry as in-flight (craft request accepted). Clears any prior error.
-- No-op if the entry is absent.
function queue.markCrafting(q, name, now, inflightRequest, jobId)
  q = queue.normalize(q)
  local e = q.entries[name]
  if not e then return q end
  e.state = queue.CRAFTING
  e.craftingAt = tonumber(now) or 0
  if inflightRequest ~= nil then
    e.inflightRequest = math.max(0, math.floor(tonumber(inflightRequest) or 0))
  end
  if jobId ~= nil then e.jobId = jobId end
  e.error = nil
  -- A new attempt invalidates any previous failure's late-progress snapshot:
  -- stock gained from here on belongs to THIS batch, not the failed one.
  e.failedRequest, e.failedAmount, e.failedAt = nil, nil, nil
  return q
end

-- AP craft lifecycle events report only the craft job id. Keep the lookup here
-- so callers do not duplicate the queue-entry search or jobId string/number
-- normalization rules.
function queue.findByJobId(q, jobId)
  q = queue.normalize(q)
  if jobId == nil then return nil, nil end
  local want = tostring(jobId)
  for key, e in pairs(q.entries) do
    if type(e) == "table" and e.jobId ~= nil and tostring(e.jobId) == want then
      return key, e
    end
  end
  return nil, nil
end

local function copyEntry(e, key)
  local out = {}
  if type(e) == "table" then
    for k, v in pairs(e) do out[k] = v end
  end
  out.key = out.key or key
  return out
end

local function applyStockProgress(q, key, e, amountsByName, now)
  if type(e) ~= "table" then return q, nil, key, 0, false end
  amountsByName = type(amountsByName) == "table" and amountsByName or {}
  local current = tonumber(amountsByName[e.name] or amountsByName[key])
  local baseline = tonumber(e.amount)
  local made = 0
  if current and baseline and current > baseline then
    made = math.floor(current - baseline)
    local inflight = math.max(0, math.floor(tonumber(e.inflightRequest or e.request) or 0))
    if inflight > 0 and made > inflight then made = inflight end
  end
  if made <= 0 then return q, nil, key, 0, false end

  local original = copyEntry(e, key)
  local remaining = math.max(0, math.floor(tonumber(e.request) or 0) - made)
  if remaining > 0 then
    e.state = queue.APPROVED
    e.request = remaining
    e.amount = current
    e.approvedAt = tonumber(now) or 0
    e.craftingAt = nil
    e.craftingStartedAt = nil
    e.inflightRequest = nil
    e.jobId = nil
    e.error = nil
    -- progress consumed; a stale failure snapshot must not credit again later
    e.failedRequest, e.failedAmount, e.failedAt = nil, nil, nil
  else
    q.entries[key] = nil
  end
  return q, original, key, made, remaining <= 0
end

function queue.markJobStarted(q, jobId, now)
  local key, e = queue.findByJobId(q, jobId)
  if not e then return q, nil, nil end
  e.craftingStartedAt = e.craftingStartedAt or (tonumber(now) or 0)
  e.lastJobEventAt = tonumber(now) or 0
  e.error = nil
  return q, e, key
end

function queue.completeJobId(q, jobId)
  q = queue.normalize(q)
  local key, e = queue.findByJobId(q, jobId)
  if not e then return q, nil, nil end
  q.entries[key] = nil
  return q, e, key
end

function queue.failJobId(q, jobId, now, reason, amountsByName)
  local key, e = queue.findByJobId(q, jobId)
  if not e then return q, nil, nil end
  local original = copyEntry(e, key)
  e.state = queue.APPROVED
  e.triedAt = tonumber(now) or 0
  e.error = reason and tostring(reason) or "craft failed"
  e.craftingAt = nil
  e.craftingStartedAt = nil
  e.inflightRequest = nil
  e.jobId = nil
  -- Late-progress snapshot (docs/DECISIONS.md #3): AP can report "craft failed"
  -- for a job whose items land seconds LATER. Freeze the batch size and the
  -- stock level AT failure time so reconcileFailedRows can credit the late
  -- delivery. Deliberately separate fields from e.amount: auto-mode's plan
  -- refresh (copyPlanFields) overwrites e.amount every scan, which would bake
  -- the late gain into the baseline and hide it.
  local batch = math.max(0, math.floor(tonumber(original.inflightRequest) or 0))
  if batch > 0 and type(amountsByName) == "table" then
    local cur = tonumber(amountsByName[e.name] or amountsByName[key])
    if cur then
      e.failedRequest = batch
      e.failedAmount = cur
      e.failedAt = tonumber(now) or 0
    end
  end
  return q, original, key
end

-- A terminal AP failure can arrive after RS already completed a capped batch.
-- In that case stock increased even though the full queue entry is not done.
-- Treat it as progress, reduce the remaining request, and let the next batch
-- fire later instead of marking the row as a zero-progress failure.
function queue.progressJobId(q, jobId, amountsByName, now)
  q = queue.normalize(q)
  local key, e = queue.findByJobId(q, jobId)
  if not e then return q, nil, nil, 0, false end
  return applyStockProgress(q, key, e, amountsByName, now)
end

-- Record a failed craft attempt. The entry stays APPROVED (so it retries after
-- the runner's backoff); triedAt stamps the backoff start. No-op if absent.
function queue.markError(q, name, now, reason)
  q = queue.normalize(q)
  local e = q.entries[name]
  if not e then return q end
  e.triedAt = tonumber(now) or 0
  e.error = reason and tostring(reason) or "craft failed"
  e.jobId = nil
  return q
end

-- If a row has been marked CRAFTING but RS no longer reports an active task for
-- it and stock still has not reconciled it away, return it to APPROVED with a
-- retryable error. This covers AP accepting craftItem but not actually sustaining
-- a visible RS task. `activeByName` is an authoritative live-task map.
function queue.failInactiveCrafting(q, activeByName, now, graceMs, reason)
  q = queue.normalize(q)
  if type(activeByName) ~= "table" then return q, 0 end
  now = tonumber(now) or 0
  graceMs = math.max(0, tonumber(graceMs) or 0)
  local n = 0
  for key, e in pairs(q.entries) do
    if type(e) == "table" and e.state == queue.CRAFTING then
      local active = activeByName[e.name] or activeByName[key]
      local started = tonumber(e.craftingAt or e.approvedAt) or 0
      if not active and (now - started) >= graceMs then
        e.state = queue.APPROVED
        e.triedAt = now
        e.error = reason and tostring(reason) or "no active RS task"
        e.jobId = nil
        n = n + 1
      end
    end
  end
  return q, n
end

-- Like failInactiveCrafting, but a completed capped batch is not a stale failure
-- if stock increased since the entry was approved/last progressed. In that case,
-- reduce the remaining request, refresh the baseline amount, and return it to
-- APPROVED so the next batch can fire. Returns q, staleCount, progressedCount.
function queue.reconcileInactiveCrafting(q, activeByName, amountsByName, now, graceMs, reason)
  q = queue.normalize(q)
  if type(activeByName) ~= "table" then return q, 0, 0 end
  amountsByName = type(amountsByName) == "table" and amountsByName or {}
  now = tonumber(now) or 0
  graceMs = math.max(0, tonumber(graceMs) or 0)
  local stale, progressed = 0, 0
  for key, e in pairs(q.entries) do
    if type(e) == "table" and e.state == queue.CRAFTING then
      local active = activeByName[e.name] or activeByName[key]
      local started = tonumber(e.craftingAt or e.approvedAt) or 0
      if not active and (now - started) >= graceMs then
        local _, progressedEntry = applyStockProgress(q, key, e, amountsByName, now)
        if progressedEntry then
          progressed = progressed + 1
        else
          e.state = queue.APPROVED
          e.triedAt = now
          e.error = reason and tostring(reason) or "no active RS task"
          e.jobId = nil
          stale = stale + 1
        end
      end
    end
  end
  return q, stale, progressed
end

-- Late-progress reconcile (docs/DECISIONS.md #3): clear a quarantined row whose
-- failed batch DID deliver, just after the failure event was processed. Uses the
-- failure-time snapshot (failedAmount/failedRequest, stamped by failJobId), NOT
-- e.amount -- auto-mode's plan refresh overwrites e.amount every scan. Credit is
-- capped at the failed batch, so unrelated stock inflow can unlatch a row by at
-- most one batch (the same ambiguity AP-EVENT-3 progress already accepts; a
-- genuinely broken row just fails again on its next fire and re-latches).
-- Snapshots older than maxAgeMs expire without clearing the error (a delivery
-- that late is indistinguishable from ordinary production).
-- Returns q, cleared: { {key, name, made, remaining} } for audit/results.
function queue.reconcileFailedRows(q, amountsByName, now, maxAgeMs)
  q = queue.normalize(q)
  amountsByName = type(amountsByName) == "table" and amountsByName or {}
  now = tonumber(now) or 0
  local cleared = {}
  for key, e in pairs(q.entries) do
    if type(e) == "table" and e.state == queue.APPROVED and e.error
      and tonumber(e.failedRequest) and tonumber(e.failedAmount) then
      if maxAgeMs and (now - (tonumber(e.failedAt) or 0)) > maxAgeMs then
        e.failedRequest, e.failedAmount, e.failedAt = nil, nil, nil
      else
        local current = tonumber(amountsByName[e.name] or amountsByName[key])
        local made = 0
        if current and current > tonumber(e.failedAmount) then
          made = math.min(math.floor(current - e.failedAmount), math.floor(e.failedRequest))
        end
        if made > 0 then
          local remaining = math.max(0, math.floor(tonumber(e.request) or 0) - made)
          cleared[#cleared + 1] = { key = key, name = e.name, made = made, remaining = remaining }
          if remaining > 0 then
            e.request = remaining
            e.amount = current
            e.approvedAt = now
            e.triedAt = nil -- release the failed-craft backoff with the error
            e.error = nil
            e.failedRequest, e.failedAmount, e.failedAt = nil, nil, nil
          else
            q.entries[key] = nil
          end
        end
      end
    end
  end
  return q, cleared
end

-- How long a failed entry still has to wait before the runner's failed-craft
-- backoff will try it again. Non-failed entries are ready (0).
function queue.retryRemainingMs(entry, now, cooldownMs)
  if type(entry) ~= "table" or not entry.error then return 0 end
  cooldownMs = tonumber(cooldownMs) or 0
  if cooldownMs <= 0 then return 0 end
  local elapsed = (tonumber(now) or 0) - (tonumber(entry.triedAt) or 0)
  local remaining = cooldownMs - elapsed
  if remaining <= 0 then return 0 end
  return remaining
end

function queue.retryLabel(entry, now, cooldownMs)
  local remaining = queue.retryRemainingMs(entry, now, cooldownMs)
  if remaining <= 0 then return "retry now" end
  local seconds = math.ceil(remaining / 1000)
  if seconds < 60 then return "retry " .. seconds .. "s" end
  return "retry " .. math.ceil(seconds / 60) .. "m"
end

-- Clear failed-entry backoff so the runner can try those approvals on its next
-- pass. This never crafts directly; it only removes the local retry delay.
function queue.retryFailed(q, now)
  q = queue.normalize(q)
  local n = 0
  for _, e in pairs(q.entries) do
    if e.error then
      e.error = nil
      e.triedAt = nil
      e.state = queue.APPROVED
      e.approvedAt = tonumber(now) or e.approvedAt
      n = n + 1
    end
  end
  return q, n
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
-- opts:
--   maxNew    : cap absent queue entries admitted by this call
--   maxQueued : cap existing runnable non-manual auto/quota queue depth before
--               admitting absent entries. Failed rows stay quarantined but do
--               not consume runnable capacity. Existing rows can still refresh/re-arm.
--
-- Pure: the manager owns the mode gate, the ledger COOLDOWN (which keeps an item
-- from reading WOULD CRAFT again until its window passes, bounding re-fire), and
-- persistence. plans rows are the stock/balance planner shape {action,name,label,
-- request,key?}.
function queue.autoApprove(q, plans, now, opts)
  q = queue.normalize(q)
  opts = opts or {}
  local maxNew = tonumber(opts.maxNew)
  if maxNew and maxNew > 0 then maxNew = math.floor(maxNew) else maxNew = nil end
  local maxQueued = tonumber(opts.maxQueued)
  if maxQueued and maxQueued > 0 then maxQueued = math.floor(maxQueued) else maxQueued = nil end
  local queued = 0
  if maxQueued then
    for _, e in pairs(q.entries) do
      if type(e) == "table" and not queue.isManual(e) and not e.error then queued = queued + 1 end
    end
  end
  local n = 0
  for _, p in ipairs(plans or {}) do
    if p and p.action == "WOULD CRAFT" and p.name and (tonumber(p.request) or 0) > 0 then
      local key = p.key or p.name
      local cur = q.entries[key]
      local absent = cur == nil
      local canAdmit = (not absent)
        or ((not maxNew or n < maxNew) and (not maxQueued or queued < maxQueued))
      if canAdmit and (not cur or cur.state ~= queue.APPROVED) then
        queue.approve(q, p, now)
        if absent then queued = queued + 1 end
        n = n + 1
      elseif cur then
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

function queue.failureCount(q)
  q = queue.normalize(q)
  local n = 0
  for _, e in pairs(q.entries) do
    if type(e) == "table" and e.error then n = n + 1 end
  end
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

-- Chronological craft audit for live debugging. Unlike recordResult() this keeps
-- recent events in order so a test session can answer "what happened first?".
-- Shape is an array of compact event tables; the manager owns persistence.
function queue.recordAudit(audit, event)
  if type(audit) ~= "table" then audit = {} end
  if type(event) ~= "table" then return audit end
  local e = {
    at = tonumber(event.at) or 0,
    kind = event.kind and tostring(event.kind) or "event",
    name = event.name and tostring(event.name) or nil,
    key = event.key and tostring(event.key) or nil,
    amount = tonumber(event.amount or event.request),
    ok = event.ok == nil and nil or event.ok == true,
    reason = event.reason and tostring(event.reason) or nil,
    jobId = event.jobId,
    stockAtScan = tonumber(event.stockAtScan),
    activeCraftMethod = event.activeCraftMethod and tostring(event.activeCraftMethod) or nil,
    activeCraftCount = tonumber(event.activeCraftCount),
    activeNow = event.activeNow == nil and nil or event.activeNow == true,
    queueDepth = tonumber(event.queueDepth),
  }
  audit[#audit + 1] = e
  return audit
end

-- Keep newest audit entries by timestamp, preserving chronological order in the
-- retained tail. max <= 0 disables the cap.
function queue.pruneAudit(audit, max)
  if type(audit) ~= "table" then return {}, 0 end
  max = tonumber(max) or 0
  if max <= 0 or #audit <= max then return audit, 0 end
  table.sort(audit, function(a, b)
    local aa, bb = tonumber(a and a.at) or 0, tonumber(b and b.at) or 0
    if aa ~= bb then return aa < bb end
    return tostring(a and a.name or "") < tostring(b and b.name or "")
  end)
  local drop = #audit - max
  for _ = 1, drop do table.remove(audit, 1) end
  return audit, drop
end

return queue
