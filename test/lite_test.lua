-- Headless test of StickTime Lite (Lua 5.3 with EdgeTX's number settings, or Lua 5.2).
-- Usage: lua lite_test.lua build/sticktime_lite_test.lua [W H [color]]
-- color: on a color radio, through StickTimeLite/color.lua as the loader runs it there
-- Menus and settings, time trials on all seven tracks with an autopilot (gates, hoops, arches,
-- flags, dive gates, the Bando's doors), practice with wind, freestyle tricks and combos, gate
-- rush, crashes into the ground, a gate and a wall, pause, save and reload, B&W drawing rules,
-- VM instructions per frame.
local path, W, H = arg[1], tonumber(arg[2] or 128), tonumber(arg[3] or 64)
local COLOR = arg[4] == "color"
local floor = math.floor
local atan2 = math.atan2 or math.atan
local fails = 0
local function fail(msg) fails = fails + 1 if fails < 25 then print("FAIL: " .. msg) end end

LCD_W, LCD_H = W, H
local F = COLOR and { INVERS = 0x01, CENTER = 0x04, RIGHT = 0x08, LEFT = 0, BLINK = 0x1000, PREC1 = 0x20,
  PREC2 = 0x30, SOLID = 0xff, DOTTED = 0x55, BOLD = 0x100, TINSIZE = 0x200, SMLSIZE = 0x300, MIDSIZE = 0x400,
  DBLSIZE = 0x500, XXLSIZE = 0x600 } or { BLINK = 0x01, INVERS = 0x02, BOLD = 0x40, LEFT = 0, RIGHT = 0x04,
  CENTER = 0x20, PREC1 = 0x20, PREC2 = 0x30, FORCE = 0x02, ERASE = 0x04, ROUND = 0x08, TINSIZE = 0x100,
  SMLSIZE = 0x200, MIDSIZE = 0x300, DBLSIZE = 0x400, XXLSIZE = 0x500, SOLID = 0xff, DOTTED = 0x55 }
for k, v in pairs(F) do _G[k] = v end
EVT_VIRTUAL_ENTER, EVT_VIRTUAL_EXIT, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV = 514, 513, 7680, 7424
-- like a radio with +/- keys: INC is PREV (+), DEC is NEXT (-)
EVT_VIRTUAL_INC, EVT_VIRTUAL_DEC = 7424, 7680
if W == 212 then GREY = function(x) return x * 0x10000 end end

local clock = 0
local sticks = { ail = 0, ele = 0, thr = -1024, rud = 0 }
function getTime() return floor(clock / 10) end
function getValue(id)
  local v = id == 1 and sticks.ail or id == 2 and sticks.ele or id == 3 and sticks.thr or id == 4 and sticks.rud or 0
  return floor((v > 1024 and 1024 or v < -1024 and -1024 or v) + 0.5)
end
function getFieldInfo(n)
  local ids = { ail = 1, ele = 2, thr = 3, rud = 4 }
  return ids[n] and { id = ids[n], name = n } or nil
end
local tones = 0
PLAY_NOW, PLAY_BACKGROUND = 0x10, 0x20                 -- EdgeTX's values
-- background tones (the motor sound): how many, and the last one's frequency, length, flags, volume
local bgt = { n = 0 }
function playTone(f, d, p, flags, incr, vol)
  if flags and flags % 0x40 >= 0x20 then bgt.n, bgt.f, bgt.len, bgt.flags, bgt.vol = bgt.n + 1, f, d, flags, vol
  else tones = tones + 1 end
end
local buzz = 0
function playHaptic() buzz = buzz + 1 end
-- the SD card: the track files from the repository, then what the script writes
local SD = {}
for t = 1, 9 do
  local fh = io.open("../sdcard/SCRIPTS/TOOLS/StickTimeLite/t" .. t .. ".txt", "r")
  if fh then SD["/SCRIPTS/TOOLS/StickTimeLite/t" .. t .. ".txt"] = fh:read("*a") fh:close() end
end
io = {
  open = function(p, m) if m == "r" and not SD[p] then return nil end return { p = p, m = m, d = (m == "r") and SD[p] or "", pos = 1 } end,
  read = function(f, n) local s = string.sub(f.d, f.pos, f.pos + n - 1) f.pos = f.pos + #s return s end,
  write = function(f, ...) for _, s in ipairs({ ... }) do f.d = f.d .. tostring(s) end end,
  close = function(f) if f.m ~= "r" then SD[f.p] = f.d end end,
}
-- not on B&W radios: the script must not touch them
local hidden = {}
for _, k in ipairs({ "table", "os", "debug", "coroutine", "utf8", "package", "require" }) do hidden[k] = true end

local st = { lines = 0, bad = 0, calls = 0 }
local function num(v, what)
  if type(v) ~= "number" or v ~= v then fail(what .. ": bad number " .. tostring(v)) return 0 end
  return v
end
lcd = {
  clear = function() st.calls = st.calls + 1 end,
  drawLine = function(x1, y1, x2, y2, pat, fl)
    st.calls, st.lines = st.calls + 1, st.lines + 1
    x1, y1, x2, y2 = num(x1, "line x1"), num(y1, "line y1"), num(x2, "line x2"), num(y2, "line y2")
    if fl == nil then fail("drawLine without flags (XOR on B&W)") end
    if COLOR then
      -- color radios drop a line with an end beyond the right or bottom edge
      if x1 > W or x2 > W or y1 > H or y2 > H then st.bad = st.bad + 1 end
    elseif x1 < 0 or y1 < 0 or x2 < 0 or y2 < 0 or x1 >= W or x2 >= W or y1 >= H or y2 >= H then st.bad = st.bad + 1 end
  end,
  drawText = function(x, y, s) st.calls = st.calls + 1 num(x, "text x") num(y, "text y")
    if type(s) ~= "string" then fail("drawText: not a string") end
    if COLOR and (x < 0 or x > W or y < 0 or y > H - 12) then fail("text off the screen at " .. x .. "," .. y .. ": " .. s) end
  end,
  sizeText = function(s) return #s * 9, 17 end,
  RGB = function(r, g, b) return 0x8000 + (floor(r / 8) * 2048 + floor(g / 4) * 32 + floor(b / 8)) * 65536 end,
  drawNumber = function(x, y, v) st.calls = st.calls + 1 num(x, "num x") num(y, "num y") num(v, "num v") end,
  drawRectangle = function(x, y) st.calls = st.calls + 1 num(x, "rect x") num(y, "rect y") end,
  drawFilledRectangle = function(x, y, w, h)
    st.calls = st.calls + 1
    if num(x, "fill x") < 0 or num(y, "fill y") < 0 or num(w, "fill w") < 0 or num(h, "fill h") < 0 then fail("negative fill") end
  end,
}

-- EdgeTX gives strings no metatable: s:sub() style calls fail on a radio, so here too
debug.setmetatable("", nil)
-- load in an environment without the libraries B&W radios lack
STICKTIME_TEST = {}
local f
if COLOR then
  -- color.lua, which loads the game (here the test build). As on EdgeTX, a third argument
  -- (env) leaves the chunk with no globals at all.
  function loadScript(p, mode, ...)
    local file = string.find(p, "/core.lua", 1, true) and path or "../sdcard" .. p
    if select("#", ...) > 0 then return loadfile(file, "t", nil) end
    return loadfile(file, "t")
  end
  f = function() return dofile("../sdcard/SCRIPTS/TOOLS/StickTimeLite/color.lua") end
else
  f = assert(loadfile(path, "t", setmetatable({}, { __index = function(_, k)
    if hidden[k] then error("uses '" .. k .. "', which B&W radios do not have", 2) end
    return _G[k]
  end, __newindex = function(_, k) fail("sets global " .. tostring(k)) end })))
end
local script = f()
local T = STICKTIME_TEST
script.init()

local instrMax, instrSum, frames = 0, 0.0, 0
local function frame(ev)
  clock = clock + 50
  local n = 0
  debug.sethook(function() n = n + 100 end, "", 100)
  local ok, r = pcall(script.run, ev or 0)
  debug.sethook()
  if not ok then fail("run: " .. tostring(r)) return 0 end
  frames, instrSum = frames + 1, instrSum + n
  if n > instrMax then instrMax = n end
  return r
end
local function state() local t = { T.get() } return t[16], t end
local function steps(n) for _ = 1, n do frame(0) end end
local function idle() sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, -1024 end
local FLY, CRASHED, READY, PAUSED, DONE, MENU, SETUP = 4, 5, 6, 7, 8, 1, 2

-- angle-mode autopilot: steer toward a lead point on the gate axis, hold the gate height
local function autopilot(target)
  local _, s = state()
  local px, py, pz, vx, vy, vz, fx, fz = s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[9]
  local _, _, _, nx, ny, nz, k, cx, cy, cz = T.gate(target or s[18])          -- aim point
  local d = (px - cx) * nx + (py - cy) * ny + (pz - cz) * nz
  if target and d > 0 then nx, nz, d = -nx, -nz, -d end
  local lead = math.min(14, math.max(0, -d * 0.55))
  local tx, ty, tz = cx - nx * lead, cy - ny * lead, cz - nz * lead
  local hd = math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
  if k == 3 then tx, tz, ty = cx, cz, hd > 1.2 and cy + 3 or cy - 4 end
  local dx, dz = tx - px, tz - pz
  local dist = math.sqrt(dx * dx + dz * dz) + 1e-6
  local hl = math.sqrt(fx * fx + fz * fz) + 1e-6
  local hx, hz = fx / hl, fz / hl
  local herr = atan2(hz * dx - hx * dz, hx * dx + hz * dz)
  sticks.rud = math.max(-1, math.min(1, herr * 1.6)) * 1024
  local vf, vs = vx * hx + vz * hz, vx * hz - vz * hx
  local vdes = math.min(11, 3 + dist * 0.35)
  if math.abs(herr) > 0.6 then vdes = 3 end
  if k == 3 then vdes = math.min(vdes, hd * 0.6) end
  sticks.ele = math.max(-0.75, math.min(0.75, (vdes - vf) * 0.12)) * 1024
  sticks.ail = math.max(-0.6, math.min(0.6, -vs * 0.15 + herr * 0.25)) * 1024
  local _, twr = T.info()
  local tilt = math.min(0.8, math.abs(sticks.ele / 1024) * 0.9)
  local hover = ((1 / twr - 0.015) / 0.985) ^ (1 / 1.6) / math.cos(tilt)
  sticks.thr = (math.max(0, math.min(1, hover + (ty - py) * 0.08 - vy * 0.1)) * 2 - 1) * 1024
end

-- 1. menus: walk the main menu, change the track, every setting both ways
steps(5)
for _ = 1, 7 do frame(EVT_VIRTUAL_NEXT) end
for _ = 1, 7 do frame(EVT_VIRTUAL_PREV) end
if state() ~= MENU then fail("not in the menu") end
for _ = 1, 4 do frame(EVT_VIRTUAL_NEXT) end           -- Track
frame(EVT_VIRTUAL_ENTER)
frame(EVT_VIRTUAL_INC) frame(EVT_VIRTUAL_INC)
if T.S.track ~= 3 then fail("track +2 should be 3, is " .. T.S.track) end
frame(EVT_VIRTUAL_DEC)
if T.S.track ~= 2 then fail("track -1 should be 2, is " .. T.S.track) end
frame(EVT_VIRTUAL_EXIT)
frame(EVT_VIRTUAL_NEXT)                                -- Settings
frame(EVT_VIRTUAL_ENTER)
if state() ~= SETUP then fail("settings did not open") end
local before = {}
for k, v in pairs(T.S) do before[k] = v end
for i = 1, 9 do
  frame(EVT_VIRTUAL_ENTER)
  frame(EVT_VIRTUAL_INC) frame(0)
  frame(EVT_VIRTUAL_DEC) frame(EVT_VIRTUAL_DEC) frame(0)
  frame(EVT_VIRTUAL_INC)
  frame(EVT_VIRTUAL_EXIT)
  frame(EVT_VIRTUAL_NEXT)
end
for k, v in pairs(before) do
  if T.S[k] ~= v then fail("setting " .. k .. " changed after +1 -2 +1: " .. tostring(v) .. " -> " .. tostring(T.S[k])) end
end
frame(EVT_VIRTUAL_ENTER)                               -- on Back
if state() ~= MENU then fail("Back did not return to the menu") end
-- the settings rows wrap: +1 on the last value of Power goes to the first
T.set("twr", 12)
frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_PREV)

-- 2. time trial and practice on every track, flown by the autopilot in angle mode
T.set("mode", 2)
T.set("laps", 2)
T.set("twr", 5)
local NT = T.info()
for t = 1, NT do
  T.track(t)
  T.start(1)
  idle()
  steps(70)
  local s0 = state()
  if s0 ~= FLY then fail("track " .. t .. ": not flying after the countdown (state " .. s0 .. ")") end
  local crashes, sim = 0, 0
  local last = s0
  while sim < 6000 do
    local s = state()
    if s == DONE then break end
    if s == CRASHED and last ~= CRASHED then crashes = crashes + 1 end
    last = s
    if s == FLY then autopilot() else idle() end
    if s == READY then sticks.thr = 0 end
    frame(0)
    sim = sim + 1
  end
  local _, _, gm, lap, total = T.info()
  local bl, br = T.best(t)
  local name = select(8, T.info())
  local nb = select(12, T.info())
  print(string.format("track %d %-11s time trial: finished=%s laps=%d total=%.2fs best lap %.2fs crashes=%d%s",
    t, name, tostring(state() == DONE), lap, total / 100, bl / 100, crashes, nb > 0 and (" structures=" .. nb) or ""))
  if state() ~= DONE then fail("track " .. t .. ": time trial not finished") end
  if crashes > 0 then fail("track " .. t .. ": autopilot crashed " .. crashes .. " times") end
  if br <= 0 or bl <= 0 or br < bl * 2 then fail("track " .. t .. ": best race/lap not recorded right") end
  idle()
  frame(EVT_VIRTUAL_EXIT)                              -- results -> menu
  if state() ~= MENU then fail("EXIT on the results should go to the menu") end
end

-- practice in strong wind: laps keep counting
T.set("wind", 2)
T.track(1)
T.start(2)
steps(70)
local wsteps = 0
for i = 1, 4800 do
  if state() == FLY then autopilot() else idle() end
  frame(0)
  if select(4, T.info()) >= 3 and wsteps == 0 then wsteps = i end
end
local _, _, _, plap = T.info()
print(string.format("practice in strong wind: %d laps in 240 s, 3 laps after %.1f s", plap, wsteps / 20))
if plap < 3 then fail("practice in wind: only " .. plap .. " laps in 240 s") end
T.set("wind", 0)

-- freestyle: no countdown; a roll in acro is a trick, the combo is banked 2.5 s later
T.set("mode", 1)
T.track(1)
T.start(3)
steps(2)
if state() ~= READY then fail("freestyle should start without a countdown (state " .. state() .. ")") end
sticks.thr = 0
steps(8)
if state() ~= FLY then fail("freestyle: stick did not start flying") end
T.pose(0, 25, 20, 0, 0, 0)
sticks.ail, sticks.thr = 1024, 100
steps(14)
local sc, chn = select(10, T.info())
if chn < 1 then fail("freestyle: no trick after a full roll (combo " .. chn .. ")") end
-- level out where the roll ended (it overshoots by some 60 deg) and hover while the combo banks
local _, sp = state()
T.pose(sp[1], sp[2], sp[3], 0, 0, 0)
T.vel(0, 0, 0)
sticks.ail = 0
sticks.thr = -250
steps(70)
sc, chn = select(10, T.info())
local _, _, _, bf = T.best(1)
print(string.format("freestyle: score %d after a roll, best combo %d", sc, bf))
if sc < 100 or chn > 0 or bf ~= sc then fail("freestyle: combo not banked (score " .. sc .. ", best " .. bf .. ")") end
-- a crash loses the combo in progress
T.pose(0, 25, 20, 0, 0, 0)
sticks.ail, sticks.thr = 1024, 100
steps(14)
T.pose(0, 1, 20, 0, -80, 0)
T.vel(0, -15, 0)
sticks.ail, sticks.thr = 0, -1024
steps(6)
local sc2, chn2 = select(10, T.info())
if state() ~= CRASHED or chn2 ~= 0 or sc2 ~= sc then fail("freestyle: a crash should lose the combo (state " .. state() .. ", combo " .. chn2 .. ", score " .. sc2 .. " was " .. sc .. ")") end
steps(40)
T.set("mode", 2)
idle()
frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)

