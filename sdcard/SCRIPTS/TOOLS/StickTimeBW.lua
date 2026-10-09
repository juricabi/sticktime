local toolName = "TNS|StickTime BW|TNE"
--[[ ======================================================================
  StickTime BW v1.6.4  -  loader for black & white radios

  The game itself is in /SCRIPTS/TOOLS/StickTimeBW/ (copy that whole folder too):
  game.luac, the game precompiled for EdgeTX 2.11 and newer, and core.lua,
  its source. A B&W radio cannot compile the game: that takes more memory
  than any of them has, and running out of it can crash the radio. So this
  loader only loads game.luac. There is no game.lua next to it, so EdgeTX
  takes the binary whatever the file times are (with a source of the same
  name it compiles the source when its file looks newer). To change the
  game, edit core.lua and compile it to game.luac on a computer (build.py).

  When game.luac does not load, the loader says why on a screen of its own.
  EdgeTX's error box would cut the message: on a 128 px screen it shows only
  what follows the last "/" in it, and at most 64 characters.
====================================================================== ]]
-- made for black & white screens: on a color radio, color.lua says which game to start instead
if LCD_W > 212 then
  local m = loadScript("/SCRIPTS/TOOLS/StickTimeBW/color.lua")
  if m then return m() end
end
local f, err = loadScript("/SCRIPTS/TOOLS/StickTimeBW/game.lua", "b")
if f then return f() end
-- what to do, in lines of at most 21 characters (a 128 px screen)
local ver, _, maj, minor = getVersion()
local msg
if string.find(tostring(err), "memory", 1, true) then
  msg = { "Not enough memory", "on this radio.", "Use StickTime Lite." }
elseif maj and minor and (maj < 2 or maj == 2 and minor < 11) then
  -- EdgeTX 2.10 and older (and OpenTX) have Lua 5.2, which can't read the 5.3 binary
  msg = { "Needs EdgeTX 2.11", "or newer. This radio", "has " .. tostring(ver) .. "." }
else
  msg = { "Copy the whole folder", "StickTimeBW into", "SCRIPTS/TOOLS." }
end
return { run = function(event)
  lcd.clear()
  lcd.drawFilledRectangle(0, 0, LCD_W, 9)
  lcd.drawText(2, 1, "StickTime BW", INVERS)
  for i = 1, #msg do lcd.drawText(2, 3 + 10 * i, msg[i]) end
  if event == (EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK) then return 1 end
  return 0
end }
