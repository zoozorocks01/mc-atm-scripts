-- atm10-reload: apply updated manager/libs without rebooting the rs_bridge computer.
--
-- Rebooting detaches the AdvancedPeripherals bridge and can crash the server if AP
-- still has a craft job that may fire an event. This command asks the running
-- manager to drain and exit, asks the startup wrapper not to auto-restart it with
-- stale package.loaded modules, clears cached atm10-* modules, then starts the
-- manager through the normal startup watchdog again in this same computer session.

local PROGRAM = "startup"
local DRAIN_REQUEST_FILE = ".atm10-drain-request"
local RELOAD_REQUEST_FILE = ".atm10-reload-request"
local CRAFTSTATE_FILE = ".atm10-craftstate"
local HEARTBEAT_FILE = ".atm10-heartbeat"
local POLL_SECONDS = 3
local HEARTBEAT_STALE_MS = 30000

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local text = f.readAll()
  f.close()
  return text
end

local function readSerializedFile(path)
  local text = readText(path)
  if not text then return nil end
  local ok, data = pcall(textutils.unserialize, text)
  if ok then return data end
  return nil
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(tostring(text or ""))
  f.close()
  return true
end

local function writeSerializedFile(path, data)
  local ok, text = pcall(textutils.serialize, data)
  if not ok or type(text) ~= "string" then return false end
  return writeText(path, text)
end

local function heartbeatFresh(now)
  local at = tonumber(readText(HEARTBEAT_FILE))
  if not at then return false, "heartbeat missing" end
  local age = math.max(0, now - at)
  return age <= HEARTBEAT_STALE_MS, "heartbeat age " .. math.ceil(age / 1000) .. "s"
end

local function drainAcked(state, requestedAt)
  if type(state) ~= "table" or state.drainAck ~= true then return false end
  return tostring(state.drainRequestAt) == tostring(requestedAt)
end

-- Both flags carry a renewal timestamp and are rewritten every poll: the manager
-- and the startup wrapper honor them only while fresh, so an aborted (Ctrl+T)
-- atm10-reload cannot quiesce the manager forever or strand the wrapper into
-- exiting on a later, unrelated program stop.
local function writeRequests(requestedAt, now)
  now = now or requestedAt
  local drainOk = writeSerializedFile(DRAIN_REQUEST_FILE,
    { requestedAt = requestedAt, renewedAt = now, reload = true })
  local reloadOk = writeText(RELOAD_REQUEST_FILE, tostring(now))
  return drainOk and reloadOk
end

local function waitForManagerToDrainAndStop(requestedAt)
  while true do
    local now = nowMs()
    writeRequests(requestedAt, now)
    local fresh, heartbeatReason = heartbeatFresh(now)
    if not fresh then
      print("atm10-reload: manager not running (" .. heartbeatReason .. ")")
      return true
    end

    local craftState = readSerializedFile(CRAFTSTATE_FILE) or {}
    if drainAcked(craftState, requestedAt) then
      print("atm10-reload: manager acknowledged drain; waiting for it to stop")
    else
      print("atm10-reload: waiting for manager drain ack (" .. heartbeatReason .. ")")
    end
    sleep(POLL_SECONDS)
  end
end

local function clearAtm10Modules()
  local n = 0
  for name in pairs(package.loaded or {}) do
    if type(name) == "string" and name:match("^atm10%-") then
      package.loaded[name] = nil
      n = n + 1
    end
  end
  return n
end

local requestedAt = nowMs()
print("atm10-reload: requesting manager drain")
if not writeRequests(requestedAt) then
  print("atm10-reload: could not write reload request files; aborting")
  return
end

waitForManagerToDrainAndStop(requestedAt)

local cleared = clearAtm10Modules()
pcall(fs.delete, DRAIN_REQUEST_FILE)
pcall(fs.delete, RELOAD_REQUEST_FILE)
pcall(fs.delete, HEARTBEAT_FILE)

print("atm10-reload: cleared " .. cleared .. " cached atm10 module(s)")
print("atm10-reload: starting " .. PROGRAM)
local ok = shell.run(PROGRAM)
if ok == false then
  print("atm10-reload: " .. PROGRAM .. " did not start cleanly")
end
