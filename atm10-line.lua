-- atm10-line.lua : production-line actuator (docs/DECISIONS.md #4).
--
-- Runs on a SMALL computer near a machine line (e.g. the smelter bank). It
-- listens for the manager's rednet broadcast and turns each configured line's
-- decision into a redstone output that gates that line's RS Exporter.
--
-- Usage (in the mini computer's shell, or its startup file):
--   atm10-line --manager <manager-computer-id> <line>:<side> [<line>:<side> ...]
--   e.g.  atm10-line --manager 42 aluminum:back copper:left
-- Line names must match `config.lines[].name` in the manager's inventory-config.
-- Keep atm10-control.lua beside this program; it validates packets before a
-- redstone output can change.
--
-- DEAD-MAN SWITCH: if no fresh manager broadcast arrives within STALE_MS, every
-- output goes OFF. A dead or unreachable manager can never leave a line running
-- unattended -- same fail-safe philosophy as the safereboot drain flag.

local PROTOCOL = "atm10-lines-v1"
local STALE_MS = 30000 -- outputs drop OFF beyond this silence

local ok, control = pcall(require, "atm10-control")
if not ok then
  print("atm10-line: missing atm10-control.lua; staying OFF")
  return
end

local args = { ... }
local function failClosedSpecs(specs)
  local sides = {}
  for _, spec in ipairs(specs or {}) do
    local _, side = tostring(spec):match("^([^:]+):(%a+)$")
    if side and control.LINE_SIDES[side] then sides[side] = true end
  end
  for side in pairs(sides) do pcall(rs.setOutput, side, false) end
end

local managerId
if args[1] == "--manager" then
  managerId = math.floor(tonumber(args[2]) or -1)
  table.remove(args, 1)
  table.remove(args, 1)
end
if not managerId or managerId < 0 or #args == 0 then
  failClosedSpecs(args)
  print("usage: atm10-line --manager <manager-computer-id> <line>:<side> [...]")
  print("e.g.   atm10-line --manager 42 aluminum:back copper:left")
  return
end

local outputs = {}
local function failClosed()
  for _, output in ipairs(outputs) do pcall(rs.setOutput, output.side, false) end
end

for _, spec in ipairs(args) do
  local line, side = tostring(spec):match("^([^:]+):(%a+)$")
  if not line or not control.LINE_SIDES[side] then
    failClosed()
    print("bad spec '" .. tostring(spec) .. "' (want <line>:<side>, side one of top/bottom/left/right/front/back)")
    return
  end
  outputs[#outputs + 1] = { line = line, side = side, on = false }
end
local topologyOK, topologyReason = control.validateLineOutputs(outputs)
if not topologyOK then
  failClosed()
  print("invalid line topology: " .. tostring(topologyReason) .. " (all configured outputs OFF)")
  return
end

local function openModem()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
      rednet.open(side)
      return true
    end
  end
  return false
end

if not openModem() then
  print("no modem attached - place a (wireless) modem on any side")
  return
end

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function apply(quietly)
  for _, o in ipairs(outputs) do
    rs.setOutput(o.side, o.on == true)
    if not quietly then
      print(("%s -> %s (%s): %s"):format(o.line, o.side, o.on and "ON" or "OFF", o.reason or ""))
    end
  end
end

-- Fail-safe boot posture: everything OFF until the first fresh broadcast.
apply(true)
print("atm10-line: listening for manager " .. managerId .. " (" .. PROTOCOL .. ")")
local lastHeard = 0
local packetState = {}
local watchdogTimer

local function armWatchdog()
  if watchdogTimer and os.cancelTimer then os.cancelTimer(watchdogTimer) end
  watchdogTimer = os.startTimer(math.max(1, math.ceil(STALE_MS / 1000)))
end

armWatchdog()

while true do
  local event, p1, p2, p3 = os.pullEvent()
  if event == "rednet_message" and p3 == PROTOCOL and type(p2) == "table" and type(p2.lines) == "table" then
    local heardAt = nowMs()
    local accepted, nextState = control.linePacketAccept(packetState, p2, p1, managerId, heardAt, STALE_MS)
    if accepted then
      packetState, lastHeard = nextState, heardAt
      armWatchdog()
      local changed = false
      for _, o in ipairs(outputs) do
        local st = p2.lines[o.line]
        local want = (type(st) == "table" and st.on == true) or false
        local reason = (type(st) == "table" and st.reason)
          or (st == nil and "line not in manager config" or nil)
        if want ~= o.on or reason ~= o.reason then changed = true end
        o.on, o.reason = want, reason
      end
      if changed then apply() end
    end
  elseif event == "timer" and p1 == watchdogTimer then
    if control.lineWatchdogExpired(lastHeard, nowMs(), STALE_MS) then
      local anyOn = false
      for _, o in ipairs(outputs) do anyOn = anyOn or o.on end
      for _, o in ipairs(outputs) do o.on, o.reason = false, "manager silent (dead-man)" end
      if anyOn then
        apply()
        print("manager silent > " .. math.floor(STALE_MS / 1000) .. "s - all lines OFF (dead-man)")
      end
      lastHeard = 0 -- report once, stay off until broadcasts resume
    end
    armWatchdog()
  end
end
