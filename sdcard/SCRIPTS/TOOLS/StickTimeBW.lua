local toolName = "TNS|StickTime BW|TNE"
--[[ ======================================================================
  StickTime BW v1.6.3  -  loader for black & white radios

  The game itself is in /SCRIPTS/TOOLS/StickTimeBW/ (copy that folder too):
  core.luac, precompiled for EdgeTX 2.11 and newer, and its source
  core.lua. B&W radios have little RAM: compiling the game on the radio
  needs far more memory than running it, and a script compiled on the
  radio keeps its debug info for that run. So this loader takes the
  precompiled core.luac. Only without it EdgeTX compiles core.lua (and
  saves core.luac); that copy is dropped and core.luac is loaded.
  If you edit core.lua, delete core.luac.
====================================================================== ]]
-- made for black & white screens: on a color radio, color.lua says which game to start instead
if LCD_W > 212 then
  local m = loadScript("/SCRIPTS/TOOLS/StickTimeBW/color.lua")
  if m then return m() end
end
local CORE = "/SCRIPTS/TOOLS/StickTimeBW/core.lua"
local f = loadScript(CORE, "b")
if not f then
  f = loadScript(CORE)
  f = nil
  collectgarbage()
  f = loadScript(CORE, "b") or loadScript(CORE)
end
if not f then error("StickTime BW: cannot load " .. CORE) end
return f()
