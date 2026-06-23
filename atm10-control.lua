local status = require("atm10-status")

local control = {}

control.MODE_MONITOR = "monitor"
control.MODE_DRY_RUN = "dry-run"
control.MODE_MANUAL = "manual"
control.MODE_AUTO = "auto"

local validModes = {
  ["monitor"] = true,
  ["dry-run"] = true,
  ["manual"] = true,
  ["auto"] = true,
}

function control.normalizeMode(value, default)
  if validModes[value] then return value end
  return default or control.MODE_DRY_RUN
end

function control.action(args)
  args = args or {}
  return {
    id = args.id or args.label or "unnamed",
    system = args.system or "unknown",
    label = args.label or args.id or "Unnamed Action",
    kind = args.kind or "unknown",
    target = args.target,
    amount = args.amount,
    reason = args.reason,
    mode = control.normalizeMode(args.mode),
    enabled = args.enabled == true,
    approved = args.approved == true,
    status = status.normalize(args.status or status.WOULD),
    execute = args.execute,
  }
end

function control.executionState(action)
  if not action then return status.UNKNOWN, "missing action" end
  local mode = control.normalizeMode(action.mode)

  if action.enabled ~= true then
    return status.DISABLED, "disabled"
  end

  if mode == control.MODE_MONITOR then
    return status.DISABLED, "monitor only"
  end

  if mode == control.MODE_DRY_RUN then
    return status.WOULD, "planning only"
  end

  if mode == control.MODE_MANUAL and action.approved ~= true then
    return status.COOLDOWN, "waiting approval"
  end

  if type(action.execute) ~= "function" then
    return status.BLOCKED, "no executor"
  end

  return status.OK, "ready"
end

function control.canExecute(action)
  local state = control.executionState(action)
  return state == status.OK
end

function control.describe(action)
  local state, reason = control.executionState(action)
  return {
    id = action and action.id or "missing",
    system = action and action.system or "unknown",
    label = action and action.label or "Missing Action",
    kind = action and action.kind or "unknown",
    target = action and action.target or nil,
    amount = action and action.amount or nil,
    reason = reason,
    status = state,
    tag = status.tag(state),
  }
end

function control.describeAll(actions)
  local out = {}
  for _, action in ipairs(actions or {}) do
    out[#out + 1] = control.describe(action)
  end
  return out
end

function control.execute(action)
  local state, reason = control.executionState(action)
  if state ~= status.OK then
    return false, reason
  end

  return action.execute(action)
end

return control
