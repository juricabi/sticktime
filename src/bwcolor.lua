-- @TITLE@ on a color radio: the B&W game at the screen's own resolution, for the highest
-- frame rate. The B&W loader runs this file instead of the game when the screen is a color
-- one. The game draws with the B&W radios' flags (FORCE, ERASE, INVERS, the B&W font sizes):
-- here they get values of their own, and lcd becomes a set of functions that draw them in
-- B&W colors. STICKTIME_UI scales the menus and HUD to the color fonts; the 3D view uses
-- every pixel.
local CORE = "/SCRIPTS/TOOLS/@DIR@/core.lua"
local floor, fmt, tostring = math.floor, string.format, tostring
local LCD = lcd
local clear, line, fill, frame, text, size =
  LCD.clear, LCD.drawLine, LCD.drawFilledRectangle, LCD.drawRectangle, LCD.drawText, LCD.sizeText
local BG, INK = LCD.RGB(214, 222, 208), LCD.RGB(24, 30, 26)   -- a B&W LCD's colors
-- the color radio's own flags (the game's take over these globals below)
local C_SML, C_MID, C_DBL, C_TIN, C_XXL, C_RIGHT, C_CENTER = SMLSIZE, MIDSIZE, DBLSIZE, TINSIZE, XXLSIZE, RIGHT, CENTER

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
  local d = { has(f, B.SMLSIZE) and C_SML or has(f, B.MIDSIZE) and C_MID or has(f, B.DBLSIZE) and C_DBL
                or has(f, B.TINSIZE) and C_TIN or has(f, B.XXLSIZE) and C_XXL or 0,
              has(f, B.RIGHT) and C_RIGHT or has(f, B.CENTER) and C_CENTER or 0,
              has(f, B.INVERS), has(f, B.PREC1) and 1 or has(f, B.PREC2) and 2 or 0 }
  TF[f] = d
  return d
end

local function str(x, y, s, f)
  local d = TF[f] or tf(f)
  if d[3] then
    -- INVERS: light text in a dark box, as on a B&W screen
    local w, h = size(s, d[1])
    local x0 = (d[2] == C_RIGHT and x - w or d[2] == C_CENTER and x - w / 2 or x) - 2
    if x0 < 0 then w, x0 = w + x0, 0 end
    fill(x0, y, w + 4, h - 2, INK)
    text(x, y, s, d[1] + d[2] + BG)
  else
    text(x, y, s, d[1] + d[2] + INK)
  end
end

local L = setmetatable({
  clear = function() clear(BG) end,
  drawLine = function(x1, y1, x2, y2, p, f) line(x1, y1, x2, y2, p, LC[f or 0] or lc(f)) end,
  drawFilledRectangle = function(x, y, w, h, f) fill(x, y, w, h, LC[f or 0] or lc(f)) end,
  drawRectangle = function(x, y, w, h, f) frame(x, y, w, h, LC[f or 0] or lc(f)) end,
  drawText = function(x, y, s, f) str(x, y, s, f or 0) end,
  drawNumber = function(x, y, v, f)
    f = f or 0
    local p = (TF[f] or tf(f))[4]
    str(x, y, p == 1 and fmt("%.1f", v / 10) or p == 2 and fmt("%.2f", v / 100) or tostring(v), f)
  end,
}, { __index = LCD })

-- menus and HUD: B&W layouts are made for 8 px rows of 7 px small text
local _, h = size("A", C_SML)
local U = (h or 14) / 7
if U < 1 then U = 1 end

-- The game reads lcd and the flags as globals, so they are replaced here. (loadScript's env
-- argument would give the game a set of its own, but EdgeTX's loadScript drops it: the game
-- would see no globals at all.) A tool runs in a Lua state of its own on color radios, so
-- nothing else sees the change, and it ends with the tool.
lcd = L
STICKTIME_UI, GREY = U, false
LEFT, RIGHT, CENTER, INVERS, BLINK, BOLD, FORCE, ERASE = B.LEFT, B.RIGHT, B.CENTER, B.INVERS, B.BLINK, B.BOLD, B.FORCE, B.ERASE
PREC1, PREC2, SMLSIZE, MIDSIZE, DBLSIZE, TINSIZE, XXLSIZE = B.PREC1, B.PREC2, B.SMLSIZE, B.MIDSIZE, B.DBLSIZE, B.TINSIZE, B.XXLSIZE
local f = loadScript(CORE, "b") or loadScript(CORE, "bt")
if not f then error("@TITLE@: cannot load " .. CORE) end
return f()
