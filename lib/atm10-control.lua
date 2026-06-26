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
