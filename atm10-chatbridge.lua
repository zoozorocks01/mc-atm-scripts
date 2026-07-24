-- atm10-chatbridge.lua : in-game chat command grammar + reply shaping for the
-- manager's (future) Chat Box peripheral, and the agent outbound spool.
--
-- Pure compute, no peripherals. The manager (which runs 24/7 on computer 6,
-- independent of any agent session) will own the Chat Box; this module holds
-- everything testable about that conversation:
--   (1) parse a player chat line into a command intent   -> chatbridge.parse()
--   (2) answer an intent from EXISTING state snapshots   -> chatbridge.reply()
--   (3) split any outbound text to a safe chat length    -> chatbridge.split()
--   (4) drain an agent-dropped outbound spool, rate-capped -> chatbridge.outbound()
--   (5) turn agent-heartbeat staleness into honest seat
--       presence announcements (never claim a listener
--       that is not running)                             -> chatbridge.presence()
--
-- Grammar (typed by a player in normal chat; anything else is ignored):
--   !stock <item>   live count + target for a managed item (label match)
--   !status         one-line manager summary (mode, queue, crafts/min)
--   !seat           which agent seats are live (from heartbeat files)
--   !help           the grammar, one line
--
-- Mirror pair: lib/atm10-chatbridge.lua == atm10-chatbridge.lua (byte-identical).

local chatbridge = {}

-- Conservative default: real cap is 256 for server chat; leave headroom for
-- the sender tag and step prefixes so no caller can recreate the
-- "Chat message was too long" failure class.
chatbridge.MAX_LEN = 200

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- (1) Player line -> intent, or nil for anything that is not a command.
-- opts.players: optional allowlist of player names (array). Unknown commands
-- from an allowed player return kind="help" so a typo still gets an answer.
function chatbridge.parse(player, message, opts)
  opts = opts or {}
  local text = trim(message)
  if text:sub(1, 1) ~= "!" then return nil end
  if opts.players then
    local allowed = false
    for _, p in ipairs(opts.players) do
      if p == player then allowed = true break end
    end
    if not allowed then return nil end
  end
  -- Optional named prefix (e.g. prefix "cheme" => "!cheme status"). With a
  -- prefix set, bare "!word" lines are ignored entirely - they belong to
  -- other mods/players, not us. Case-insensitive; "!cheme" alone = help.
  local body, prefix = text:sub(2), nil
  if opts.prefix and trim(opts.prefix) ~= "" then
    prefix = trim(opts.prefix):lower()
    local head, tail = body:match("^(%S+)%s*(.*)$")
    if not head or head:lower() ~= prefix then return nil end
    body = tail
    if trim(body) == "" then return { kind = "help", player = player, prefix = prefix } end
  end
  local cmd, rest = body:match("^(%a+)%s*(.*)$")
  if not cmd then return nil end
  cmd = cmd:lower()
  if cmd == "stock" then
    if trim(rest) == "" then return { kind = "help", player = player, prefix = prefix } end
    return { kind = "stock", query = trim(rest):lower(), player = player, prefix = prefix }
  elseif cmd == "status" then
    return { kind = "status", player = player, prefix = prefix }
  elseif cmd == "seat" then
    return { kind = "seat", player = player, prefix = prefix }
  else
    return { kind = "help", player = player, prefix = prefix }
  end
end

