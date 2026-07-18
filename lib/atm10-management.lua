-- Read-only v0 base-management objective planner.
--
-- This module deliberately does NOT touch peripherals, queue state, or craftItem.
-- It converts snapshots the manager already has into one answer suitable for an
-- operator/agent: the first bounded safe objective, or the concrete blocker that
-- prevents choosing one. Execution stays on the existing gated queue path.

local management = {}

-- The manager passes its persisted queue object ({ entries = { ... } }), while
-- small callers/tests may pass a plain row list. Inspect both shapes. Reading
-- only `ipairs(queue)` silently missed every real persisted failure because its
-- entries are keyed by item/key rather than numeric indexes.
local function countFailed(queue)
  local n = 0
  local rows = type(queue) == "table" and (queue.entries or queue) or {}
  for _, row in pairs(rows) do
    if type(row) == "table" and row.error then n = n + 1 end
  end
  return n
end

local function isProtected(name, opts)
  if type(name) ~= "string" then return true end
  if type(opts.protected) == "table" and opts.protected[name] then return true end
  -- Preserve the established oresight rule by default. These materials may be
  -- observed and planned manually, but v0 never selects them unattended.
  return name:find("allthemodium:", 1, true) ~= nil
end

local function eligible(row, opts)
  if type(row) ~= "table" or row.action ~= "WOULD CRAFT" then return false end
  if type(row.name) ~= "string" or not row.name:match("_ingot$") then return false end
  if row.kind == "compress" or isProtected(row.name, opts) then return false end
  return (tonumber(row.request) or 0) > 0
end

local function better(a, b)
  local ap, bp = tonumber(a.priority) or 0, tonumber(b.priority) or 0
  if ap ~= bp then return ap > bp end
  local ar, br = tonumber(a.request) or 0, tonumber(b.request) or 0
  if ar ~= br then return ar > br end
  return tostring(a.name) < tostring(b.name)
end

-- input: { plans, queue, bridge={connected,online,degraded}, loop={status},
--          rsStuckCount }
-- opts:  { maxTotal=4000, protected={ [name]=true } }
-- returns { state="READY"|"BLOCKED"|"IDLE", reason, target? }
-- target is a proposal only: {name,label,amount,target,craftTo,remaining}.
function management.plan(input, opts)
  input = type(input) == "table" and input or {}
  opts = opts or {}
  local bridge = type(input.bridge) == "table" and input.bridge or {}
  local loop = type(input.loop) == "table" and input.loop or {}
  local failed = countFailed(input.queue)

  if bridge.connected == false or bridge.online == false then
    return { state = "BLOCKED", reason = "bridge unavailable" }
  end
  if bridge.degraded == true then return { state = "BLOCKED", reason = "bridge degraded" } end
  if loop.status and loop.status ~= "OK" then
    return { state = "BLOCKED", reason = "manager loop " .. tostring(loop.status) }
  end
  if failed > 0 then return { state = "BLOCKED", reason = "queue failures: " .. failed } end
  if (tonumber(input.rsStuckCount) or 0) > 0 then
    return { state = "BLOCKED", reason = "frozen RS tasks: " .. tostring(input.rsStuckCount) }
  end

  local choice
  for _, row in ipairs(input.plans or {}) do
    if eligible(row, opts) and (not choice or better(row, choice)) then choice = row end
  end
  if not choice then
    return { state = "IDLE", reason = "no safe ingot refill candidate" }
  end

  local maxTotal = math.max(1, math.floor(tonumber(opts.maxTotal) or 4000))
  local remaining = math.max(0, math.floor(tonumber(choice.request) or 0))
  return {
    state = "READY",
    reason = "read-only proposal; approval required",
    target = {
      name = choice.name,
      label = choice.label or choice.name,
      amount = tonumber(choice.amount) or 0,
      target = tonumber(choice.target),
      craftTo = tonumber(choice.craftTo),
      remaining = math.min(remaining, maxTotal),
      capped = remaining > maxTotal,
    },
  }
end

-- One compact HEALTH-page/operator line for the proposal above. Keeping this
-- pure makes the in-game wording testable and avoids a second interpretation of
-- safety state in the display code.
function management.statusLine(result)
  result = type(result) == "table" and result or {}
  if result.state == "READY" and type(result.target) == "table" then
    return "V0 READY: " .. tostring(result.target.label or result.target.name) ..
      " +" .. tostring(result.target.remaining or 0) .. " (approval required)"
  end
  if result.state == "BLOCKED" then return "V0 BLOCKED: " .. tostring(result.reason or "unknown") end
  return "V0 IDLE: " .. tostring(result.reason or "no objective")
end

return management
