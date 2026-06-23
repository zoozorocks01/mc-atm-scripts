local PROGRAM = "power-display"
local RESTART_DELAY = 5

local function log(message)
  term.setTextColor(colors.white)
  print(message)
end

while true do
  term.clear()
  term.setCursorPos(1, 1)
  log("Starting " .. PROGRAM)

  local ok, result = pcall(shell.run, PROGRAM)
  if not ok and tostring(result) == "Terminated" then
    error("Terminated", 0)
  end

  term.setTextColor(colors.red)
  if ok then
    print(PROGRAM .. " stopped.")
  else
    print(PROGRAM .. " crashed:")
    print(tostring(result))
  end

  term.setTextColor(colors.yellow)
  print("Restarting in " .. RESTART_DELAY .. "s...")
  sleep(RESTART_DELAY)
end
