local PROGRAM = "power-display"
local RESTART_DELAY = 5
-- Crash-loop backoff: a program that exits in under FAST_FAIL_SECONDS counts as a
-- fast failure (bad config, missing peripheral, broken self-update). After
-- BACKOFF_AFTER consecutive fast failures, walk the restart delay up BACKOFF_STEPS
-- (capped) and show a loud persistent banner instead of hammering a tight 5s crash
-- loop forever. A run that survives past the threshold resets the counter.
local FAST_FAIL_SECONDS = 30
local BACKOFF_AFTER = 3
local BACKOFF_STEPS = { 5, 10, 30, 60 }
local CONFIG_HINT = "the monitor + modem"

local function log(message)
  term.setTextColor(colors.white)
  print(message)
end

-- Restart delay for the current fast-failure streak; second return is true once we
-- are in crash-loop backoff (so the caller shows the persistent banner).
local function backoffDelay(fastFailures)
  if fastFailures < BACKOFF_AFTER then return RESTART_DELAY, false end
  local step = math.min(fastFailures - BACKOFF_AFTER + 1, #BACKOFF_STEPS)
  return BACKOFF_STEPS[step], true
end

local fastFailures = 0

while true do
  term.clear()
  term.setCursorPos(1, 1)
  log("Starting " .. PROGRAM)

  local startedAt = os.clock()
  local ok, result = pcall(shell.run, PROGRAM)
  if not ok and tostring(result) == "Terminated" then
    error("Terminated", 0)
  end

  -- count consecutive fast failures; a long-lived run resets the streak
  if (os.clock() - startedAt) < FAST_FAIL_SECONDS then
    fastFailures = fastFailures + 1
  else
    fastFailures = 0
  end

  term.setTextColor(colors.red)
  if ok then
    print(PROGRAM .. " stopped.")
  else
    print(PROGRAM .. " crashed:")
    print(tostring(result))
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
