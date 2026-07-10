local status = require("atm10-status")

local control = {}

control.PROTOCOL = "atm10-control-v1"

control.MODE_MONITOR = "monitor"
control.MODE_DRY_RUN = "dry-run"
control.MODE_MANUAL = "manual"
control.MODE_AUTO = "auto"

-- Operating tiers: one high-level switch (config.operatingTier) that resolves to the
-- underlying mode + capability flags, so an operator can pick a whole behavior set --
-- 'viewer' (read-only, never crafts), 'manual' (plans, you approve each craft), or
-- 'auto' (crafts approved deficits unattended) -- without wiring mode / allowAutocraft
-- / stockKeeper.enabled individually. Leaving operatingTier unset preserves the raw
-- mode/flags (fully backward compatible). Each tier maps to a hard, code-enforced
-- guarantee: executionState() gates all crafting on mode, stockKeeper.enabled gates
-- the planner, allowAutocraft is the capability master-switch.
control.TIERS = {
  viewer = { mode = control.MODE_MONITOR, allowAutocraft = false, stockKeeperEnabled = false },
  manual = { mode = control.MODE_MANUAL,  allowAutocraft = true,  stockKeeperEnabled = true  },
  auto   = { mode = control.MODE_AUTO,    allowAutocraft = true,  stockKeeperEnabled = true  },
}

-- applyTier(cfg): if cfg.operatingTier names a known tier, set the three derived
-- fields on cfg in place (the tier wins -- it is the explicit high-level choice).
-- Unknown/absent tier -> cfg untouched (caller keeps its raw mode/flags). Preserves
-- all other stockKeeper fields (only sets .enabled). Returns cfg.
function control.applyTier(cfg)
  if type(cfg) ~= "table" then return cfg end
  local t = control.TIERS[cfg.operatingTier]
  if not t then return cfg end
  cfg.mode = t.mode
  cfg.allowAutocraft = t.allowAutocraft
  if type(cfg.stockKeeper) ~= "table" then cfg.stockKeeper = {} end
  cfg.stockKeeper.enabled = t.stockKeeperEnabled
  return cfg
end

control.CAPABILITY_AUTOCRAFT = "autocraft"
control.CAPABILITY_EXPORT = "export"
control.CAPABILITY_REDSTONE = "redstone"
control.CAPABILITY_SECURITY = "security"

-- How long after the last craftItem a computer must stay attached before it is
-- safe to detach (reboot/shutdown/update). Covers the window in which
-- AdvancedPeripherals still holds the craft job and may fire its final event.
control.DEFAULT_DRAIN_MS = 120000

local validModes = {
  ["monitor"] = true,
  ["dry-run"] = true,
  ["manual"] = true,
  ["auto"] = true,
}

local capabilityFlags = {
  autocraft = "allowAutocraft",
  export = "allowExport",
  redstone = "allowRedstone",
  security = "allowSecurity",
}

local function copyList(values)
  if type(values) ~= "table" then return nil end

  local out = {}
  for i, value in ipairs(values) do
    out[i] = value
  end
  return out
end

local function contains(values, target)
  if type(values) ~= "table" then return false end

  for _, value in ipairs(values) do
    if value == target then return true end
  end

  return false
end

function control.normalizeMode(value, default)
  if validModes[value] then return value end
  return default or control.MODE_DRY_RUN
end

function control.policy(args)
  args = args or {}

  return {
    mode = control.normalizeMode(args.mode, control.MODE_DRY_RUN),
    allowAutocraft = args.allowAutocraft == true,
    allowExport = args.allowExport == true,
    allowRedstone = args.allowRedstone == true,
    allowSecurity = args.allowSecurity == true,
    token = args.token,
    allowedSenders = copyList(args.allowedSenders),
  }
end

function control.isCapabilityAllowed(capability, policy)
  policy = policy or {}

  local flag = capabilityFlags[capability or "unknown"]
  if not flag then
    return false, "unknown capability"
  end

  if policy[flag] ~= true then
    return false, tostring(capability) .. " not allowed"
  end

  return true, "allowed"
end

