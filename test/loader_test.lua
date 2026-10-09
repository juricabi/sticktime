-- The B&W loaders (StickTimeBW.lua, StickTimeLite.lua) with a mock loadScript, run by the 32-bit
-- EdgeTX-config Lua: they must load the precompiled game.luac once, in "b" mode, and never ask
-- EdgeTX for the source: compiling it takes more memory than a B&W radio has. Without the
-- binary they stop with an error that names the folder.
local ROOT = "../sdcard/SCRIPTS/TOOLS/"
LCD_W, LCD_H = 128, 64
lcd = setmetatable({}, { __index = function() return function() return 0 end end })
SOLID, DOTTED, FORCE, ERASE = 0xff, 0x55, 2, 4
local ok = true

local function check(loader, haveLuac, oom)
  local calls = {}
  function loadScript(path, mode)
    mode = mode or "bt"
    local rel = path:match("TOOLS/(.*)%.lua$")
    calls[#calls + 1] = rel:match("[^/]*$") .. ":" .. mode
    if oom then return nil, "not enough memory" end
    local f = haveLuac and io.open(ROOT .. rel .. ".luac", "rb")
    if f then
      local s = f:read("a")
      f:close()
      return load(s, "=game", "b")
    end
    if string.find(mode, "t") then return loadfile(ROOT .. rel .. ".lua") end
    return nil, "loadScript(\"" .. path .. "\", \"" .. mode .. "\") error: File not found"
  end
  local good, m = pcall(dofile, ROOT .. loader)
  local seq = table.concat(calls, " ")
  local want = "game:b"
  if oom then
    -- the full B&W game on a radio with too little memory points to the Lite
    local hint = loader == "StickTimeBW.lua" and "StickTime Lite" or "not enough memory"
    good = not good and string.find(tostring(m), hint, 1, true) ~= nil and seq == want
  elseif haveLuac then
    good = good and type(m) == "table" and type(m.init) == "function" and type(m.run) == "function" and seq == want
  else
    local dir = loader:gsub("%.lua$", "")
    good = not good and string.find(tostring(m), dir, 1, true) ~= nil and seq == want
  end
  print(string.format("%-18s %-21s loadScript calls: %-8s %s", loader,
    oom and "out of memory" or haveLuac and "with game.luac" or "without game.luac",
    seq, good and ((haveLuac and not oom) and "ok" or "ok, stops: " .. tostring(m):match("^[^:]*:%d+: (.*)$")) or ("FAIL (want " .. want .. ")")))
  ok = ok and good
end

for _, loader in ipairs({ "StickTimeBW.lua", "StickTimeLite.lua" }) do
  check(loader, true)
  check(loader, false)
  check(loader, true, true)
end

-- started on a color radio: the loader runs <DIR>/color.lua, which replaces lcd and the flags
-- with B&W-style ones and loads the same game (the bytecode), or compiles core.lua when there is
-- no game.luac (a color radio has the memory). loadScript as EdgeTX's: a third argument (env)
-- leaves the chunk with no globals at all, so color.lua must not pass one.
for _, loader in ipairs({ "StickTimeBW.lua", "StickTimeLite.lua" }) do
  for _, haveLuac in ipairs({ true, false }) do
    LCD_W, LCD_H = 480, 272
    local seen = {}
    function loadScript(path, mode, ...)
      local rel = path:match("TOOLS/(.*)%.lua$")
      local withEnv = select("#", ...) > 0
      seen[#seen + 1] = rel:match("[^/]*$") .. (withEnv and "+env" or "")
      if rel:match("/color$") or rel:match("/core$") then
        if withEnv then return loadfile(ROOT .. rel .. ".lua", "t", nil) end
        return loadfile(ROOT .. rel .. ".lua")
      end
      local f = haveLuac and io.open(ROOT .. rel .. ".luac", "rb")
      if not f then return nil, "File not found" end
      local s = f:read("a")
      f:close()
      if withEnv then return load(s, "=game", "b", nil) end
      return load(s, "=game", "b")
    end
    local mock = setmetatable({ sizeText = function(t) return #t * 9, 17 end, RGB = function() return 0 end },
                              { __index = function() return function() return 0 end end })
    lcd = mock
    local m = dofile(ROOT .. loader)
    local seq = table.concat(seen, " ")
    local want = haveLuac and "color game" or "color game core"
    local good = type(m) == "table" and type(m.init) == "function" and type(m.run) == "function" and seq == want
      and lcd ~= mock and FORCE == 32 and lcd.drawLine ~= mock.drawLine
    print(string.format("%-18s on a color radio, %-17s loadScript calls: %-16s %s", loader,
      haveLuac and "with game.luac:" or "without game.luac:", seq, good and "ok" or ("FAIL (want " .. want .. ")")))
    ok = ok and good
  end
end
lcd = setmetatable({}, { __index = function() return function() return 0 end end })
SOLID, DOTTED, FORCE, ERASE = 0xff, 0x55, 2, 4
LCD_W, LCD_H = 128, 64
print(ok and "loaders: ok" or "loaders: FAIL")
if not ok then os.exit(1) end
