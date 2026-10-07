-- @TITLE@ started on a color radio: the B&W loader runs this instead of the game, which is
-- drawn for black & white screens (its menus would be tiny there, the pause menu a black box).
local LINES = { "@TITLE@ is made for", MIDSIZE, "black & white screens.", MIDSIZE, "", SMLSIZE,
  "On a color radio, start StickTime", 0, "(StickTime.lua in /SCRIPTS/TOOLS).", SMLSIZE, "", SMLSIZE,
  "EXIT to close", SMLSIZE }
local function height(f)
  local _, h
  if lcd.sizeText then _, h = lcd.sizeText("Ag", f) end
  if type(h) == "number" and h > 0 then return h end
  return f == MIDSIZE and 30 or f == SMLSIZE and 16 or 22
end
return { run = function(event)
  local total = 0
  for i = 2, #LINES, 2 do total = total + height(LINES[i]) end
  local y = (LCD_H - total) / 2
  lcd.clear()
  for i = 1, #LINES, 2 do
    lcd.drawText(LCD_W / 2, y, LINES[i], CENTER + LINES[i + 1])
    y = y + height(LINES[i + 1])
  end
  return (event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_ENTER) and 1 or 0
end }