-- the Bando: flying into a wall is a crash
T.track(7)
T.start(2)
steps(70)
T.pose(-6, 2, 28, 0, 0, 0)
T.vel(0, 0, 10)
sticks.thr = 0
steps(15)
if state() ~= CRASHED then fail("no crash into the Bando's wall (state " .. state() .. ")") end
idle()
steps(40)
frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)

-- 3. gate rush: random gates either way (no flags), 30 s plus bonuses, ends by itself
T.track(4)
T.start(4)
steps(70)
local rushSteps = 0
while state() ~= DONE and rushSteps < 4000 do
  local _, s = state()
  local k = select(7, T.gate(s[18]))
  if k == 6 or k == 7 then fail("gate rush picked a flag") break end
  if state() == FLY then autopilot(s[18]) else idle() end
  frame(0)
  rushSteps = rushSteps + 1
end
local _, _, _, _, _, rn = T.info()
local _, _, bg = T.best(4)
print(string.format("gate rush: %d gates in %.1f s, best %d", rn, rushSteps / 20, bg))
if state() ~= DONE then fail("gate rush did not end") end
if rn < 4 or bg ~= rn then fail("gate rush: " .. rn .. " gates, best " .. bg) end
frame(EVT_VIRTUAL_EXIT)

-- 4. crash into the ground, respawn, fly on with a stick
T.track(1)
T.start(2)
steps(70)
T.pose(0, 6, -10, 0, -80, 0)
T.vel(0, -12, 4)
sticks.thr = -1024
steps(10)
if state() ~= CRASHED then fail("no crash into the ground (state " .. state() .. ")") end
steps(30)
if state() ~= READY then fail("not READY after a crash (state " .. state() .. ")") end
sticks.thr = 0
steps(3)
if state() ~= FLY then fail("stick did not start flying again") end
-- flying into a gate post
local cx, cy, cz, nx, _, nz = T.gate(2)
T.pose(cx + nz * 1.6 - nx * 4, cy, cz - nx * 1.6 - nz * 4, math.deg(atan2(nx, nz)), 0, 0)
T.vel(nx * 10, 0, nz * 10)
sticks.thr = 0
steps(15)
if state() ~= CRASHED then fail("no crash into the gate frame (state " .. state() .. ")") end

