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

-- gateCrafts(state, ok, threshold)
--   Folds this cycle's bridge outcome into the consecutive-failure count (via
--   bridgeDegraded) AND returns the fire/hold decision in one call, so the
--   manager holds no decision logic of its own. Returns
--   (allowFire, degraded, count): allowFire == not degraded. Pure -- the caller
--   owns `state`; this fn never touches a peripheral.
--
--   Wire ok=false on any bridge-read failure (scan's no-bridge / offline / stale
--   branch), ok=true on a clean scan. When degraded, the manager must SKIP firing
--   craftItem this cycle: a flaky bridge that is intermittently answering reads is
--   exactly the half-attached state in which the mutating craftItem is the
--   uncatchable-crash trigger. A single clean scan resets the count and re-allows
--   firing automatically (no latch, no manual clear).
function health.gateCrafts(state, ok, threshold)
  local degraded, count = health.bridgeDegraded(state, ok, threshold)
  return (not degraded), degraded, count
end

return health
