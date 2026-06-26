-- reboot guard -- deployed ONLY to the manager (the RS-Bridge computer), where it
-- shadows the built-in `reboot` program (the shell searches the current dir before
-- /rom/programs, so this file wins when you type `reboot`).
--
-- WHY: a plain reboot of the RS-Bridge computer crashes the WHOLE SERVER if
-- AdvancedPeripherals still has a craft job pending -- it fires the job's completion
-- event at the now-detached computer and throws an uncatchable NotAttachedException
-- on the server thread. `safereboot` waits out the craft-drain window first, so the
-- bridge is never detached mid-job. This guard makes `reboot` do the safe thing.
--
-- Pass --force only when you KNOW nothing is crafting (forwarded to safereboot).
-- True emergency hard reboot that bypasses the guard:  rom/programs/reboot

local args = { ... }

term.setTextColor(colors.orange)
print("[guard] 'reboot' redirects to safereboot here (drain-safe; avoids the AP server-crash).")
term.setTextColor(colors.white)

local ok = shell.run("safereboot", table.unpack(args))
if ok == false then
  term.setTextColor(colors.red)
  print("[guard] safereboot did not run.")
  print("[guard] Emergency hard reboot (UNSAFE if crafting): rom/programs/reboot")
  term.setTextColor(colors.white)
end
