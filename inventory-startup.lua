local PROGRAM = "inventory-info"
local RESTART_DELAY = 5
local HEARTBEAT_FILE = ".atm10-heartbeat"
local WATCHDOG_TIMEOUT = 90 -- seconds without a heartbeat before the program is treated as hung
local WATCHDOG_POLL = 5
-- Crash-loop backoff: a program that exits in under FAST_FAIL_SECONDS counts as a
-- fast failure (bad config, missing peripheral, broken self-update). After
-- BACKOFF_AFTER consecutive fast failures, walk the restart delay up BACKOFF_STEPS
-- (capped) and show a loud persistent banner instead of hammering a tight 5s crash
-- loop forever. A run that survives past the threshold resets the counter. (A HUNG
-- restart ran >= the watchdog grace, so it never counts as a fast failure.)
local FAST_FAIL_SECONDS = 30
local BACKOFF_AFTER = 3
local BACKOFF_STEPS = { 5, 10, 30, 60 }
local CONFIG_HINT = "inventory-config (the rs_bridge + monitor)"

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

-- Restart delay for the current fast-failure streak; second return is true once we
-- are in crash-loop backoff (so the caller shows the persistent banner).
local function backoffDelay(fastFailures)
  if fastFailures < BACKOFF_AFTER then return RESTART_DELAY, false end
  local step = math.min(fastFailures - BACKOFF_AFTER + 1, #BACKOFF_STEPS)
  return BACKOFF_STEPS[step], true
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

local fastFailures = 0

while true do
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("Starting " .. PROGRAM)
  -- The ONLY real fix for the AdvancedPeripherals detach crash is keeping this CC
  -- chunk loaded; a reboot/unload while a craft job is pending crashes the server
  -- tick. Remind the operator on every boot (see README "Stability").
  term.setTextColor(colors.orange)
  print("STABILITY: this computer must be chunk force-loaded (see README).")

  -- drop any prior run's heartbeat so the watchdog measures THIS run only
  if fs.exists(HEARTBEAT_FILE) then pcall(fs.delete, HEARTBEAT_FILE) end

  local startedAt = os.clock()
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

  -- count consecutive fast failures; a hung restart or a long-lived run resets it
  if not hung and (os.clock() - startedAt) < FAST_FAIL_SECONDS then
    fastFailures = fastFailures + 1
  else
    fastFailures = 0
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

  local delay, backingOff = backoffDelay(fastFailures)
  if backingOff then
    term.setTextColor(colors.red)
    print("PERSISTENT CRASH: " .. PROGRAM .. " keeps failing fast (" .. fastFailures .. "x).")
    print("Check " .. CONFIG_HINT .. ".")
  end

  term.setTextColor(colors.yellow)
  print("Restarting in " .. delay .. "s...")
  sleep(delay)
end
