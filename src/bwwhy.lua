--[[ @TITLE@: why the game did not load, on a screen of its own. The loader runs this file only
  when game.luac fails to load, so its code is not in memory while the game loads. EdgeTX's error
  box would cut the message: on a 128 px screen it shows only what follows the last "/" in it, and
  at most 64 characters. ]]
local err = ...
-- what to do, in lines of at most 21 characters (a 128 px screen)
local ver, _, maj, minor = getVersion()
local msg
if string.find(tostring(err), "memory", 1, true) then
  msg = { "Not enough memory", "on this radio."@OOMHINT@ }
elseif maj and minor and (maj < 2 or maj == 2 and minor < 11) then
  -- EdgeTX 2.10 and older (and OpenTX) have Lua 5.2, which can't read the 5.3 binary
  msg = { "Needs EdgeTX 2.11", "or newer. This radio", "has " .. tostring(ver) .. "." }
else
  msg = { "Copy the whole folder", "@DIR@ into", "SCRIPTS/TOOLS." }
end
return { run = function(event)
  lcd.clear()
  lcd.drawFilledRectangle(0, 0, LCD_W, 9)
  lcd.drawText(2, 1, "@TITLE@", INVERS)
  for i = 1, #msg do lcd.drawText(2, 3 + 10 * i, msg[i]) end
  if event == (EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK) then return 1 end
  return 0
end }
