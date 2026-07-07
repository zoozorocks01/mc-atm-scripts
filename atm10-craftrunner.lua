-- Executes approved craft-queue entries through the control safety gate.
--
-- Pure orchestration: no peripherals, no fs, no rednet. The manager injects the
-- bridge craft call, the in-flight check, the ledger writer, the policy, and the
-- clock, so this logic is unit-tested off the in-game runtime (see tests/run.lua),
-- exactly like the stock planner.
--
-- SAFETY MODEL:
--   * An entry only reaches the bridge through control.execute, i.e. ONLY after
--     every gate passes (mode/enabled/armed/capability/approval). The queue
--     approval itself is the manual approval.
--   * Each approval fires AT MOST ONE craft request, then transitions to
--     CRAFTING so it is never re-requested.
--   * If the item is already crafting in RS, adopt CRAFTING without a request.
--   * A bridge rejection keeps the entry APPROVED with an error. In manual mode
--     or when deps.holdFailed=true, failed plan approvals stay blocked until the
--     operator explicitly retries or clears them. Auto mode can opt into the same
--     fail-stop behavior for unattended safety.
local control = require("atm10-control")
local cqueue = require("atm10-queue")

local runner = {}

-- Strict weak ordering shared by every fire lane; mirrors queue.list(...,{priority=true})
-- (atm10-queue.lua: priority desc, approvedAt desc, name asc). If queue.lua's ordering
-- changes, update this in lockstep or single-lane backward-compat equivalence drifts.
local function cmp(a, b)
  local ap, bp = tonumber(a.priority) or 0, tonumber(b.priority) or 0
  if ap ~= bp then return ap > bp end                 -- urgent (higher priority) first
  local aa, ba = tonumber(a.approvedAt) or 0, tonumber(b.approvedAt) or 0
  if aa ~= ba then return aa > ba end                 -- newer approval first (queue.lua:153)
  local an, bn = tostring(a.name), tostring(b.name)
  if an ~= bn then return an < bn end                 -- name asc
  return tostring(a.key or a.name) < tostring(b.key or b.name) -- key disambiguates two compress
end                                                   -- rows into the SAME item (balance.lua:48); deterministic

