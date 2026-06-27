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

return give
