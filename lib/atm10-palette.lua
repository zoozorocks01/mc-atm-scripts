local palette = {}

palette.themes = {
  controlRoom = {
    black = 0x070B11,
    cyan = 0x39BAE6,
    blue = 0x3A7BD5,
    white = 0xE8EDF4,
    lightGray = 0xAEB6C2,
    gray = 0x1D2A3A,
    green = 0x6BD968,
    yellow = 0xE6B450,
    orange = 0xFF8C42,
    red = 0xF07178,
    purple = 0xD2A6FF,
    lightBlue = 0x5B81A8,
  },
  amber = {
    black = 0x0D0A03,
    cyan = 0xFFB000,
    blue = 0xC98200,
    white = 0xFFC04D,
    lightGray = 0xB87912,
    gray = 0x3A2500,
    green = 0xB8D94A,
    yellow = 0xFFCC4D,
    orange = 0xFF8C42,
    red = 0xFF5630,
    purple = 0xD69B45,
    lightBlue = 0x8A5A00,
  },
  green = {
    black = 0x031206,
    cyan = 0x37D76B,
    blue = 0x20994A,
    white = 0x7DFFA6,
    lightGray = 0x55B873,
    gray = 0x12351E,
    green = 0x7DFFA6,
    yellow = 0xFFCC00,
    orange = 0xFF944D,
    red = 0xFF5544,
    purple = 0x71D68F,
    lightBlue = 0x15622C,
  },
}

local colorSlots = {
  black = colors.black,
  cyan = colors.cyan,
  blue = colors.blue,
  white = colors.white,
  lightGray = colors.lightGray,
  gray = colors.gray,
  green = colors.green,
  yellow = colors.yellow,
  orange = colors.orange,
  red = colors.red,
  purple = colors.purple,
  lightBlue = colors.lightBlue,
}

local function channels(rgb)
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  return r / 255, g / 255, b / 255
end

function palette.apply(target, themeName)
  local theme = palette.themes[themeName or "controlRoom"] or palette.themes.controlRoom
  local applied = 0

  if not target or not target.setPaletteColour then
    return false, "palette unavailable"
  end

  for name, rgb in pairs(theme) do
    local slot = colorSlots[name]
    if slot then
      local r, g, b = channels(rgb)
      local ok = pcall(target.setPaletteColour, slot, r, g, b)
      if not ok then
        ok = pcall(target.setPaletteColour, slot, rgb)
      end
      if ok then applied = applied + 1 end
    end
  end

  return applied > 0, applied
end

return palette
