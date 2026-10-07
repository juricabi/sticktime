-- the B&W loader: compiles the core once, then runs the saved bytecode (mock loadScript)
local calls = {}
LCD_W, LCD_H = 128, 64
function loadScript(path, mode)
  calls[#calls + 1] = mode or "bt"
  local luac = path:gsub("%.lua$", ".luac")
  if mode == "b" then
    local f = io.open("../sdcard/SCRIPTS/TOOLS/" .. luac:match("TOOLS/(.*)$"), "rb")
    if not f then return nil, "no luac" end
    local s = f:read("a") f:close()
    return load(s, "=core", "b")
  end
  return loadfile("../sdcard/SCRIPTS/TOOLS/" .. path:match("TOOLS/(.*)$"))
end
lcd = setmetatable({}, { __index = function() return function() return 0 end end })
SOLID, DOTTED, FORCE, ERASE = 0xff, 0x55, 2, 4
local m = dofile("../sdcard/SCRIPTS/TOOLS/FPVSimBW.lua")
assert(type(m) == "table" and type(m.init) == "function" and type(m.run) == "function", "loader must return the core's {init, run}")
assert(calls[1] == "bt" and calls[2] == "b", "loader should compile, then load the bytecode: " .. table.concat(calls, ","))
print("loader: ok (" .. table.concat(calls, " -> ") .. ")")