-- ground effect: at the throttle that holds a hover high up, the quad rises near the ground
do
  local hover = (((1 / 5 - 0.015) / 0.985) ^ (1 / 1.6) * 2 - 1) * 1024
  local function vyAfter(y)
    T.track(1) T.start(2) steps(70)
    local _, s0 = state()
    T.pose(s0[1], y, s0[3], 0, 0, 0) T.vel(0, 0, 0)
    sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, hover
    steps(10)
    local st, s = state()
    return s[5], st
  end
  local vLow, stLow = vyAfter(0.3)
  local vHigh, stHigh = vyAfter(6)
  print(string.format("ground effect: hover throttle, after 0.5 s: %.2f m/s up from 0.3 m, %.2f m/s from 6 m", vLow, vHigh))
  if stLow ~= FLY or stHigh ~= FLY or not (vLow > vHigh + 0.05) then fail("no ground effect near the ground") end
  idle()
end
idle()

-- motor sound: a background tone whose pitch follows the throttle while flying, silent when
-- paused or off; Vibration off: no buzz on a crash
do
  local snd, vib, mode = T.S.snd, T.S.vib, T.S.mode
  T.set("mode", 1) T.set("snd", 2) T.set("vib", 1)
  T.track(1) T.start(2) steps(70) T.state(FLY)
  local _, s0 = state()
  T.pose(s0[1], 30, s0[3], 0, 0, 0) T.vel(0, 0, 0)
  sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, -1024
  bgt.n = 0
  steps(8)
  local nIdle, fIdle = bgt.n, bgt.f or 0
  sticks.thr = 1024
  steps(8)
  local fFull = bgt.f or 0
  print(string.format("motor sound: %d tones in 0.4 s, %d Hz at idle, %d Hz at full throttle (flags %s, volume %s, %s ms)",
    nIdle, fIdle, fFull, tostring(bgt.flags), tostring(bgt.vol), tostring(bgt.len)))
  if nIdle < 4 then fail("motor sound: no background tone while flying") end
  if bgt.flags ~= PLAY_BACKGROUND + PLAY_NOW or bgt.vol ~= 3 or not bgt.len or bgt.len < 100 then fail("motor sound: wrong playTone arguments") end
  if fIdle < 160 or fIdle > 220 or fFull < 480 or fFull > 620 then fail("motor sound: pitch should rise from about 190 to 540 Hz") end
  sticks.thr = -300
  frame(EVT_VIRTUAL_EXIT)                                -- pause
  frame(0)
  if state() ~= PAUSED or bgt.len ~= 0 then fail("motor sound: not silenced on pause (state " .. state() .. ")") end
  local n = bgt.n
  steps(5)
  if bgt.n ~= n then fail("motor sound: tones while paused") end
  frame(EVT_VIRTUAL_ENTER)                               -- resume
  T.set("snd", 0)
  steps(4)
  n = bgt.n
  steps(6)
  if bgt.n ~= n then fail("motor sound: tones with Motor sound off") end
  for v = 1, 0, -1 do
    T.set("vib", v)
    T.state(FLY) T.pose(s0[1], 3, s0[3], 0, 0, 0) T.vel(0, -15, 0)
    local b = buzz
    steps(6)
    if state() ~= CRASHED then fail("hard landing should crash (state " .. state() .. ")") end
    if (buzz > b) ~= (v == 1) then fail("Vibration " .. (v == 1 and "on" or "off") .. ": " .. (buzz - b) .. " buzzes on a crash") end
  end
  print("vibration: buzz on a crash only with Vibration on")
  T.set("snd", snd) T.set("vib", vib) T.set("mode", mode)
  idle()
