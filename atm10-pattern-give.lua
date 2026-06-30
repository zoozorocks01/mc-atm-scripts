-- Ready-to-paste /give command builder for Refined Storage CRAFTING patterns.
-- Pure string assembly: no peripheral / fs / textutils, only string ops + a
-- deterministic id generator. Unit-tested off-CC (see tests/run.lua).
--
-- SCOPE: type="crafting" patterns ONLY (recipe-grid patterns, e.g. 9 ingot -> 1
-- block, or 1 block -> 9 ingot). Processing patterns (dust->ingot, alloys) use a
-- DIFFERENT component shape that must not be hand-authored from guesswork -- see
-- docs/RS_PATTERN_SPAWNING.md. This lib deliberately cannot emit those.
--
-- The emitted format is byte-identical to the commands already proven in-world
-- (the 11 metal-block patterns went live this way). Golden-string tests pin it.
local give = {}

-- Build ONE /give line for a crafting pattern.
-- opts = { items = {<id>, ... width*height entries, row-major}, width, height,
--          id = {a,b,c,d}, count = 1 (optional, the trailing stack count) }
-- Returns the command string, or (nil, err) if the recipe is invalid -- a
-- partial/invalid recipe must never be emitted (no "shouldn't happen" fallback).
function give.craftingGive(opts)
  if type(opts) ~= "table" then return nil, "opts must be a table" end
  local items = opts.items
  local w, h = opts.width, opts.height
  local id = opts.id
  if type(items) ~= "table" then return nil, "items must be a table" end
  if type(w) ~= "number" or type(h) ~= "number" or w < 1 or h < 1 then
    return nil, "width/height must be positive numbers"
  end
  if type(id) ~= "table" or #id ~= 4 then return nil, "id must be a 4-int table" end
  for i = 1, 4 do
    if type(id[i]) ~= "number" then return nil, "id[" .. i .. "] must be a number" end
  end
  local need = w * h
  if #items ~= need then
    return nil, "expected " .. need .. " items (" .. w .. "x" .. h .. "), got " .. #items
  end
  for i = 1, need do
    if type(items[i]) ~= "string" or items[i] == "" then
      return nil, "item[" .. i .. "] must be a non-empty string"
    end
  end

  local parts = {}
  for i = 1, need do
    parts[i] = '{id:"' .. items[i] .. '",count:1}'
  end
  local itemsStr = table.concat(parts, ",")
  local count = opts.count or 1

  return '/give @s refinedstorage:pattern['
    .. 'refinedstorage:pattern_state={type:"crafting",id:[I;'
    .. id[1] .. ',' .. id[2] .. ',' .. id[3] .. ',' .. id[4] .. ']},'
    .. 'refinedstorage:crafting_pattern_state={input:{input:{height:'
    .. h .. ',width:' .. w .. ',items:[' .. itemsStr .. ']},left:0,top:0},'
    .. 'fuzzyMode:0b}] ' .. count
end

-- 9x ingotId in a 3x3 grid -> RS derives the block output.
function give.compressIngotToBlock(ingotId, idQuad)
  if type(ingotId) ~= "string" or ingotId == "" then return nil, "ingotId required" end
  local items = {}
  for i = 1, 9 do items[i] = ingotId end
  return give.craftingGive({ items = items, width = 3, height = 3, id = idQuad })
end

-- 1x blockId in a 1x1 grid -> RS derives the 9-ingot output.
function give.uncompressBlockToIngots(blockId, idQuad)
  if type(blockId) ~= "string" or blockId == "" then return nil, "blockId required" end
  return give.craftingGive({ items = { blockId }, width = 1, height = 1, id = idQuad })
end

-- Deterministic distinct 4-int handle per pattern index n.
-- Default scheme reproduces the proven block file: {3000+n, 9000+3n, 15000+5n, 21000+7n}.
-- scheme="uncompress" gives the 80000-band scheme used by the uncompress file
-- when called with the same 0-based index that file uses (tin n=0 -> 80001..80004).
function give.idQuad(n, scheme)
  n = n or 0
  if scheme == "uncompress" then
    local base = 80000 + 10 * n
    return { base + 1, base + 2, base + 3, base + 4 }
  end
  return { 3000 + n, 9000 + 3 * n, 15000 + 5 * n, 21000 + 7 * n }
