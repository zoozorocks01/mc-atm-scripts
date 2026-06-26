local status = {}

status.OK = "OK"
status.LOW = "LOW"
status.WOULD = "WOULD"
status.CRAFTING = "CRAFTING"
status.COOLDOWN = "COOLDOWN"
status.NO_RECIPE = "NO_RECIPE"
status.BLOCKED = "BLOCKED"
status.CRITICAL = "CRITICAL"
status.DRAINING = "DRAINING"
status.STALE = "STALE"
status.DISABLED = "DISABLED"
status.RESERVED = "RESERVED"
status.UNKNOWN = "UNKNOWN"

local byAction = {
  ["OK"] = status.OK,
  ["LOW"] = status.LOW,
  ["WOULD"] = status.WOULD,
  ["WOULD CRAFT"] = status.WOULD,
  ["CRAFTING"] = status.CRAFTING,
  ["ALREADY CRAFTING"] = status.CRAFTING,
  ["ON COOLDOWN"] = status.COOLDOWN,
  ["COOLDOWN"] = status.COOLDOWN,
  ["NOT CRAFTABLE"] = status.NO_RECIPE,
  ["NO RECIPE"] = status.NO_RECIPE,
  ["NO_RECIPE"] = status.NO_RECIPE,
  ["BLOCKED"] = status.BLOCKED,
  ["CYCLE CAP"] = status.BLOCKED,
  ["CRITICAL"] = status.CRITICAL,
  ["DRAINING"] = status.DRAINING,
  ["STALE"] = status.STALE,
  ["STALE DATA"] = status.STALE,
  ["DISABLED"] = status.DISABLED,
  ["RESERVED"] = status.RESERVED,
  ["UNKNOWN"] = status.UNKNOWN,
}

local glyphs = {
  OK = "+",
  LOW = "!",
  WOULD = ">",
  CRAFTING = "~",
  COOLDOWN = ".",
  NO_RECIPE = "x",
  BLOCKED = "#",
  CRITICAL = "x",
  DRAINING = "v",
  STALE = "?",
  DISABLED = "-",
  RESERVED = "=",
  UNKNOWN = "?",
}

local labels = {
  OK = "OK",
  LOW = "LOW",
  WOULD = "WOULD",
  CRAFTING = "CRAFTING",
  COOLDOWN = "COOLDOWN",
  NO_RECIPE = "NO RECIPE",
  BLOCKED = "BLOCKED",
  CRITICAL = "CRITICAL",
  DRAINING = "DRAINING",
  STALE = "STALE",
  DISABLED = "DISABLED",
  RESERVED = "RESERVED",
  UNKNOWN = "UNKNOWN",
}

local colorsByStatus = {
  OK = colors.green,
  LOW = colors.yellow,
  WOULD = colors.cyan,
  CRAFTING = colors.purple,
  COOLDOWN = colors.lightBlue,
  NO_RECIPE = colors.red,
  BLOCKED = colors.orange,
  CRITICAL = colors.red,
  DRAINING = colors.yellow,
  STALE = colors.orange,
  DISABLED = colors.gray,
  RESERVED = colors.lightBlue,
  UNKNOWN = colors.lightGray,
}

local severity = {
  UNKNOWN = 0,
  OK = 1,
  DISABLED = 1,
  RESERVED = 2,
  COOLDOWN = 2,
  CRAFTING = 2,
  WOULD = 3,
  DRAINING = 3,
  LOW = 4,
  BLOCKED = 5,
  STALE = 5,
  NO_RECIPE = 6,
  CRITICAL = 8,
}

function status.normalize(value)
  if type(value) ~= "string" then return status.UNKNOWN end
  return byAction[value] or byAction[string.upper(value)] or status.UNKNOWN
end

function status.glyph(value)
  return glyphs[status.normalize(value)] or glyphs.UNKNOWN
end

function status.label(value)
  return labels[status.normalize(value)] or labels.UNKNOWN
end

function status.color(value)
  return colorsByStatus[status.normalize(value)] or colors.white
end

function status.tag(value)
  local normalized = status.normalize(value)
  return status.glyph(normalized) .. " " .. status.label(normalized)
end

function status.severity(value)
  return severity[status.normalize(value)] or 0
end

function status.worst(values)
  local worstValue = status.OK
  local worstScore = 0

  for _, value in ipairs(values or {}) do
    local score = status.severity(value)
    if score > worstScore then
      worstValue = status.normalize(value)
      worstScore = score
    end
  end

  return worstValue
end

function status.tally(rows)
  local counts = {
    OK = 0,
    WOULD = 0,
    CRAFTING = 0,
    COOLDOWN = 0,
    NO_RECIPE = 0,
    BLOCKED = 0,
    LOW = 0,
    CRITICAL = 0,
    DRAINING = 0,
    STALE = 0,
    DISABLED = 0,
    RESERVED = 0,
    UNKNOWN = 0,
  }

  for _, row in ipairs(rows or {}) do
    local value = row.status or row.action or row
    local normalized = status.normalize(value)
    counts[normalized] = (counts[normalized] or 0) + 1
  end

  return counts
end

return status
