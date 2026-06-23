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
--   * A bridge rejection keeps the entry APPROVED but backs off for one cooldown
--     before retrying, so a recipe that can't be satisfied does not spam.
local control = require("atm10-control")
local cqueue = require("atm10-queue")

local runner = {}

-- deps:
--   policy        : control.policy (mode + capability flags)            [required]
--   mode          : config mode string, passed onto each craftAction
--   now           : current time in ms
--   cooldownMs    : retry backoff after a failed craft (ms; <=0 disables)
--   isCrafting    : function(name) -> bool   (is RS already crafting it?)
--   craft         : function(name, amount) -> ok, reason   (the bridge call)
--   recordRequest : function(name, amount, now)            (optional; ledger write)
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
  local policy = deps.policy

  local summary = { requested = {}, failed = {}, changed = false }

  for _, e in ipairs(cqueue.list(q)) do
    if e.state == cqueue.APPROVED then
      if e.triedAt and cooldownMs > 0 and (now - e.triedAt) < cooldownMs then
        -- backing off after a recent failed craft; skip this cycle
      elseif isCrafting(e.name) then
        -- RS is already crafting it: adopt CRAFTING, never double-request
        cqueue.markCrafting(q, e.name, now)
        summary.changed = true
      else
        local action = control.craftAction(e, {
          mode = deps.mode,
          execute = function() return craftFn(e.name, e.request) end,
        })

        -- canExecute checks the gate WITHOUT running the executor, so we can tell
        -- a closed gate (leave APPROVED, quiet) apart from a bridge rejection.
        if control.canExecute(action, policy) then
          local ok, reason = control.execute(action, policy) -- only here does the bridge run
          if ok then
            cqueue.markCrafting(q, e.name, now)
            if recordRequest then recordRequest(e.name, e.request, now) end
            summary.requested[#summary.requested + 1] = { name = e.name, amount = e.request }
            summary.changed = true
          else
            cqueue.markError(q, e.name, now, reason)
            summary.failed[#summary.failed + 1] = { name = e.name, reason = reason }
            summary.changed = true
          end
        end
        -- gate closed (dry-run/monitor/awaiting approval/capability off): no-op
      end
    end
  end

  return summary, q
end

return runner
