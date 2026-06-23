-- Off-CC test support: stubs the CC:Tweaked globals the atm10-* libs touch,
-- provides an in-memory fs, and a tiny assert helper. Dev-only; never shipped
-- to a computer (not listed in the updater).

-- Real CC:Tweaked color bit values, so palette/blit slot maps stay faithful.
_G.colors = {
  white = 0x1, orange = 0x2, magenta = 0x4, lightBlue = 0x8,
  yellow = 0x10, lime = 0x20, pink = 0x40, gray = 0x80,
  lightGray = 0x100, cyan = 0x200, purple = 0x400, blue = 0x800,
  brown = 0x1000, green = 0x2000, red = 0x4000, black = 0x8000,
}

-- In-memory fs stub (only the slice atm10-palette uses). `files` is a stable
-- upvalue so clearFiles/setFile mutate it in place and the closures still see it.
local files = {}
_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode ~= "r" then return nil end
    local content = files[path]
    if content == nil then return nil end
    return {
      readAll = function() return content end,
      close = function() end,
    }
  end,
}

local M = { pass = 0, fail = 0 }

function M.setFile(name, content) files[name] = content end
function M.clearFiles() for k in pairs(files) do files[k] = nil end end

function M.check(cond, msg)
  if cond then
    M.pass = M.pass + 1
  else
    M.fail = M.fail + 1
    print("  FAIL: " .. tostring(msg))
  end
end

function M.eq(got, want, msg)
  M.check(got == want, (msg or "eq") .. "  (got=" .. tostring(got) .. ", want=" .. tostring(want) .. ")")
end

function M.summary()
  print(string.format("\n%d passed, %d failed", M.pass, M.fail))
  return M.fail == 0
end

return M
