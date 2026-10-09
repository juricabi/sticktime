local toolName = "TNS|StickTime Lite|TNE"
--[[ ======================================================================
  StickTime Lite v1.6.4  -  loader for black & white radios

  The game itself is in /SCRIPTS/TOOLS/StickTimeLite/ (copy that whole folder too):
  game.luac, the game precompiled for EdgeTX 2.11 and newer, and core.lua,
  its source. A B&W radio cannot compile the game: that takes more memory
  than any of them has, and running out of it can crash the radio. So this
  loader only loads game.luac. There is no game.lua next to it, so EdgeTX
  takes the binary whatever the file times are (with a source of the same
  name it compiles the source when its file looks newer). To change the
  game, edit core.lua and compile it to game.luac on a computer (build.py).
====================================================================== ]]
-- made for black & white screens: on a color radio, color.lua says which game to start instead
if LCD_W > 212 then
  local m = loadScript("/SCRIPTS/TOOLS/StickTimeLite/color.lua")
  if m then return m() end
end
local f, err = loadScript("/SCRIPTS/TOOLS/StickTimeLite/game.lua", "b")
if not f then
  err = tostring(err)
  if string.find(err, "memory", 1, true) then error("StickTime Lite: not enough memory") end
  error("StickTime Lite needs EdgeTX 2.11+ and the StickTimeLite folder (" .. err .. ")")
end
return f()
