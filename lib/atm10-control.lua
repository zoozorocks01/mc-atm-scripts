local status = require("atm10-status")

local control = {}

control.PROTOCOL = "atm10-control-v1"

control.MODE_MONITOR = "monitor"
control.MODE_DRY_RUN = "dry-run"
control.MODE_MANUAL = "manual"
control.MODE_AUTO = "auto"

control.CAPABILITY_AUTOCRAFT = "autocraft"
control.CAPABILITY_EXPORT = "export"
control.CAPABILITY_REDSTONE = "redstone"
control.CAPABILITY_SECURITY = "security"

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

return control
