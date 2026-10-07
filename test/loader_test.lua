-- The B&W loaders (StickTimeBW.lua, StickTimeLite.lua) with a mock loadScript, run by the 32-bit
-- EdgeTX-config Lua: they must load the precompiled core.luac once, and only when there is
-- none let EdgeTX compile core.lua, drop that copy and load the saved bytecode.
local ROOT = "../sdcard/SCRIPTS/TOOLS/"
LCD_W, LCD_H = 128, 64
lcd = setmetatable({}, { __index = function() return function() return 0 end end })
SOLID, DOTTED, FORCE, ERASE = 0xff, 0x55, 2, 4
local ok = true

local function check(loader, haveLuac)
  local calls, luac = {}, haveLuac
  function loadScript(path, mode)
    mode = mode or "bt"
    calls[#calls + 1] = mode
    local rel = path:match("TOOLS/(.*)%.lua$")
    if mode == "b" and not luac then return nil, "no luac" end
    if mode == "b" or (mode == "bt" and luac) then
      local f = assert(io.open(ROOT .. rel .. ".luac", "rb"))
      local s = f:read("a")
      f:close()
      return load(s, "=core", "b")
    end
    luac = true                            -- EdgeTX compiles the source and saves core.luac
    return loadfile(ROOT .. rel .. ".lua")
  end
  local m = dofile(ROOT .. loader)
  local seq = table.concat(calls, " ")
  local want = haveLuac and "b" or "b bt b"
  local good = type(m) == "table" and type(m.init) == "function" and type(m.run) == "function" and seq == want
  print(string.format("%-12s %-22s loadScript calls: %-8s %s", loader, haveLuac and "with core.luac" or "without core.luac",
    seq, good and "ok" or ("FAIL (want " .. want .. ")")))
  ok = ok and good
end

for _, loader in ipairs({ "StickTimeBW.lua", "StickTimeLite.lua" }) do
  check(loader, true)
  check(loader, false)
end

-- started on a color radio: the loader runs <DIR>/color.lua, which loads the same core
-- (the bytecode) in its own environment, with lcd functions that draw the B&W flags in color
for _, loader in ipairs({ "StickTimeBW.lua", "StickTimeLite.lua" }) do
  LCD_W, LCD_H = 480, 272
  local seen = {}
  function loadScript(path, mode, env)
    local rel = path:match("TOOLS/(.*)%.lua$")
    seen[#seen + 1] = rel:match("[^/]*$") .. (env and "+env" or "")
    if rel:match("/color$") then return loadfile(ROOT .. rel .. ".lua") end
    local f = assert(io.open(ROOT .. rel .. ".luac", "rb"))
    local s = f:read("a")
    f:close()
    return load(s, "=core", "b", env)
  end
  lcd = setmetatable({ sizeText = function(t) return #t * 9, 17 end, RGB = function() return 0 end },
                     { __index = function() return function() return 0 end end })
  local m = dofile(ROOT .. loader)
  local seq = table.concat(seen, " ")
  local good = type(m) == "table" and type(m.init) == "function" and type(m.run) == "function" and seq == "color core+env"
  print(string.format("%-18s on a color radio: loadScript calls: %-16s %s", loader, seq,
    good and "game loaded through color.lua: ok" or "FAIL"))
  ok = ok and good
end
lcd = setmetatable({}, { __index = function() return function() return 0 end end })
LCD_W, LCD_H = 128, 64
print(ok and "loaders: ok" or "loaders: FAIL")
if not ok then os.exit(1) end