end

-- 5. pause: EXIT pauses, Resume, Restart, Menu
steps(40)
frame(EVT_VIRTUAL_EXIT)
if state() ~= PAUSED then fail("EXIT did not pause") end
frame(EVT_VIRTUAL_ENTER)
if state() == PAUSED then fail("Resume did not resume") end
frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)
if state() ~= 3 then fail("Restart did not restart the countdown (state " .. state() .. ")") end
frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)
if state() ~= MENU then fail("Menu did not go to the menu") end
-- pick track 3 in the menu (saved), then EXIT in the main menu closes the tool
for _ = 1, 4 do frame(EVT_VIRTUAL_NEXT) end
frame(EVT_VIRTUAL_ENTER)
while T.S.track ~= 3 do frame(EVT_VIRTUAL_INC) end
frame(EVT_VIRTUAL_ENTER)
for _ = 1, 4 do frame(EVT_VIRTUAL_PREV) end
if frame(EVT_VIRTUAL_EXIT) ~= 1 then fail("EXIT in the menu should close the tool") end

-- 6. saved and loaded again by a new instance
local saved = SD["/SCRIPTS/TOOLS/StickTimeLite/data.txt"]
if not saved then fail("nothing saved") else
  STICKTIME_TEST = {}
  local s2 = f()
  local T2 = STICKTIME_TEST
  s2.init()
  for k, v in pairs(T.S) do
    if T2.S[k] ~= v then fail("setting " .. k .. " not restored: " .. tostring(v) .. " vs " .. tostring(T2.S[k])) end
  end
  if T2.S.track ~= 3 then fail("track not restored") end
  for t = 1, NT do
    local a1, a2, a3, a4 = T.best(t)
    local b1, b2, b3, b4 = T2.best(t)
    if floor(a1) ~= b1 or floor(a2) ~= b2 or a3 ~= b3 or a4 ~= b4 then fail("bests of track " .. t .. " not restored") end
  end
  print("saved: " .. saved)