-- CRAFT-5: fair fire order under a per-cycle cap. Splits one global craft budget into a
-- reserved compress/overflow floor + round-robin across refill categories, so a dust-refill
-- flood can't starve a below-floor alloy and compress rows don't fight refills for the same
-- slots. PURE: reorders only, never truncates -- the caller's global `fired >= maxPerCycle`
-- guard stays the ONLY hard cap, so runtime skips (backoff / already-crafting / same-item
-- dedup) free their slot to a later entry and no per-bucket counter can mis-account.
-- budgets = { total = maxPerCycle (nil/<=0 = unlimited), overflow = overflowReserve }.
--
-- Order = [reserved compress] ++ [refills round-robin by category] ++ [surplus compress]:
--   * reserved-first => a refill flood cannot occupy the leading min(overflow,#compress) slots
--   * surplus-last   => extra compress only uses slots refills leave idle (refills protected).
--     NB this means compress is NOT interleaved with refills by priority: with overflow=0 every
--     compress trails every refill regardless of its priority. Fire order is byte-identical to the
--     old pure-priority path ONLY when there are no compress rows.
--   * a refill-only bucket with one category degrades to pure priority order (the tapped path)
--   * never truncates => if one bucket has no demand the other fills the whole cap (no waste)
-- Cross-CYCLE round-robin is NOT persisted (stateless): when total < #lanes the same lanes win
-- each cycle, but a starved category's deficit (=> priority) climbs and rotates it in naturally.
-- A1 adds a leading MANUAL lane so operator one-shots win the cap before quota refills:
--   Order = [reserved manual] ++ [reserved compress] ++ [surplus manual] ++ [refills RR]
--           ++ [surplus compress]
--   * reserved-manual (budgets.manual slots) guarantees at least that many jobs fire each
--     cycle even when a refill flood fills the cap (jobs can't be starved by quotas).
--   * surplus-manual sits BEFORE refills so a job wins the rest of the cap when capacity
--     allows, while the reserved-COMPRESS floor is still honored ahead of surplus manual.
--   * with budgets.manual=0 manual still LEADS refills (only the guaranteed floor differs).
function runner.fireOrder(entries, budgets)
  budgets = budgets or {}
  local manual, compress, refills = {}, {}, {}
  for _, e in ipairs(entries or {}) do
    if cqueue.isManual(e) then manual[#manual + 1] = e
    elseif e.kind == "compress" then compress[#compress + 1] = e
    else refills[#refills + 1] = e end
  end
  table.sort(manual, cmp)
  table.sort(compress, cmp)

  -- group refills into per-category lanes; a nil category collapses into one "" lane so a
  -- nil-category refill and a "Tapped" refill never split into rival round-robin lanes
  local laneMap, laneOrder = {}, {}
  for _, e in ipairs(refills) do
    local c = e.category or ""
    if not laneMap[c] then laneMap[c] = {}; laneOrder[#laneOrder + 1] = c end
    local lane = laneMap[c]; lane[#lane + 1] = e
  end
  for _, c in ipairs(laneOrder) do table.sort(laneMap[c], cmp) end
  -- order lanes by their HEAD entry, comparing fields directly (cmp-of-cmp is not a valid
  -- strict weak order); category label is the final stable tiebreak
  table.sort(laneOrder, function(x, y)
    local hx, hy = laneMap[x][1], laneMap[y][1]
    local px, py = tonumber(hx.priority) or 0, tonumber(hy.priority) or 0
    if px ~= py then return px > py end
    local ax, ay = tonumber(hx.approvedAt) or 0, tonumber(hy.approvedAt) or 0
    if ax ~= ay then return ax > ay end
    return tostring(x) < tostring(y)
  end)

  -- clamp the reserve to [0, cap]; unlimited total => cap = #compress so every compress can lead
  local t = tonumber(budgets.total)
  local totalCap = (t and t > 0) and t or math.huge
  local cap = (totalCap == math.huge) and #compress or totalCap
  local reserveN = math.max(0, math.min(math.floor(tonumber(budgets.overflow) or 0), cap))
  local reserve = math.min(reserveN, #compress)
  -- A1: reserved-manual floor, clamped to [0, cap] then to #manual
  local reserveMN = math.max(0, math.min(math.floor(tonumber(budgets.manual) or 0), cap))
  local reserveM = math.min(reserveMN, #manual)

  local order = {}
  for i = 1, reserveM do order[#order + 1] = manual[i] end             -- reserved manual first
  for i = 1, reserve do order[#order + 1] = compress[i] end           -- reserved compress next
  for i = reserveM + 1, #manual do order[#order + 1] = manual[i] end  -- surplus manual before refills
  local idx = {}
  for _, c in ipairs(laneOrder) do idx[c] = 1 end
  local placed = true
  while placed do                                                      -- refills round-robin
    placed = false
    for _, c in ipairs(laneOrder) do
      local lane, i = laneMap[c], idx[c]
      if i <= #lane then order[#order + 1] = lane[i]; idx[c] = i + 1; placed = true end
    end
  end
  for i = reserve + 1, #compress do order[#order + 1] = compress[i] end -- surplus compress last
  return order
end

-- deps:
--   policy        : control.policy (mode + capability flags)            [required]
--   mode          : config mode string, passed onto each craftAction
--   now           : current time in ms
--   cooldownMs    : retry backoff after a failed craft (ms; <=0 disables)
--   isCrafting    : function(name) -> bool   (is RS already crafting it?)
--   craft         : function(name, amount) -> ok, reason, jobId   (the bridge call)
--   recordRequest : function(name, amount, now)            (optional; ledger write)
--   maxPerCycle   : cap on NEW bridge requests issued this run (<=0/nil = unlimited);
--                   over-cap entries stay APPROVED for a later cycle, so the operator
--                   can approve many items without flooding a laggy server at once.
--   maxBridgeRequest : cap on one craftItem call's count (<=0/nil = unlimited);
--                   lets one large approval drain through smaller AP/RS-safe batches.
--   overflowReserve : CRAFT-5 floor of slots (carved from maxPerCycle) reserved FIRST for
--                   kind=="compress" rows, so a refill flood can't starve compression and
--                   surplus compress can't starve refills. 0/nil = no reserved floor: compress
--                   then yields to ALL refills (fires only on idle capacity), NOT interleaved
--                   by priority. Borrowable: either side uses the other's idle slots. See runner.fireOrder.
--   holdReason    : optional function(entry, q) -> string reason to leave APPROVED
--                   without firing this cycle (used for compression-pair deadlocks).
--   holdFailed    : true => failed non-manual entries never retry automatically.
--
-- Mutates q in place. Returns a summary and the queue:
--   { requested = { {name, amount} }, failed = { {name, reason} }, changed = bool }
function runner.run(q, deps)
  deps = deps or {}
  q = cqueue.normalize(q)

  local now = tonumber(deps.now) or 0
  local cooldownMs = tonumber(deps.cooldownMs) or 0
  local isCrafting = deps.isCrafting or function() return false end
  local craftFn = deps.craft or function() return false, "no executor" end
  local recordRequest = deps.recordRequest
  local holdReason = deps.holdReason
  local policy = deps.policy
  local manualMode = deps.mode == control.MODE_MANUAL
  local holdFailed = deps.holdFailed == true
  local maxPerCycle = tonumber(deps.maxPerCycle)
  if maxPerCycle and maxPerCycle <= 0 then maxPerCycle = nil end
  local maxBridgeRequest = tonumber(deps.maxBridgeRequest)
  if maxBridgeRequest and maxBridgeRequest > 0 then
    maxBridgeRequest = math.floor(maxBridgeRequest)
  else
    maxBridgeRequest = nil
  end

  local summary = { requested = {}, failed = {}, completed = {}, held = {}, changed = false }
  local fired = 0
  local requestedThisRun = {} -- item names already requested this run (avoid double-fire)

  local function capBridgeRequest(amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if maxBridgeRequest and amount > maxBridgeRequest then return maxBridgeRequest end
    return amount
  end

  -- A1: how many units of a manual job may fire THIS time, honoring the craftFrom
  -- input reserve exactly as stockplan.plan does (the planner never runs for a job).
  -- force=true or no craftFrom => the full e.request. Returns (amount, heldReason):
  -- a heldReason with amount<=0 is a SOFT skip (leave APPROVED, surface why; not a
  -- failure). resolve absent (older manager / a unit test) => no reserve enforcement.
  local resolve = deps.resolve
  local function manualFireAmount(e)
    local want = math.max(0, math.floor(tonumber(e.request) or 0))
    if e.force == true then return want, nil end
    local cf = e.craftFrom
    if type(cf) ~= "table" or not cf.name or type(resolve) ~= "function" then
      return want, nil
    end
    local inputAmount = tonumber((resolve(cf.name))) or 0
    local ratio = math.max(1, math.floor(tonumber(cf.ratio) or 1))
    local reserve = math.max(0, math.floor(tonumber(cf.reserve) or 0))
    local maxByInput = math.max(0, math.floor((inputAmount - reserve) / ratio))
    if maxByInput <= 0 then
      return 0, "holding " .. tostring(cf.name) .. " reserve"
    end
    if want > maxByInput then return maxByInput, nil end
    return want, nil
  end

  -- CRAFT-5: reorder the priority-sorted APPROVED set into a fair fire order (reserved
  -- manual floor + reserved compress floor + round-robin refill categories + surplus
  -- compress last). Reorder only: the `fired >= maxPerCycle` guard below is still the
  -- sole hard cap.
  local order = runner.fireOrder(cqueue.list(q, { priority = true }),
    { total = maxPerCycle, overflow = tonumber(deps.overflowReserve),
      manual = tonumber(deps.manualReserve) })
  for _, e in ipairs(order) do
    local ekey = e.key or e.name -- queue identity (refill vs compress can share a name)
    local manualJob = cqueue.isManual(e)
    if e.state == cqueue.APPROVED then
      local heldByDeps = type(holdReason) == "function" and holdReason(e, q) or nil
      -- A1: a manual job bypasses the runner's failed-craft backoff (the operator asked
      -- for it NOW), so only NON-manual entries respect the cooldown skip.
      if heldByDeps then
        if e.error ~= heldByDeps then
          e.error = heldByDeps
          summary.changed = true
        end
        summary.held[#summary.held + 1] = { name = e.name, reason = heldByDeps }
      elseif (not manualJob) and e.error and (manualMode or holdFailed or cqueue.isHardFailure(e)) then
        summary.held[#summary.held + 1] = { name = e.name, reason = e.error }
      elseif (not manualJob) and e.triedAt and cooldownMs > 0 and (now - e.triedAt) < cooldownMs then
        -- backing off after a recent failed craft; skip this cycle
      elseif isCrafting(e.name) then
        -- RS is already crafting it: adopt CRAFTING, never double-request
        cqueue.markCrafting(q, ekey, now)
        requestedThisRun[e.name] = true
        summary.changed = true
      elseif requestedThisRun[e.name] then
        -- another entry already requested this exact item this run (e.g. two
        -- compress rules both crafting copper_ingot): adopt CRAFTING, don't re-fire
        cqueue.markCrafting(q, ekey, now)
        summary.changed = true
      elseif maxPerCycle and fired >= maxPerCycle then
        -- hit the per-cycle request cap; leave APPROVED for the next cycle
      else
        -- A1: a manual job fires only the craftFrom-reserve-clamped remainder; a fully
        -- held job (input below its reserve) is a soft skip, not a failure or a fire.
        local fireAmount, heldReason = e.request, nil
        if manualJob then
          fireAmount, heldReason = manualFireAmount(e)
          if heldReason then
            summary.held[#summary.held + 1] = { name = e.name, reason = heldReason }
          end
        end
        if manualJob and (heldReason or (fireAmount or 0) <= 0) then
          -- soft skip: leave APPROVED so it retries when the input recovers
        else
          fireAmount = capBridgeRequest(fireAmount)
          if fireAmount <= 0 then
            -- malformed/zero request after clamping: leave APPROVED but do not fire
          else
            local action = control.craftAction({ name = e.name, label = e.label, request = fireAmount }, {
              mode = deps.mode,
              execute = function() return craftFn(e.name, fireAmount) end,
            })

            -- canExecute checks the gate WITHOUT running the executor, so we can tell
            -- a closed gate (leave APPROVED, quiet) apart from a bridge rejection.
            if control.canExecute(action, policy) then
              local ok, reason, jobId = control.execute(action, policy) -- only here does the bridge run
              if ok then
                if recordRequest then recordRequest(e.name, fireAmount, now) end
                requestedThisRun[e.name] = true
                if jobId ~= nil then e.jobId = jobId end
                summary.requested[#summary.requested + 1] = {
                  key = ekey, name = e.name, label = e.label, kind = e.kind, amount = fireAmount, jobId = jobId,
                }
                summary.changed = true
                fired = fired + 1
                if manualJob then
                  -- A1: track progress; complete (signal the manager to drop) when made>=N.
                  -- A job split across cycles by the craftFrom clamp accumulates here and
                  -- stays APPROVED until done; the manager recomputes request=remaining.
                  cqueue.recordMade(q, ekey, fireAmount, now)
                  if cqueue.jobComplete(q, ekey) then
                    summary.completed[#summary.completed + 1] = { key = ekey, name = e.name, made = e.made }
                  else
                    e.error = nil -- a partial fire is not an error; keep it APPROVED for next cycle
                  end
                else
                  cqueue.markCrafting(q, ekey, now, fireAmount, jobId)
                end
              else
                cqueue.markError(q, ekey, now, reason)
                summary.failed[#summary.failed + 1] = {
                  key = ekey, name = e.name, label = e.label, kind = e.kind, amount = fireAmount, reason = reason,
                }
                summary.changed = true
              end
            end
            -- gate closed (dry-run/monitor/awaiting approval/capability off): no-op
          end
        end
      end
    end
  end

  return summary, q
end

return runner