function control.authorize(senderId, message, policy)
  policy = policy or {}

  if type(policy.allowedSenders) == "table" and #policy.allowedSenders > 0 then
    if not contains(policy.allowedSenders, senderId) then
      return false, "sender not allowed"
    end
  end

  if policy.token ~= nil then
    if type(message) ~= "table" or message.token ~= policy.token then
      return false, "bad token"
    end
  end

  return true, "authorized"
end

function control.action(args)
  args = args or {}

  local capability = args.capability or args.kind or "unknown"

  return {
    id = args.id or args.label or "unnamed",
    system = args.system or "unknown",
    label = args.label or args.id or "Unnamed Action",
    kind = args.kind or capability,
    capability = capability,
    target = args.target,
    amount = args.amount,
    reason = args.reason,
    mode = control.normalizeMode(args.mode),
    enabled = args.enabled == true,
    armed = args.armed == true,
    approved = args.approved == true,
    sender = args.sender,
    status = status.normalize(args.status or status.WOULD),
    execute = args.execute,
  }
end

-- Build an autocraft control action from an approved craft-queue entry.
-- The operator's queue approval IS the manual approval, so `approved` defaults
-- true. enabled/armed default true (a configured + approved stock item is an
-- explicit, operator-driven request, not a latent actuator output). The caller
-- supplies the executor and may override any gate via opts.
function control.craftAction(entry, opts)
  entry = entry or {}
  opts = opts or {}

  local function default(value, fallback)
    if value == nil then return fallback end
    return value
  end

  return control.action({
    id = "craft:" .. tostring(entry.name),
    system = "inventory",
    label = entry.label or entry.name,
    capability = control.CAPABILITY_AUTOCRAFT,
    target = entry.name,
    amount = tonumber(entry.request) or 0,
    mode = opts.mode,
    enabled = default(opts.enabled, true),
    armed = default(opts.armed, true),
    approved = default(opts.approved, true),
    execute = opts.execute,
  })
end

local function resolveMode(action, policy)
  if policy and policy.mode then
    return control.normalizeMode(policy.mode, control.MODE_DRY_RUN)
  end

  return control.normalizeMode(action and action.mode, control.MODE_DRY_RUN)
end

function control.executionState(action, policy)
  if not action then return status.UNKNOWN, "missing action" end
  local mode = resolveMode(action, policy)

  if action.enabled ~= true then
    return status.DISABLED, "disabled"
  end

  if mode == control.MODE_MONITOR then
    return status.DISABLED, "monitor only"
  end

  if mode == control.MODE_DRY_RUN then
    return status.WOULD, "planning only"
  end

  if action.armed ~= true then
    return status.DISABLED, "not armed"
  end

  local allowed, capabilityReason = control.isCapabilityAllowed(action.capability, policy)
  if not allowed then
    return status.BLOCKED, capabilityReason
  end

  if mode == control.MODE_MANUAL and action.approved ~= true then
    return status.COOLDOWN, "waiting approval"
  end

  if type(action.execute) ~= "function" then
    return status.BLOCKED, "no executor"
  end

  return status.OK, "ready"
end

function control.canExecute(action, policy)
  local state = control.executionState(action, policy)
  return state == status.OK
end

function control.describe(action, policy)
  local state, reason = control.executionState(action, policy)
  return {
    id = action and action.id or "missing",
    system = action and action.system or "unknown",
    label = action and action.label or "Missing Action",
    kind = action and action.kind or "unknown",
    capability = action and action.capability or "unknown",
    target = action and action.target or nil,
    amount = action and action.amount or nil,
    mode = resolveMode(action, policy),
    enabled = action and action.enabled == true or false,
    armed = action and action.armed == true or false,
    reason = reason,
    status = state,
    tag = status.tag(state),
  }
end

