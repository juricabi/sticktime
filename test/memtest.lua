-- How much memory a B&W script needs on a radio. Runs in tools/etxhost's radio mode: the
-- script lives in its own Lua state with EdgeTX's Lua core, the radio API in ROM and a model
-- of the radio's allocator (bins / CCM plus newlib-nano malloc, fragmentation included).
--
--   ETX_MODEL=f2 ETX_HEAP=63300 .tools/etxhost -radio test/memtest.lua <file.lua|file.luac> [W H [color]]
--
-- "color": a color radio (its lcd functions and flag values), where the B&W loaders run
-- StickTimeBW/color.lua and StickTimeLite/color.lua.
--
-- A .lua file is compiled in the radio state with its debug info, as on a radio's first start.
-- Then every track and mode is played through the script's STICKTIME_TEST hooks, with the GC
-- step EdgeTX runs before each run() call. Prints the heap high-water mark and "MEM OK".
local path, W, H, COLOR = arg[1], tonumber(arg[2] or 128), tonumber(arg[3] or 64), arg[4] == "color"
local function kb(n) return string.format("%.1f", n / 1024) end

radio.new(W, H, COLOR)
-- a loader in /SCRIPTS/TOOLS loads its core with loadScript from the SD card folder
local root = string.match(path, "^(.*)/SCRIPTS/TOOLS/")
if root then radio.sdroot(root) end
-- a radio that has been used before: a save file with settings and bests for every track
local saves = { ["StickTimeLite"] = { "/SCRIPTS/TOOLS/StickTimeLite/data.txt", "FPVLITE2 mode=2 wind=1 quad=1 track=1 laps=3 rates=2 " ..
  "twr=5 tilt=20", "l%d=4810 r%d=14120 f%d=1200 g%d=12" }, ["StickTimeBW"] = { "/SCRIPTS/TOOLS/StickTimeBW.dat", "FPVSIM2 " ..
  "track=1 quad=1 ai=2 wind=0 mode=2 rm=850 fps=0 sticks=1 tilt=30 rc=150 map=1 re=45 ym=700 wash=0 laps=3 skill=1 " ..
  "rates=4 yc=130 ye=40 fov=100 twr=6 batt=1", "l%d=4321 r%d=9876 g%d=7 f%d=300" } }
for name, sv in pairs(saves) do
  if string.find(path, name, 1, true) then
    local s = sv[2]
    for t = 1, 7 do s = s .. " " .. string.format(sv[3], t, t, t, t) end
    radio.setfile(sv[1], s)
  end
end
-- StickTime BW: a custom track as big as the editor makes them (24 gates, 16 structures) in slot 1,
-- track 9, played like the others
if string.find(path, "StickTimeBW", 1, true) then
  local big = "Big Test" .. string.char(10) .. "1 4321 7 30 0 0 1 0 0  18 2 2 15 0  35 9 4 30 0  49 21 1 45 0  61 35 5 60 0  68 52 6 75 0  70 70 1 90 0  68 88 4 105 0  61 105 2 120 0  49 119 1 135 0  35 131 7 150 0  18 138 4 165 0  0 140 1 180 0  -18 138 2 195 0  -35 131 1 210 0  -49 119 4 225 0  -61 105 6 240 0  -68 88 1 255 0  -70 70 2 270 0  -68 52 4 285 0  -61 35 1 300 0  -49 21 7 315 0  -35 9 1 330 0  -18 2 4 345 0 / 0 -35 3 2 0 4 1  40 -27 3 2 0 5 2  74 -4 3 2 0 6 3  97 30 3 2 0 4 1  105 70 3 2 0 5 2  97 110 3 2 0 6 3  74 144 3 2 0 4 1  40 167 3 2 0 5 2  0 175 3 2 0 6 3  -40 167 3 2 0 4 1  -74 144 3 2 0 5 2  -97 110 3 2 0 6 3  -105 70 3 2 0 4 1  -97 30 3 2 0 5 2  -74 -4 3 2 0 6 3  -40 -27 3 2 0 4 1" .. string.char(10)
  radio.setfile("/SCRIPTS/TOOLS/StickTimeTracks/c1.txt", big)
  -- and the biggest format 3 track it reads (1.10.0): those gates and structures with as much scenery
  -- after them as fits in 1599 bytes (StickTime BW reads the whole file and flies the gates and
  -- structures; the scenery is the color edition's), track 10
  local t3 = "Big Scenery" .. string.char(10) .. "3 4322" .. string.sub(big, 16, #big - 1) .. " /"
  local rails, decals = string.rep(" -50 -50 50 -50 1 0", 12), string.rep(" 0 70 5 3 0 5", 8)
  while #t3 + 10 + 2 + #rails + 2 + #decals + 1 <= 1599 do t3 = t3 .. " 10 20 4 0" end
  radio.setfile("/SCRIPTS/TOOLS/StickTimeTracks/c2.txt", t3 .. " /" .. rails .. " /" .. decals .. string.char(10))
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
    frame(0, math.floor(i / 40) % 2 == 0 and 200 or -200, 300, 250, 0)
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
    local okT, _, nt = pcall(radio.call, "T.info")     -- the highest track there is (custom ones too)
    local _, _, nm = pcall(radio.call, "T.nmodes")
    if not okT or type(nt) ~= "number" then nt = 7 end
    if type(nm) ~= "number" then nm = 4 end
    for t = 1, nt do
      for m = 1, nm do
        radio.call("T.track", t)
        radio.call("T.start", m)
        fly()
        key(EXIT) key(EXIT) key(EXIT)                   -- pause, menu
      end
    end
  else
    -- as shipped (no hooks: StickTime BW and the Lite), through the menus: every track (StickTime
    -- BW: the custom one too) x 4 modes, Track is item 5; the pause menu's way back to the menu is
    -- the Lite's 3rd item, StickTime BW's 5th
    local bw = string.find(path, "StickTimeBW", 1, true)
    for t = 1, bw and 10 or 8 do
      for m = 1, 4 do
        for _ = 2, m do key(NEXT) end
        key(ENTER)                                      -- start mode m
        fly()
        key(EXIT)                                       -- pause
        for _ = 1, bw and 4 or 2 do key(NEXT) end
        key(ENTER)                                      -- "Menu" / "Main menu"
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
