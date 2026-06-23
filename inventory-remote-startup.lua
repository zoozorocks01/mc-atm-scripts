local PROGRAM = "inventory-remote"
local RESTART_DELAY = 5

while true do
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("Starting " .. PROGRAM)

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
