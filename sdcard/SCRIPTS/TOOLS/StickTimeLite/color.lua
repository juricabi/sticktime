-- StickTime Lite on a color radio: the B&W game at the screen's own resolution, for the highest
-- frame rate. The B&W loader runs this file instead of the game when the screen is a color
-- one. The game draws with the B&W radios' flags (FORCE, ERASE, INVERS, the B&W font sizes):
-- it gets its own values for them here, and lcd functions that draw them in B&W colors.
-- STICKTIME_UI scales its menus and HUD to the color fonts; the 3D view uses every pixel.
local CORE = "/SCRIPTS/TOOLS/StickTimeLite/core.lua"
local floor, fmt = math.floor, string.format
local line, fill, frame, text, size = lcd.drawLine, lcd.drawFilledRectangle, lcd.drawRectangle, lcd.drawText, lcd.sizeText
local BG, INK = lcd.RGB(214, 222, 208), lcd.RGB(24, 30, 26)   -- a B&W LCD's colors

-- the game's B&W flags: any distinct bits, only this file reads them
local B = { LEFT = 0, RIGHT = 1, CENTER = 2, INVERS = 4, BLINK = 8, BOLD = 16, FORCE = 32, ERASE = 64,
            PREC1 = 128, PREC2 = 256, SMLSIZE = 512, MIDSIZE = 1024, DBLSIZE = 2048, TINSIZE = 4096, XXLSIZE = 8192 }
local function has(f, b) return floor(f / b) % 2 == 1 end

-- per flag value, worked out once: the color for lines and boxes (ERASE: the background),
-- and for text the color font, alignment, INVERS and decimals
local LC, TF = {}, {}
local function lc(f)
  local c = (f and has(f, B.ERASE)) and BG or INK
  if f then LC[f] = c end
  return c
end
local function tf(f)
  local d = { has(f, B.SMLSIZE) and SMLSIZE or has(f, B.MIDSIZE) and MIDSIZE or has(f, B.DBLSIZE) and DBLSIZE
                or has(f, B.TINSIZE) and TINSIZE or has(f, B.XXLSIZE) and XXLSIZE or 0,
              has(f, B.RIGHT) and RIGHT or has(f, B.CENTER) and CENTER or 0,
              has(f, B.INVERS), has(f, B.PREC1) and 1 or has(f, B.PREC2) and 2 or 0 }
  TF[f] = d
  return d
end

local function str(x, y, s, f)
  local d = TF[f] or tf(f)
  if d[3] then
    -- INVERS: light text in a dark box, as on a B&W screen
    local w, h = size(s, d[1])
    local x0 = (d[2] == RIGHT and x - w or d[2] == CENTER and x - w / 2 or x) - 2
    if x0 < 0 then w, x0 = w + x0, 0 end
    fill(x0, y, w + 4, h - 2, INK)
    text(x, y, s, d[1] + d[2] + BG)
  else
    text(x, y, s, d[1] + d[2] + INK)
  end
end

local L = setmetatable({
  clear = function() lcd.clear(BG) end,
  drawLine = function(x1, y1, x2, y2, p, f) line(x1, y1, x2, y2, p, LC[f or 0] or lc(f)) end,
  drawFilledRectangle = function(x, y, w, h, f) fill(x, y, w, h, LC[f or 0] or lc(f)) end,
  drawRectangle = function(x, y, w, h, f) frame(x, y, w, h, LC[f or 0] or lc(f)) end,
  drawText = function(x, y, s, f) str(x, y, s, f or 0) end,
  drawNumber = function(x, y, v, f)
    f = f or 0
    local p = (TF[f] or tf(f))[4]
    str(x, y, p == 1 and fmt("%.1f", v / 10) or p == 2 and fmt("%.2f", v / 100) or tostring(v), f)
  end,
}, { __index = lcd })

-- menus and HUD: B&W layouts are made for 8 px rows of 7 px small text
local _, h = size("A", SMLSIZE)
local U = (h or 14) / 7
if U < 1 then U = 1 end

local env = setmetatable({ lcd = L, STICKTIME_UI = U, GREY = false }, { __index = _G })
for k, v in pairs(B) do env[k] = v end
local f = loadScript(CORE, "b", env) or loadScript(CORE, "bt", env)
if not f then error("StickTime Lite: cannot load " .. CORE) end
return f()