end
-- a broken save file is ignored
SD["/SCRIPTS/TOOLS/StickTimeLite/data.txt"] = "FPVLITE2 track=99 twr=13 mode=x laps=-1 l1=abc"
STICKTIME_TEST = {}
local s3 = f()
s3.init()
if STICKTIME_TEST.S.track ~= 1 or STICKTIME_TEST.S.twr ~= 5 then fail("bad save values were not rejected") end
s3.run(0)
-- a save of the first Lite, under its old name FPV Sim Lite (four tracks: the 4th was the Grand
-- Prix, now the 6th): read, and saved under the new name right away
SD["/SCRIPTS/TOOLS/StickTimeLite/data.txt"] = nil
SD["/SCRIPTS/TOOLS/FPVLite/data.txt"] = "FPVLITE1 track=4 twr=6 rates=3 l1=4810 r1=10120 g1=3 l4=8000 r4=16500 g4=7"
STICKTIME_TEST = {}
local s4 = f()
s4.init()
local T4 = STICKTIME_TEST
local a1, a2, a3, a4 = T4.best(6)                 -- lap, race, gate rush, combo
local c1, c2, c3, c4 = T4.best(4)
local d1, d2, d3 = T4.best(1)
if T4.S.track ~= 6 or T4.S.twr ~= 6 or T4.S.rates ~= 3 or a1 ~= 8000 or a2 ~= 16500 or a3 ~= 7 or a4 ~= 0
  or c1 ~= 0 or c2 ~= 0 or c3 ~= 0 or c4 ~= 0 or d1 ~= 4810 or d2 ~= 10120 or d3 ~= 3 then
  fail("a save of the first Lite was not read right")
end
local new = SD["/SCRIPTS/TOOLS/StickTimeLite/data.txt"]
if not new or string.sub(new, 1, 8) ~= "FPVLITE2" or not string.find(new, "l6=8000", 1, true) then
  fail("the first Lite's save was not written under the new name")
end
s4.run(0)

print(string.format("%s %s %dx%d%s  frames %d  instr/frame avg %d max %d  lines %d  off-screen lines %d  tones %d",
  _VERSION, string.match(path, "[^/]+$"), W, H, COLOR and " color" or "", frames, floor(instrSum / frames), instrMax,
  st.lines, st.bad, tones))
if st.bad > 0 then fail(st.bad .. " lines with points off the screen (the firmware refuses them)") end
print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
