-- atm10-health: pure bridge-health tracking.
--
-- The manager's call() wrapper swallows bridge call failures to nil, so a flaky
-- or half-detached bridge currently reads as "fine" until it fully drops. This
-- pure helper tracks consecutive failures and reports a degraded state once they
-- cross a threshold, so the manager (or a future header chip) can surface it.
--
-- No side effects, no peripheral access: the caller owns the state table and
-- decides what to do with the result. Lib file, so it does not count against the
-- manager's top-level locals cap.

local health = {}

health.DEFAULT_THRESHOLD = 3
health.DEFAULT_RECOVER = 2

-- bridgeDegraded(state, ok, threshold)
--   state     : a table the caller persists across calls; this fn maintains
--               state.bridgeFails (consecutive failure count). Created lazily.
--   ok        : the outcome of the last bridge call -- true = success,
--               anything falsy (nil/false) = failure.
--   threshold : how many consecutive failures before degraded (default 3).
--
-- On failure the count increments; on success it resets to 0. Returns
-- (degraded, count): degraded is true once count >= threshold. The count is
-- monotonic across failures until a success resets it.
function health.bridgeDegraded(state, ok, threshold)
  if type(state) ~= "table" then error("bridgeDegraded: state table required", 0) end
  local n = tonumber(threshold) or health.DEFAULT_THRESHOLD
  if n < 1 then n = 1 end

  if ok == true then
    state.bridgeFails = 0
  else
    state.bridgeFails = (tonumber(state.bridgeFails) or 0) + 1
  end

  return state.bridgeFails >= n, state.bridgeFails
end

-- gateCrafts(state, ok, threshold, recoverCycles)
--   The fire/hold decision the manager wires in, with RECOVERY HYSTERESIS so it
--   actually protects the dangerous bridge RE-ATTACH window. Folds this cycle's
--   bridge read outcome into the persisted `state` and returns whether craftItem
--   may fire this cycle. Pure -- the caller owns `state`; never touches a peripheral.
--
--   Wire ok=false on any bridge-read failure (scan's no-bridge / offline / stale
--   branch), ok=true on a clean scan. The mutating craftItem at a half-attached
--   bridge is the uncatchable AdvancedPeripherals crash trigger, and the worst
--   moment is right when the bridge comes BACK after a detach (reboot/chunk reload)
--   but is still settling -- a single clean read there is not proof it is safe.
--   So:
--     * ok==false -> bridgeFails++, cleanStreak=0; once bridgeFails reaches
--                    `threshold` consecutive failures the bridge is marked unsafe
--                    (state.holding=true) and firing is held.
--     * ok==true  -> bridgeFails=0, cleanStreak++; while unsafe, firing stays HELD
--                    until `recoverCycles` consecutive clean reads, then resumes.
--   A never-failed bridge starts safe (holding falsy) so steady-state fires
--   normally. NOTE: the earlier version reset on the FIRST clean read, which made
--   the gate a no-op -- the clean read that returns the data also re-allowed firing,
--   so the manager's hold-guard was never reached on the data path. Hysteresis fixes
--   that. Returns (allowFire, holding, fails, cleanStreak).
function health.gateCrafts(state, ok, threshold, recoverCycles)
  if type(state) ~= "table" then error("gateCrafts: state table required", 0) end
  local th = tonumber(threshold) or health.DEFAULT_THRESHOLD
  if th < 1 then th = 1 end
  local rec = tonumber(recoverCycles) or health.DEFAULT_RECOVER
  if rec < 1 then rec = 1 end

  if ok == true then
    state.bridgeFails = 0
    state.cleanStreak = (tonumber(state.cleanStreak) or 0) + 1
    if state.cleanStreak > rec then state.cleanStreak = rec end
    if state.holding and state.cleanStreak >= rec then state.holding = false end
  else
    state.cleanStreak = 0
    state.bridgeFails = (tonumber(state.bridgeFails) or 0) + 1
    if state.bridgeFails > th then state.bridgeFails = th end
    if state.bridgeFails >= th then state.holding = true end
  end

  return (not state.holding), (state.holding == true),
         state.bridgeFails or 0, state.cleanStreak or 0
end

return health
