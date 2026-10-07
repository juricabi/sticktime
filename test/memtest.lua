-- How much memory a B&W script needs on a radio. Runs in tools/etxhost's radio mode: the
-- script lives in its own Lua state with EdgeTX's Lua core, the radio API in ROM and a model
-- of the radio's allocator (bins / CCM plus newlib-nano malloc, fragmentation included).
--
--   ETX_MODEL=f2 ETX_HEAP=63300 .tools/etxhost -radio test/memtest.lua <file.lua|file.luac> [W H]
--
-- A .lua file is compiled in the radio state with its debug info, as on a radio's first start.
-- Then every track and mode is played through the script's STICKTIME_TEST hooks, with the GC
-- step EdgeTX runs before each run() call. Prints the heap high-water mark and "MEM OK".
local path, W, H = arg[1], tonumber(arg[2] or 128), tonumber(arg[3] or 64)
local function kb(n) return string.format("%.1f", n / 1024) end

radio.new(W, H)
-- a loader in /SCRIPTS/TOOLS loads its core with loadScript from the SD card folder
local root = string.match(path, "^(.*)/SCRIPTS/TOOLS/")
if root then radio.sdroot(root) end
-- a radio that has been used before: a save file with settings and bests for every track
local saves = { ["StickTimeLite"] = { "/SCRIPTS/TOOLS/StickTimeLite/data.txt", "FPVLITE2 mode=2 wind=1 quad=1 track=1 laps=3 rates=2 " ..
  "twr=5 tilt=20", "l%d=4810 r%d=14120 f%d=1200 g%d=12" }, ["StickTimeBW"] = { "/SCRIPTS/TOOLS/StickTimeBW.dat", "FPVSIM2 " ..
  "track=1 quad=1 ai=2 wind=0 mode=2 rm=850 fps=0 sticks=1 tilt=30 rc=150 map=1 re=45 ym=700 wash=0 laps=3 skill=1 " ..
  "rates=4 yc=130 ye=40 fov=100 twr=6", "l%d=4321 r%d=9876 g%d=7 f%d=300" } }
for name, sv in pairs(saves) do
  if string.find(path, name, 1, true) then
    local s = sv[2]
    for t = 1, 7 do s = s .. " " .. string.format(sv[3], t, t, t, t) end
    radio.setfile(sv[1], s)
  end
end
local base = radio.mem()
radio.resetpeak()
local ok, err = radio.load(path, true)
local lua, top, now, used, pools, fails, holes, big = radio.mem()
if not ok then
  print(string.format("%s %dx%d: LOAD FAILED (%s) | Lua %s KB, heap high-water %s KB, holes %s KB (largest %s)",
    path, W, H, tostring(err), kb(lua), kb(top), kb(holes), kb(big)))
  print("MEM FAIL")
  return
end
local loaded, loadedTop = lua - base, top
local clock = 0
local function frame(ev, a, e, t, r)
  clock = clock + 50
  radio.set(clock, a, e, t, r)
  radio.gcstep(10)                 -- EdgeTX: luaDoGc(lsScripts, false) before every run()
  local ok2, res = radio.call("run", ev or 0)
  if not ok2 then error("run: " .. tostring(res)) end
end
local peakLua, okRun, runErr = 0, true, nil
local ENTER, EXIT, NEXT, PREV, INC = 514, 513, 7680, 7424, 7680
local function fly()
  for i = 1, 200 do
    -- some throttle and pitch, alternating roll: flies, passes or hits things, crashes
    frame(0, (i // 40) % 2 == 0 and 200 or -200, 300, 250, 0)
    local l = radio.mem()
    if l > peakLua then peakLua = l end
  end
end
local function key(e) frame(e) frame(0) end
okRun, runErr = pcall(function()
  local ok3, e3 = radio.call("init")
  if not ok3 then error("init: " .. tostring(e3)) end
  for i = 1, 5 do frame(0) end
  if pcall(radio.call, "T.info") then
    -- test hooks: every track and mode directly (the full game has 7 tracks, 4 modes)
    local okT, _, nt = pcall(radio.call, "T.ntracks")
    local _, _, nm = pcall(radio.call, "T.nmodes")
    if not okT then nt, nm = 7, 4 end
    for t = 1, nt do
      for m = 1, nm do
        radio.call("T.track", t)
        radio.call("T.start", m)
        fly()
        key(EXIT) key(EXIT) key(EXIT)                   -- pause, menu
      end
    end
  else
    -- the Lite as shipped (no hooks), through its menus: 7 tracks x 4 modes, Track is item 5
    for t = 1, 7 do
      for m = 1, 4 do
        for _ = 2, m do key(NEXT) end
        key(ENTER)                                      -- start mode m
        fly()
        key(EXIT) key(NEXT) key(NEXT) key(ENTER)        -- pause, "Menu"
      end
      for _ = 1, 4 do key(NEXT) end
      key(ENTER) key(INC) key(ENTER)                    -- next track
      for _ = 1, 4 do key(PREV) end
    end
  end
end)
lua, top, now, used, pools, fails, holes, big = radio.mem()
local calls, lines, bad = radio.lcd()
print(string.format("%s %dx%d: Lua base %s KB, script loaded %s KB, playing peak %s KB | heap high-water %s KB " ..
  "(%s after loading), pools %s KB, holes %s KB (largest %s), emergency GCs %d%s",
  path, W, H, kb(base), kb(loaded), kb(peakLua - base), kb(top), kb(loadedTop), kb(pools), kb(holes), kb(big), fails,
  okRun and "" or ("  ERROR: " .. tostring(runErr))))
if bad > 0 then print("  " .. bad .. " lcd.drawLine calls with points off the screen") end
print(okRun and bad == 0 and "MEM OK" or "MEM FAIL")
