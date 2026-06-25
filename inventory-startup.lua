local PROGRAM = "inventory-info"
local RESTART_DELAY = 5
local HEARTBEAT_FILE = ".atm10-heartbeat"
local WATCHDOG_TIMEOUT = 90 -- seconds without a heartbeat before the program is treated as hung
local WATCHDOG_POLL = 5

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

-- Seconds since the program's last heartbeat, or nil if it has not emitted one.
local function heartbeatAge()
  if not fs.exists(HEARTBEAT_FILE) then return nil end
  local f = fs.open(HEARTBEAT_FILE, "r")
  if not f then return nil end
  local text = f.readAll()
  f.close()
  local hb = tonumber((text or ""):match("%-?%d+"))
  if not hb then return nil end
  return (nowMs() - hb) / 1000
end

-- Ends the parallel run (restarting the PROGRAM) when the program stops emitting
-- heartbeats -- i.e. it is HUNG, not crashed (a crash ends shell.run on its own,
-- which the loop below already handles). Crucially this restarts only the PROGRAM,
-- never the computer: the rs_bridge stays attached, so there is no AdvancedPeripherals
-- detach-crash risk from auto-recovery.
local function watchdog()
  sleep(WATCHDOG_TIMEOUT) -- grace: let the program boot and emit its first heartbeat
  while true do
    local age = heartbeatAge()
    if not age or age > WATCHDOG_TIMEOUT then return end
    sleep(WATCHDOG_POLL)
  end
end

while true do
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("Starting " .. PROGRAM)

  -- drop any prior run's heartbeat so the watchdog measures THIS run only
  if fs.exists(HEARTBEAT_FILE) then pcall(fs.delete, HEARTBEAT_FILE) end

  local ok, result
  local hung = false
  parallel.waitForAny(
    function() ok, result = pcall(shell.run, PROGRAM) end,
    function() watchdog(); hung = true end
  )

  -- a real Ctrl+T terminate should drop the operator to a shell, not auto-restart
  if not hung and not ok and tostring(result) == "Terminated" then
    error("Terminated", 0)
  end

  if hung then
    term.setTextColor(colors.orange)
    print(PROGRAM .. " not responding (no heartbeat for " .. WATCHDOG_TIMEOUT .. "s); restarting.")
  else
    term.setTextColor(colors.red)
    if ok then
      print(PROGRAM .. " stopped.")
    else
      print(PROGRAM .. " crashed:")
      print(tostring(result))
    end
  end

  term.setTextColor(colors.yellow)
  print("Restarting in " .. RESTART_DELAY .. "s...")
  sleep(RESTART_DELAY)
end