end

-- Pair a known ingot quota with its block (and vice versa) by a simple
-- _ingot<->_block suffix swap on the registry name. Returns nil if the suffix
-- is absent -- never guess.
function give.deriveBlockId(ingotId)
  if type(ingotId) ~= "string" then return nil end
  local stem = ingotId:match("^(.*)_ingot$")
  if not stem then return nil end
  return stem .. "_block"
end

function give.deriveIngotId(blockId)
  if type(blockId) ~= "string" then return nil end
  local stem = blockId:match("^(.*)_block$")
  if not stem then return nil end
  return stem .. "_ingot"
end

-- Operator-facing next-step hint for the patterns worklist. This does NOT emit
-- processing patterns; it only says which bucket the item belongs to and whether
-- the safe crafting-pattern /give derivation below can help.
function give.hintForItem(name)
  if type(name) ~= "string" or name == "" then
    return { kind = "manual", derivable = false, text = "check recipe manually; no registry id" }
  end
  local lower = name:lower()
  if lower:find("alloy", 1, true) or lower:find("circuit", 1, true) then
    return {
      kind = "processing",
      derivable = false,
      text = "processing: machine recipe needs a captured reference pattern",
    }
  end
  if name:match("_block$") then
    local ingot = give.deriveIngotId(name)
    return {
      kind = "crafting",
      derivable = ingot ~= nil,
      text = "crafting-grid: 9x " .. tostring(ingot or "<ingot>") .. " -> " .. name .. " (/give derivable)",
    }
  end
  if name:match("_ingot$") then
    local block = give.deriveBlockId(name)
    return {
      kind = "crafting",
      derivable = block ~= nil,
      text = "crafting-grid: 1x " .. tostring(block or "<block>") .. " -> 9x " .. name ..
        " (/give derivable; dust->ingot still needs a processing reference)",
    }
  end
  if lower:find("dust", 1, true) then
    return {
      kind = "processing",
      derivable = false,
      text = "processing: capture one real dust->output pattern first; do not /give guess",
    }
  end
  if lower:find("essence", 1, true) then
    return {
      kind = "crafting",
      derivable = false,
      text = "crafting-grid ladder: encode in Pattern Grid; no safe suffix derivation",
    }
  end
  return {
    kind = "manual",
    derivable = false,
    text = "check recipe in Pattern Grid; no safe /give derivation",
  }
end

function give.bucketForItem(name)
  local hint = give.hintForItem(name)
  if hint.derivable == true then return "crafting", hint end
  if hint.kind == "processing" then return "processing", hint end
  return "manual", hint
end

-- For a list of needed items { {name, label} ... }, emit a ready-to-paste /give for
-- each one we can DERIVE a crafting pattern for, NEVER guessing:
--   *_block -> a compress-from-ingots pattern (9 ingots -> block, 3x3)
--   *_ingot -> an uncompress-from-block pattern (1 block -> 9 ingots, 1x1)
-- Anything else (no _ingot/_block suffix) is skipped. Each emitted pattern gets a
-- distinct idQuad (running index; compress uses the default band, uncompress the
-- 80000 band, so the two never collide). Returns { {name, label, kind, command} }.
function give.emitForItems(items)
  local out, n = {}, 0
  for _, it in ipairs(items or {}) do
    local name = it and it.name
    if type(name) == "string" then
      local cmd, kind
      local hint = give.hintForItem(name)
      if hint.derivable == true and name:match("_block$") then
        local ingot = give.deriveIngotId(name)
        if ingot then n = n + 1; cmd = give.compressIngotToBlock(ingot, give.idQuad(n)); kind = "compress" end
      elseif hint.derivable == true and name:match("_ingot$") then
        local block = give.deriveBlockId(name)
        if block then n = n + 1; cmd = give.uncompressBlockToIngots(block, give.idQuad(n, "uncompress")); kind = "uncompress" end
      end
      if cmd then
        out[#out + 1] = { name = name, label = it.label or name, kind = kind, command = cmd }
      end
    end
  end
  return out
end

return give
