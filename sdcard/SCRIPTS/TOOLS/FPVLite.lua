local toolName = "TNS|FPV Sim Lite|TNE"
--[[ ======================================================================
  FPV Sim Lite v1.2  -  loader for black & white radios

  The game itself is in /SCRIPTS/TOOLS/FPVLite/ (copy that folder too):
  core.luac, precompiled for EdgeTX 2.11 and newer, and its source
  core.lua. B&W radios have little RAM: compiling the game on the radio
  needs far more memory than running it, and a script compiled on the
  radio keeps its debug info for that run. So this loader takes the
  precompiled core.luac when it can. Otherwise EdgeTX compiles core.lua
  (and saves core.luac); that copy is dropped and core.luac is loaded.
  If you edit core.lua, delete core.luac.
====================================================================== ]]
local CORE = "/SCRIPTS/TOOLS/FPVLite/core.lua"
local f = loadScript(CORE, "b") or loadScript(CORE)
f = nil
collectgarbage()
f = loadScript(CORE, "b") or loadScript(CORE)
if not f then error("FPV Sim Lite: cannot load " .. CORE) end
return f()
