local toolName = "TNS|@TOOLNAME@|TNE"
--[[ ======================================================================
  @TITLE@ v1.1  -  loader for black & white radios

  The game itself is in /SCRIPTS/TOOLS/FPVSimBW/core.lua (copy that
  folder too). B&W radios have little RAM, and a script compiled on the
  radio keeps its debug info in memory for that run. So this loader lets
  EdgeTX compile the game once (it saves FPVSimBW/core.luac), drops that
  copy and runs the saved bytecode, which needs about half the memory.
====================================================================== ]]
local CORE = "/SCRIPTS/TOOLS/FPVSimBW/core.lua"
local f, err = loadScript(CORE)
f = nil
collectgarbage()
f, err = loadScript(CORE, "b")
if not f then f, err = loadScript(CORE) end
if not f then error("FPV Sim: cannot load " .. CORE .. " " .. tostring(err)) end
return f()