function control.describeAll(actions, policy)
  local out = {}
  for _, action in ipairs(actions or {}) do
    out[#out + 1] = control.describe(action, policy)
  end
  return out
end

function control.execute(action, policy)
  local state, reason = control.executionState(action, policy)
  if state ~= status.OK then
    return false, reason
  end

  return action.execute(action)
end

-- Whether it is safe to detach this computer (reboot / shutdown / update) without
-- risking the AdvancedPeripherals NotAttachedException server crash. AP keeps its
-- own craft-job list and fires each job's completion event back into the computer;
-- if the computer has gone away by then, that uncaught throw kills the whole
-- server tick. So detaching is safe ONLY when nothing is crafting AND enough time
-- has elapsed since the last craftItem for AP to finish and fire its final events.
-- Note AP's job list lags our queue, so "nothing crafting" alone is not enough --
-- the drain window is what makes it safe.
--   state = { now = ms, lastCraftAt = ms|nil, crafting = count, drainMs = ms }
-- Returns { safe = bool, reason = str, crafting = n, secondsLeft = n|nil }.
function control.rebootSafety(state)
  state = state or {}
  local now = tonumber(state.now) or 0
  local drainMs = tonumber(state.drainMs) or control.DEFAULT_DRAIN_MS
  local crafting = math.max(0, math.floor(tonumber(state.crafting) or 0))
  local lastCraftAt = tonumber(state.lastCraftAt)

  if crafting > 0 then
    return {
      safe = false,
      crafting = crafting,
      reason = crafting .. " craft" .. (crafting == 1 and "" or "s") .. " in flight",
    }
  end

  if lastCraftAt then
    local elapsed = now - lastCraftAt
    if elapsed < drainMs then
      return {
        safe = false,
        crafting = 0,
        secondsLeft = math.ceil((drainMs - elapsed) / 1000),
        reason = "draining recent craft jobs",
      }
    end
  end

  return { safe = true, crafting = 0, secondsLeft = 0, reason = "no crafts in flight" }
end

-- A drain request is a standing order only while its requester (safereboot /
-- atm10-reload) is alive to renew it. Both rewrite the flag with renewedAt every
-- poll; if the requester is aborted (Ctrl+T) or crashes mid-drain, the leftover
-- flag goes stale and must NOT quiesce the manager forever. A future timestamp
-- still counts as fresh so clock weirdness can never strand a live drain.
control.DRAIN_REQUEST_TTL_MS = 60000

function control.drainRequestFresh(data, now, ttlMs)
  if type(data) ~= "table" then return false end
  local ts = tonumber(data.renewedAt) or tonumber(data.requestedAt)
  if not ts then return false end
  local ttl = tonumber(ttlMs) or control.DRAIN_REQUEST_TTL_MS
  return ((tonumber(now) or 0) - ts) <= ttl
end

-- SOAK: a bounded, fail-stop unattended-auto window an agent can request over the
-- file channel (.atm10-soak-request) without an operator at the monitor. The point
-- is to PROVE auto is trustworthy in small doses: the manager runs auto with the
-- runner's holdWhenAnyFailed fail-stop, then always reverts to manual on its own.
-- Every exit path ends in manual: the deadline passes, any queue row fails, the
-- operator changes mode, or the manager restarts (boot clears the soak state).
-- A soak may only START from manual -- it is an excursion from a safe base, never
-- a way to switch a misbehaving auto base back on.
control.SOAK_REQUEST_TTL_MS = 60000        -- request older than this is stale
control.SOAK_MIN_MS = 30000                -- floor: shorter proves nothing
control.SOAK_MAX_MS = 15 * 60 * 1000       -- hard cap on any requested window
control.SOAK_DEFAULT_MS = 5 * 60 * 1000

-- Validate + clamp an agent-written soak request into a running-soak spec.
-- data = { requestedAt = ms (manager clock), durationMs?, maxPerCycle?, note? }
-- Returns spec { requestedAt, startedAt, endsAt, maxPerCycle?, note?, fired = 0 }
-- or nil, reason. Freshness is required so a leftover file from a dead agent
-- can never start an unattended window later.
function control.soakSpec(data, now)
  if type(data) ~= "table" then return nil, "invalid request" end
  now = tonumber(now) or 0
  local requestedAt = tonumber(data.requestedAt)
  if not requestedAt or requestedAt <= 0 then return nil, "missing requestedAt" end
  if (now - requestedAt) > control.SOAK_REQUEST_TTL_MS then return nil, "stale request" end
  local duration = tonumber(data.durationMs) or control.SOAK_DEFAULT_MS
  duration = math.max(control.SOAK_MIN_MS, math.min(control.SOAK_MAX_MS, duration))
  local maxPerCycle = tonumber(data.maxPerCycle)
  if maxPerCycle then maxPerCycle = math.max(1, math.floor(maxPerCycle)) end
  return {
    requestedAt = requestedAt,
    startedAt = now,
    endsAt = now + duration,
    maxPerCycle = maxPerCycle,
    note = type(data.note) == "string" and data.note or nil,
    fired = 0,
  }
end

-- PRODUCTION LINES (docs/DECISIONS.md #4): the script-controlled on/off decision
-- for a continuous machine line (e.g. an RS Exporter feeding a smelter bank).
-- The manager computes this every scan from live stock and broadcasts it; a
-- tiny actuator computer turns it into a redstone signal. Hysteresis so the
-- line doesn't flap at the threshold: turn ON below `low`, stay on until stock
-- reaches `high`, then OFF until it dips below `low` again. A feedstock floor
-- (floorItem/floorMin) overrides everything -- the line never draws its input
-- below the reserve Zach wants kept for other recipes.
--   line  = { item, low, high?, floorItem?, floorMin? }  (high defaults to low)
--   state = { amounts = {name->count}, prevOn = bool }
-- Returns on(bool), reason(string) -- reason is for the status file / dashboard.
function control.lineDecision(line, state)
  if type(line) ~= "table" or type(line.item) ~= "string" then
    return false, "invalid line config"
  end
  state = state or {}
  local amounts = type(state.amounts) == "table" and state.amounts or {}
  local low = tonumber(line.low)
  if not low then return false, "invalid low threshold" end
  local high = math.max(low, tonumber(line.high) or low)

  if line.floorItem then
    local floorMin = tonumber(line.floorMin) or 0
    local feed = tonumber(amounts[line.floorItem])
    -- Unknown feedstock reads as empty: a line must never run blind through
    -- a scan gap and eat below the reserve.
    if (feed or 0) <= floorMin then
      return false, "feedstock at reserve floor"
    end
  end

  local stock = tonumber(amounts[line.item])
  if stock == nil then
    -- Item not visible this scan (bridge hiccup): hold the previous decision
    -- OFF-biased -- an already-off line stays off; an on line also stops,
    -- because running on stale data is how reserves get eaten.
    return false, "stock unreadable"
  end

  if state.prevOn then
    if stock >= high then return false, "target reached" end
    return true, "filling to target"
  end
  if stock < low then return true, "below target" end
  return false, "at target"
end

-- Project exactly the two stock values a continuous line can consume: its
-- output item and (when configured) its feedstock floor. The manager passes a
-- resolver over its current scan index, so line control never copies or scans
-- the entire RS grid just to make a two-boolean decision.
function control.lineAmounts(line, resolve)
  local amounts = {}
  if type(line) ~= "table" or type(resolve) ~= "function" then return amounts end
  if type(line.item) == "string" and line.item ~= "" then
    amounts[line.item] = resolve(line.item)
  end
  if type(line.floorItem) == "string" and line.floorItem ~= "" then
    amounts[line.floorItem] = resolve(line.floorItem)
  end
  return amounts
end

-- Validate the operator-owned continuous-line configuration before the manager
-- sends it to an actuator. A bad config must fail closed (all line outputs OFF),
-- not silently merge two lines or accept a negative reserve.
function control.validateLines(lines)
  if type(lines) ~= "table" then return false, "lines must be a table" end
  local seen = {}
  for index, line in ipairs(lines) do
    if type(line) ~= "table" then return false, "line " .. index .. " is not a table" end
    if type(line.item) ~= "string" or line.item == "" then
      return false, "line " .. index .. " has no item"
    end
    local low = tonumber(line.low)
    if not low or low < 0 then return false, "line " .. index .. " has invalid low" end
    local high = line.high == nil and low or tonumber(line.high)
    if not high or high < low then return false, "line " .. index .. " has invalid high" end
    if line.floorItem ~= nil and (type(line.floorItem) ~= "string" or line.floorItem == "") then
      return false, "line " .. index .. " has invalid floor item"
    end
    if line.floorMin ~= nil and (not line.floorItem or (tonumber(line.floorMin) or -1) < 0) then
      return false, "line " .. index .. " has invalid floor minimum"
    end
    local key = line.name or line.item
    if type(key) ~= "string" or key == "" then return false, "line " .. index .. " has invalid name" end
    if seen[key] then return false, "duplicate line " .. key end
    seen[key] = true
  end
  return true
end

-- One redstone output may gate one line only. Keep this validation shared and
-- pure so the actuator can fail closed before it accepts any control packet.
control.LINE_SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

function control.validateLineOutputs(outputs)
  if type(outputs) ~= "table" or #outputs == 0 then return false, "no line outputs" end
  local seenLines, seenSides = {}, {}
  for index, output in ipairs(outputs) do
    if type(output) ~= "table" then return false, "output " .. index .. " is not a table" end
    local line, side = output.line, output.side
    if type(line) ~= "string" or line == "" then return false, "output " .. index .. " has no line" end
    if type(side) ~= "string" or not control.LINE_SIDES[side] then
      return false, "output " .. index .. " has invalid side"
    end
    if seenLines[line] then return false, "duplicate line " .. line end
    if seenSides[side] then return false, "duplicate side " .. side end
    seenLines[line], seenSides[side] = true, true
  end
  return true
end

-- The actuator starts OFF and calls this only after it has heard a valid packet.
-- Equality is expired: a manager exactly one stale window silent must not retain
-- an ON exporter for another timer turn.
function control.lineWatchdogExpired(lastHeard, now, staleMs)
  lastHeard, now, staleMs = tonumber(lastHeard), tonumber(now), tonumber(staleMs)
  if not lastHeard or not now or not staleMs or staleMs <= 0 then return false end
  return lastHeard > 0 and now - lastHeard >= staleMs
end

-- Validate a compact manager -> actuator packet. Sender, source, session,
-- sequence, and sentAt are all required: a stale rednet packet must never
-- re-enable an exporter after the manager has gone quiet or restarted.
-- Returns accepted(bool), nextState|reason. nextState is deliberately small so
-- the actuator can retain only the replay-protection fields it needs.
function control.linePacketAccept(previous, packet, senderId, managerId, now, maxAgeMs)
  previous = type(previous) == "table" and previous or {}
  local expected = tonumber(managerId)
  now, maxAgeMs = tonumber(now), tonumber(maxAgeMs)
  if not expected or not now or not maxAgeMs or maxAgeMs <= 0 then return false, "bad local packet policy" end
  if tonumber(senderId) ~= expected then return false, "sender not manager" end
  if type(packet) ~= "table" or packet.kind ~= "line_state" then return false, "bad packet" end
  if tonumber(packet.source) ~= expected then return false, "source not manager" end

  local session, sequence, sentAt = tonumber(packet.session), tonumber(packet.sequence), tonumber(packet.sentAt)
  if not session or session <= 0 or session % 1 ~= 0 then return false, "bad session" end
  if not sequence or sequence <= 0 or sequence % 1 ~= 0 then return false, "bad sequence" end
  if not sentAt or sentAt <= 0 then return false, "bad sentAt" end
  if sentAt > now + maxAgeMs then return false, "packet clock ahead" end
  if now - sentAt > maxAgeMs then return false, "stale packet" end

  if previous.session == session then
    if sequence <= (tonumber(previous.sequence) or 0) then return false, "replayed sequence" end
    if sentAt < (tonumber(previous.sentAt) or 0) then return false, "older packet" end
  elseif previous.session ~= nil and sentAt <= (tonumber(previous.sentAt) or 0) then
    return false, "older session packet"
  end

  return true, { session = session, sequence = sequence, sentAt = sentAt }
end

-- Why must a running soak end right now? Returns a reason string, or nil to keep
-- going. Checked every scan cycle. Order matters: a queue failure ends the soak
-- even if the deadline also passed (the report must name the failure, not the
-- clock), and an operator mode change always wins over waiting out the window.
--   state = { now = ms, failures = n (cqueue.failureCount), baseMode = mode }
function control.soakEndReason(soak, state)
  if type(soak) ~= "table" then return "invalid soak" end
  state = state or {}
  if (tonumber(state.failures) or 0) > 0 then return "queue failure" end
  if state.baseMode ~= nil and state.baseMode ~= control.MODE_MANUAL then
    return "mode " .. tostring(state.baseMode)
  end
  if (tonumber(state.now) or 0) >= (tonumber(soak.endsAt) or 0) then return "deadline" end
  return nil
end

function control.craftJobSettled(job)
  if job == nil then return true end
  if type(job) ~= "table" then
    local msg = tostring(job):lower()
    return msg:find("not_found", 1, true) ~= nil or msg:find("not found", 1, true) ~= nil
  end

  for _, field in ipairs({ "done", "isDone", "canceled", "cancelled", "error", "errored" }) do
    if job[field] == true then return true end
  end
  for _, method in ipairs({ "isDone", "isCanceled", "isCancelled", "hasErrorOccurred", "isCalculationNotSuccessful" }) do
    if type(job[method]) == "function" then
      local ok, value = pcall(job[method])
      if ok and value == true then return true end
    end
  end
  return false
end

function control.unsettledJobs(bridge, outstanding)
  local result = { count = 0, checked = 0, method = "none", jobs = {} }
  if type(outstanding) ~= "table" or #outstanding == 0 then return result end
  if not bridge or type(bridge.getCraftingTask) ~= "function" then
    result.method = "missing"
    return result
  end

  result.method = "getCraftingTask"
  for _, entry in ipairs(outstanding) do
    local id = type(entry) == "table" and (entry.id or entry.jobId) or entry
    if id ~= nil then
      result.checked = result.checked + 1
      local ok, job = pcall(bridge.getCraftingTask, id)
      if ok then
        if not control.craftJobSettled(job) then
          result.count = result.count + 1
          result.jobs[#result.jobs + 1] = { id = id, name = type(entry) == "table" and entry.name or nil }
        end
      else
        local msg = tostring(job):lower()
        if not (msg:find("not_found", 1, true) or msg:find("not found", 1, true)) then
          result.count = result.count + 1
          result.jobs[#result.jobs + 1] = {
            id = id,
            name = type(entry) == "table" and entry.name or nil,
            reason = tostring(job),
          }
        end
      end
    end
  end
  return result
end

local function taskResource(task)
  if type(task) ~= "table" then return nil end
  if type(task.resource) == "table" then return task.resource end
  if type(task.item) == "table" then return task.item end
  if type(task.output) == "table" then return task.output end
  return nil
end

local function pctFromTask(task, crafted, quantity)
  local p = tonumber(type(task) == "table" and task.completion or nil)
  if p then
    if p >= 0 and p <= 1 then return math.floor((p * 100) + 0.5) end
    if p > 1 and p <= 100 then return math.floor(p + 0.5) end
  end
  if crafted and quantity and quantity > 0 then
    return math.max(0, math.min(100, math.floor((crafted / quantity) * 100 + 0.5)))
  end
  return nil
end

function control.normalizeCraftTask(task)
  if type(task) ~= "table" then return nil end
  local res = taskResource(task)
  local name = task.name or task.target or (type(res) == "table" and res.name)
  local label = task.label or task.displayName or (type(res) == "table" and res.displayName) or name
  local crafted = tonumber(task.crafted or task.done or task.completed)
  local quantity = tonumber(task.quantity or task.requested or task.count or task.amount
    or (type(res) == "table" and (res.count or res.amount)))
  return {
    name = name,
    label = label,
    id = task.id or task.taskId or task.uuid,
    bridgeId = task.bridge_id or task.bridgeId,
    crafted = crafted,
    quantity = quantity,
    completion = tonumber(task.completion),
    progressPct = pctFromTask(task, crafted, quantity),
  }
end

-- Authoritative live craft snapshot straight from the rs_bridge -- independent of
-- the manager's craftstate file (which goes STALE the moment you Ctrl+T the manager).
-- Tries task-list methods first (AP-version-dependent), then falls back to per-item
-- isItemCrafting over the supplied names. Returns:
--   { count=n, method=str, tasks={...}, byName={ [registry]=task } }
function control.activeCraftSnapshot(bridge, fallbackNames)
  local snap = { count = 0, method = "none", tasks = {}, byName = {} }
  if not bridge then snap.method = "no-bridge"; return snap end
  for _, m in ipairs({ "getCraftingTasks", "getTasks", "listCraftingTasks" }) do
    if type(bridge[m]) == "function" then
      local ok, res = pcall(bridge[m])
      if ok and type(res) == "table" then
        snap.count = #res
        snap.method = m
        for _, raw in ipairs(res) do
          local task = control.normalizeCraftTask(raw) or {}
          snap.tasks[#snap.tasks + 1] = task
          if task.name then snap.byName[task.name] = task end
        end
        return snap
      end
    end
  end
  if type(bridge.isItemCrafting) == "function" and type(fallbackNames) == "table" then
    for _, name in ipairs(fallbackNames) do
      local ok, res = pcall(bridge.isItemCrafting, { name = name })
      if ok and res == true then
        local task = { name = name, label = name }
        snap.tasks[#snap.tasks + 1] = task
        snap.byName[name] = task
      end
    end
    snap.count = #snap.tasks
    snap.method = "isItemCrafting"
    return snap
  end
  return snap
end

-- Count wrapper kept for safereboot and old callers.
-- Returns: count (number), method (string: the source used / "no-bridge" / "none").
function control.activeCraftCount(bridge, fallbackNames)
  local snap = control.activeCraftSnapshot(bridge, fallbackNames)
  return snap.count, snap.method
end

-- Per-job settled check over the craftItem job ids the manager recorded in its
-- drain snapshot. This closes the CALCULATION-phase hole: AP keeps ticking a job
-- (and will fire a CC event at this computer when its preview resolves) even
-- while getCraftingTasks reads empty, because that list only mirrors RS's ACTIVE
-- tasks. A job is SETTLED once the bridge no longer knows its id (AP purged it,
-- so every event has already fired) or it reports done/canceled/errored.
-- outstanding = { {id=, name=, at=}, ... } from .atm10-craftstate.
-- Returns the unsettled count, or nil when there are recorded jobs but no
-- getCraftingTask API to check them -- callers must then use the blind window.
-- ===========================================================================
-- CONTROL COMMANDS (CTRL-1): the foundation for the eventual control center.
-- A `command` is a pure data shape { action, target, args, token }; dispatch()
-- validates it against the capability gates + token and, only when every check
-- passes, hands off to a host-injected `actuator` to perform the real side effect.
-- dispatch NEVER touches a peripheral itself, so it stays pure + unit-testable and
-- is the single authorization chokepoint every control action must pass through --
-- safe for multi-user use (gate everything; default deny).
-- ===========================================================================

-- The recognized control actions -> the capability each requires. Introducing a new
-- control action = add an entry here AND an actuator branch on the host; dispatch
-- refuses anything not listed (default deny). target meaning is per-action (e.g. a
-- redstone side); args carries action-specific params (e.g. { level = 15 }).
control.COMMANDS = {
  redstone_set    = { capability = control.CAPABILITY_REDSTONE, label = "Set a redstone output" },
  redstone_toggle = { capability = control.CAPABILITY_REDSTONE, label = "Toggle a redstone output" },
  -- A1: enqueue a one-time craft job (manual/oneshot). target = item registry name;
  -- args = { count = N, force = bool }. Gated on the autocraft capability + token,
  -- identical to the redstone commands. The host injects a craft_request actuator that
  -- enqueues the job into the manual craft queue (dispatch never crafts itself).
  craft_request   = { capability = control.CAPABILITY_AUTOCRAFT, label = "Request a one-time craft job" },
}

-- Build a control command (plain data; the host/sender fills these in).
function control.command(args)
  args = args or {}
  return { action = args.action, target = args.target, args = args.args, token = args.token }
end

-- Validate + dispatch a control command. policy = control.policy{...}; actuator =
-- function(command, spec) that performs the side effect (injected by the host).
-- Returns { ok = bool, reason = str, action = str|nil }. The actuator is invoked AT
-- MOST ONCE, only after the action is recognized, the token matches (when the policy
-- sets one), and the action's capability is allowed. Default deny on anything else.
function control.dispatch(cmd, policy, actuator)
  policy = policy or {}

  if type(cmd) ~= "table" then
    return { ok = false, reason = "bad command", action = nil }
  end

  local spec = control.COMMANDS[cmd.action]
  if not spec then
    return { ok = false, reason = "unknown action", action = cmd.action }
  end

  -- token: when the policy sets one, the command must carry the matching token
  -- (the transport layer may also check this; defense in depth).
  if policy.token ~= nil and cmd.token ~= policy.token then
    return { ok = false, reason = "bad token", action = cmd.action }
  end

  local allowed, capabilityReason = control.isCapabilityAllowed(spec.capability, policy)
  if not allowed then
    return { ok = false, reason = capabilityReason, action = cmd.action }
  end

  if type(actuator) ~= "function" then
    return { ok = false, reason = "no actuator", action = cmd.action }
  end

  -- contain a misbehaving actuator (local peripheral side effect) so a bad output
  -- can't crash the dispatch loop; still counts as one invocation.
  local ok, err = pcall(actuator, cmd, spec)
  if not ok then
    return { ok = false, reason = "actuator error: " .. tostring(err), action = cmd.action }
  end

  return { ok = true, reason = "ok", action = cmd.action }
end

-- CTRL-2: receive an inbound control message (e.g. from a rednet "control" channel).
-- Authorizes the SENDER (allowlist) + TOKEN against the policy, then feeds the
-- command to dispatch. On an auth failure it returns WITHOUT dispatching, so the
-- actuator is never reached -- the transport layer is the first gate, dispatch the
-- second. senderId comes from the transport; message is the received table carrying
-- the command fields { action, target, args, token }. actuator injected by the host.
function control.handleMessage(senderId, message, policy, actuator)
  policy = policy or {}

  local okAuth, authReason = control.authorize(senderId, message, policy)
  if not okAuth then
    return { ok = false, reason = authReason, action = (type(message) == "table") and message.action or nil }
  end

  return control.dispatch(control.command(message or {}), policy, actuator)
end

-- CTRL-3: a redstone actuator for dispatch -- the first REAL control output. The
-- redstone API is injected (the CC `rs`/`redstone` global on the host, a fake in
-- tests) and `state` tracks each side's current level so redstone_toggle can flip
-- it. It only ever drives the command's target side; dispatch has already enforced
-- the redstone capability, so reaching here means the action is authorized.
--   redstone_toggle: flip the side between 0 and 15.
--   redstone_set:    args.level (0-15) or args.on (bool); defaults ON.
-- Returns the level set (0-15).
function control.redstoneActuator(rsApi, state)
  rsApi = rsApi or {}
  state = state or {}
  return function(cmd)
    local side = cmd.target
    if type(side) ~= "string" or side == "" then error("missing redstone side", 0) end
    local args = (type(cmd.args) == "table") and cmd.args or {}

    local level
    if cmd.action == "redstone_toggle" then
      level = ((tonumber(state[side]) or 0) > 0) and 0 or 15
    elseif args.level ~= nil then
      level = math.max(0, math.min(15, math.floor(tonumber(args.level) or 0)))
    elseif args.on ~= nil then
      level = (args.on == true) and 15 or 0
    else
      level = 15
    end

    state[side] = level
    if level > 0 and level < 15 and type(rsApi.setAnalogOutput) == "function" then
      rsApi.setAnalogOutput(side, level)
    else
      rsApi.setOutput(side, level > 0)
    end
    return level
  end
end

return control