-- Case-insensitive label/name match over plan rows; label match wins over
-- registry-name match so "!stock gold" prefers "Gold Ingot" to gold_tiny_dust.
local function findRows(plans, query)
  local byLabel, byName = {}, {}
  for _, row in ipairs(plans or {}) do
    local label = tostring(row.label or ""):lower()
    local name = tostring(row.name or ""):lower()
    if label:find(query, 1, true) then
      byLabel[#byLabel + 1] = row
    elseif name:find(query, 1, true) then
      byName[#byName + 1] = row
    end
  end
  if #byLabel > 0 then return byLabel end
  return byName
end

local function fmtCount(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.0fk", n / 1000) end
  return tostring(n)
end

-- (2) Intent -> array of send-ready strings (each <= maxLen), from the same
-- snapshots the dashboard already renders. state = { plans, mode, queue =
-- {depth, crafting}, perMin, seats = { {name, live, ageSec}, ... } }.
function chatbridge.reply(intent, state, opts)
  opts = opts or {}
  local maxLen = tonumber(opts.maxLen) or chatbridge.MAX_LEN
  state = state or {}
  local lines = {}
  if intent == nil then return lines end
  if intent.kind == "help" then
    local p = intent.prefix and ("!" .. intent.prefix .. " ") or "!"
    lines[1] = string.format("commands: %sstock <item>, %sstatus, %sseat, %shelp", p, p, p, p)
  elseif intent.kind == "status" then
    local q = state.queue or {}
    lines[1] = string.format("mode %s | queue %d (%d crafting) | %d crafts/min | %s",
      tostring(state.mode or "?"), tonumber(q.depth) or 0, tonumber(q.crafting) or 0,
      tonumber(state.perMin) or 0, tostring(state.summary or "OK"))
  elseif intent.kind == "seat" then
    local parts = {}
    for _, seat in ipairs(state.seats or {}) do
      parts[#parts + 1] = string.format("%s %s", tostring(seat.name),
        seat.live and "LIVE" or "offline")
    end
    if #parts == 0 then
      lines[1] = "no agent seats known - manager itself is answering"
    else
      lines[1] = table.concat(parts, " | ") .. " - offline seats get messages queued"
    end
  elseif intent.kind == "stock" then
    local rows = findRows(state.plans, intent.query)
    if #rows == 0 then
      lines[1] = string.format("no managed item matches '%s'", intent.query)
    else
      local row = rows[1]
      lines[1] = string.format("%s: %s of %s target (%s)",
        tostring(row.label or row.name), fmtCount(row.amount),
        fmtCount(row.target), tostring(row.action or "?"))
      if #rows > 1 then
        lines[1] = lines[1] .. string.format(" +%d more match", #rows - 1)
      end
    end
  end
  local out = {}
  for _, line in ipairs(lines) do
    for _, piece in ipairs(chatbridge.split(line, maxLen)) do
      out[#out + 1] = piece
    end
  end
  return out
end

-- (3) Word-boundary split so no caller can emit an over-length chat line.
-- A single word longer than maxLen is hard-cut (never send-and-hope).
function chatbridge.split(text, maxLen)
  maxLen = tonumber(maxLen) or chatbridge.MAX_LEN
  text = trim(text)
  local pieces = {}
  while #text > maxLen do
    local cut = maxLen
    for i = maxLen, math.max(1, maxLen - 40), -1 do
      if text:sub(i, i) == " " then cut = i break end
    end
    local head = trim(text:sub(1, cut))
    if head == "" then head = text:sub(1, maxLen) cut = maxLen end
    pieces[#pieces + 1] = head
    text = trim(text:sub(cut + 1))
  end
  if #text > 0 then pieces[#pieces + 1] = text end
  return pieces
end

-- (4) Agent outbound spool -> send-ready strings, oldest first, rate-capped.
-- entries: array of { text, from }. Returns sends, remaining. Each send is
-- "[from] text", split to maxLen. maxPerTick caps sends per manager tick so
-- a chatty agent cannot flood the channel.
function chatbridge.outbound(entries, opts)
  opts = opts or {}
  local maxLen = tonumber(opts.maxLen) or chatbridge.MAX_LEN
  local maxPerTick = tonumber(opts.maxPerTick) or 3
  local sends, remaining = {}, {}
  for i, e in ipairs(entries or {}) do
    local queued = #sends >= maxPerTick
    if not queued and type(e) == "table" and trim(e.text) ~= "" then
      local tagged = string.format("[%s] %s", tostring(e.from or "agent"), trim(e.text))
      local pieces = chatbridge.split(tagged, maxLen)
      if #sends + #pieces <= maxPerTick then
        for _, p in ipairs(pieces) do sends[#sends + 1] = p end
      else
        queued = true
      end
    end
    if queued then remaining[#remaining + 1] = e end
  end
  return sends, remaining
end

-- (5) Heartbeat staleness -> presence transitions. seats: array of
-- { name, lastBeatMs }. prior: map name -> true if announced live last tick.
-- Returns announcements (send-ready strings) and the new live map. The
-- manager announces seat presence so a dead agent session can never keep an
-- implicit presence claim alive (the presence-contract failure mode).
function chatbridge.presence(seats, prior, now, opts)
  opts = opts or {}
  local staleMs = tonumber(opts.staleMs) or 180000
  local announcements, live = {}, {}
  for _, seat in ipairs(seats or {}) do
    local fresh = seat.lastBeatMs and (now - seat.lastBeatMs) < staleMs
    live[seat.name] = fresh or nil
    local was = prior and prior[seat.name] or nil
    if fresh and not was then
      announcements[#announcements + 1] = string.format(
        "%s seat is LIVE - reach it with !%s or plain chat", seat.name, "seat")
    elseif was and not fresh then
      announcements[#announcements + 1] = string.format(
        "%s seat went offline - messages now queue until it returns", seat.name)
    end
  end
  return announcements, live
end

return chatbridge
