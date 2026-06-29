local draw = {}

local blitByColor = {
  [colors.white] = "0",
  [colors.orange] = "1",
  [colors.magenta] = "2",
  [colors.lightBlue] = "3",
  [colors.yellow] = "4",
  [colors.lime] = "5",
  [colors.pink] = "6",
  [colors.gray] = "7",
  [colors.lightGray] = "8",
  [colors.cyan] = "9",
  [colors.purple] = "a",
  [colors.blue] = "b",
  [colors.brown] = "c",
  [colors.green] = "d",
  [colors.red] = "e",
  [colors.black] = "f",
}

local function clamp(n, min, max)
  n = tonumber(n) or 0
  if n < min then return min end
  if n > max then return max end
  return n
end

local function colorCode(color)
  return blitByColor[color or colors.white] or blitByColor[colors.white]
end

function draw.fit(text, width)
  text = tostring(text or "")
  width = math.max(0, tonumber(width) or 0)
  if #text <= width then return text .. string.rep(" ", width - #text) end
  if width <= 1 then return string.sub(text, 1, width) end
  return string.sub(text, 1, width - 1) .. "~"
end

function draw.write(target, x, y, text, fg, bg)
  if not target then return end
  if target.rows and target.width and target.height then
    draw.bufferWrite(target, x, y, text, fg, bg)
    return
  end
  local _, h = target.getSize()
  if y < 1 or y > h then return end
  target.setCursorPos(x, y)
  target.setTextColor(fg or colors.white)
  target.setBackgroundColor(bg or colors.black)
  target.write(tostring(text or ""))
end

function draw.line(target, y, text, fg, bg)
  if not target then return end
  local w, h = target.getSize()
  if y < 1 or y > h then return end
  target.setCursorPos(1, y)
  target.setTextColor(fg or colors.white)
  target.setBackgroundColor(bg or colors.black)
  target.clearLine()
  target.write(draw.fit(text, w))
end

function draw.bracket(pct, width)
  width = math.max(3, tonumber(width) or 12)
  pct = clamp(pct, 0, 100)
  local inner = width - 2
  local filled = math.floor((pct / 100) * inner)
  return "[" .. string.rep("#", filled) .. string.rep("-", inner - filled) .. "]"
end

function draw.barText(pct, width)
  width = math.max(1, tonumber(width) or 10)
  pct = clamp(pct, 0, 100)
  local filled = math.floor((pct / 100) * width)
  return string.rep("#", filled) .. string.rep("-", width - filled)
end

function draw.percentColor(pct)
  pct = tonumber(pct) or 0
  if pct < 15 then return colors.red end
  if pct < 35 then return colors.orange end
  if pct < 65 then return colors.yellow end
  return colors.green
end

function draw.gauge(target, x, y, width, pct, color)
  local text = draw.bracket(pct, width)
  draw.write(target, x, y, text, color or draw.percentColor(pct), colors.black)
end

function draw.box(target, x, y, w, h, title, fg, bg)
  if not target or w < 4 or h < 3 then return end
  fg = fg or colors.cyan
  bg = bg or colors.black

  local top = "+" .. string.rep("-", w - 2) .. "+"
  local bottom = top
  local side = "|" .. string.rep(" ", w - 2) .. "|"

  draw.write(target, x, y, top, fg, bg)
  for row = 1, h - 2 do
    draw.write(target, x, y + row, side, fg, bg)
  end
  draw.write(target, x, y + h - 1, bottom, fg, bg)

  if title and title ~= "" then
    draw.write(target, x + 2, y, " " .. draw.fit(string.upper(title), math.max(0, w - 6)) .. " ", fg, bg)
  end
end

function draw.newBuffer(width, height, fg, bg)
  local buffer = {
    width = width,
    height = height,
    fg = fg or colors.white,
    bg = bg or colors.black,
    rows = {},
  }

  local blank = string.rep(" ", width)
  for y = 1, height do
    buffer.rows[y] = {
      text = blank,
      fg = string.rep(colorCode(buffer.fg), width),
      bg = string.rep(colorCode(buffer.bg), width),
    }
  end

  return buffer
end

function draw.bufferWrite(buffer, x, y, text, fg, bg)
  if not buffer or y < 1 or y > buffer.height then return end
  text = tostring(text or "")
  fg = colorCode(fg or buffer.fg)
  bg = colorCode(bg or buffer.bg)

  if x < 1 then
    text = string.sub(text, 2 - x)
    x = 1
  end

  if x > buffer.width or #text == 0 then return end
  local maxLen = buffer.width - x + 1
  if #text > maxLen then text = string.sub(text, 1, maxLen) end

  local row = buffer.rows[y]
  local before = string.sub(row.text, 1, x - 1)
  local after = string.sub(row.text, x + #text)
  row.text = before .. text .. after

  local beforeFg = string.sub(row.fg, 1, x - 1)
  local afterFg = string.sub(row.fg, x + #text)
  row.fg = beforeFg .. string.rep(fg, #text) .. afterFg

  local beforeBg = string.sub(row.bg, 1, x - 1)
  local afterBg = string.sub(row.bg, x + #text)
  row.bg = beforeBg .. string.rep(bg, #text) .. afterBg
end

function draw.renderBuffer(target, buffer, previous)
  if not target or not buffer then return buffer end

  for y = 1, buffer.height do
    local row = buffer.rows[y]
    local old = previous and previous.rows and previous.rows[y]
    if not old or old.text ~= row.text or old.fg ~= row.fg or old.bg ~= row.bg then
      target.setCursorPos(1, y)
      if target.blit then
        target.blit(row.text, row.fg, row.bg)
      else
        target.setTextColor(buffer.fg)
        target.setBackgroundColor(buffer.bg)
        target.write(row.text)
      end
    end
  end

  return buffer
end

return draw
