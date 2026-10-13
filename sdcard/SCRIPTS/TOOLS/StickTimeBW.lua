local toolName = "TNS|StickTime BW|TNE"
--[[ ======================================================================
  StickTime BW v1.7.0  -  loader for black & white radios

  The game itself is in /SCRIPTS/TOOLS/StickTimeBW/ (copy that whole folder too):
  game.luac, the game precompiled for EdgeTX 2.11 and newer, and core.lua,
  its source. A B&W radio cannot compile the game: that takes more memory
  than any of them has, and running out of it can crash the radio. So this
  loader only loads game.luac. There is no game.lua next to it, so EdgeTX
  takes the binary whatever the file times are (with a source of the same
  name it compiles the source when its file looks newer). To change the
  game, edit core.lua and compile it to game.luac on a computer (build.py).

  When game.luac does not load, why.lua in the same folder says why on a
  screen of its own. It is a file of its own because everything in this
  one stays in memory while the game loads, and these radios need every
  byte of it then.
====================================================================== ]]
-- made for black & white screens: on a color radio, color.lua says which game to start instead
if LCD_W > 212 then
  local m = loadScript("/SCRIPTS/TOOLS/StickTimeBW/color.lua")
  if m then return m() end
end
collectgarbage()                -- what compiling this loader left behind: the game needs the room in one piece
local f, err = loadScript("/SCRIPTS/TOOLS/StickTimeBW/game.lua", "b")
if f then return f() end
-- it did not load: why.lua says why (and if the folder is missing, so is why.lua)
f = loadScript("/SCRIPTS/TOOLS/StickTimeBW/why.lua")
if f then return f(err) end
return { run = function(event)
  lcd.clear()
  lcd.drawText(2, 13, "Copy the whole folder")
  lcd.drawText(2, 23, "StickTimeBW into")
  lcd.drawText(2, 33, "SCRIPTS/TOOLS.")
  if event == (EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK) then return 1 end
  return 0
end }
