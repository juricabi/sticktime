-- The B&W loaders (StickTimeBW.lua, StickTimeLite.lua) with a mock loadScript, run by the 32-bit
-- EdgeTX-config Lua: they must load the precompiled game.luac once, in "b" mode, and never ask
-- EdgeTX for the source: compiling it takes more memory than a B&W radio has. When the game
-- doesn't load (no game.luac, too little memory, EdgeTX older than 2.11) the loader returns a
-- tool of its own that says what to do, in lines that fit a 128 px screen, and closes on EXIT.
local ROOT = "../sdcard/SCRIPTS/TOOLS/"
LCD_W, LCD_H = 128, 64
local shown = {}                                   -- what the B&W screen shows: text since lcd.clear()
local function bwlcd()
  return setmetatable({ clear = function() shown = {} end, drawText = function(x, y, t) shown[#shown + 1] = tostring(t) end },
                      { __index = function() return function() return 0 end end })
end
lcd = bwlcd()
SOLID, DOTTED, FORCE, ERASE = 0xff, 0x55, 2, 4
EVT_VIRTUAL_EXIT, EVT_EXIT_BREAK = 513, 513
local VERSION
function getVersion() return table.unpack(VERSION) end
local ok = true

-- case: "game" (game.luac loads), "nofile" (no game.luac), "oom" (too little memory to load it),
-- "old" (EdgeTX 2.10, whose Lua 5.2 can't read the binary)
local LABEL = { game = "with game.luac", nofile = "without game.luac", oom = "out of memory", old = "on EdgeTX 2.10" }
local function check(loader, case)
  local calls = {}
  VERSION = case == "old" and { "2.10.7", "x9d+", 2, 10, 7, "EdgeTX" } or { "2.11.4", "x9d+", 2, 11, 4, "EdgeTX" }
  function loadScript(path, mode)
    mode = mode or "bt"
    local rel = path:match("TOOLS/(.*)%.lua$")
    calls[#calls + 1] = rel:match("[^/]*$") .. ":" .. mode
    if case == "oom" then return nil, "not enough memory" end
    if case == "old" then return nil, "/SCRIPTS/TOOLS/" .. rel .. ".luac: version mismatch in precompiled chunk" end
    local f = case == "game" and io.open(ROOT .. rel .. ".luac", "rb")
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
  local want, screen = "game:b", ""
  if case == "game" then
    good = good and type(m) == "table" and type(m.init) == "function" and type(m.run) == "function" and seq == want
  else
    good = good and type(m) == "table" and m.init == nil and type(m.run) == "function" and seq == want
    if good then
      local r0 = m.run(0)
      screen = table.concat(shown, " / ")
      local r1 = m.run(EVT_VIRTUAL_EXIT)
      local need = case == "oom" and (loader == "StickTimeBW.lua" and "Use StickTime Lite" or "Not enough memory")
        or case == "old" and "Needs EdgeTX 2.11" or loader:gsub("%.lua$", "") .. " into"
      good = r0 == 0 and r1 == 1 and string.find(screen, need, 1, true) ~= nil
        and (case ~= "old" or string.find(screen, "2.10.7", 1, true) ~= nil)
      for _, t in ipairs(shown) do
        if #t > 21 then good = false end           -- 21 characters of 6 px: 126 of 128 px
      end
    end
  end
  print(string.format("%-18s %-18s loadScript calls: %-7s %s", loader, LABEL[case], seq,
    good and (case == "game" and "ok" or "ok, shows: " .. screen) or ("FAIL (want " .. want .. ", got " .. tostring(m) .. " " .. screen .. ")")))
  ok = ok and good
end

for _, loader in ipairs({ "StickTimeBW.lua", "StickTimeLite.lua" }) do
  for _, case in ipairs({ "game", "nofile", "oom", "old" }) do check(loader, case) end
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
lcd = bwlcd()
SOLID, DOTTED, FORCE, ERASE = 0xff, 0x55, 2, 4
LCD_W, LCD_H = 128, 64
print(ok and "loaders: ok" or "loaders: FAIL")
if not ok then os.exit(1) end
