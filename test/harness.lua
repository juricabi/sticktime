-- Headless EdgeTX mock for the StickTime scripts (runs under Lua 5.2 / 5.3).
-- Usage: lua harness.lua <script.lua> <color|bw|bwcolor> [W H]
-- bwcolor: StickTime BW on a color radio, through StickTimeBW/color.lua (give that file)
-- Flies full races with an autopilot on every track, races AI pilots, plays
-- Freestyle and Gate Rush, exercises every menu, checks API arguments the way
-- the firmware would see them and reports VM instructions per frame.
local path, kind, W, H = arg[1], arg[2] or "color", tonumber(arg[3] or 480), tonumber(arg[4] or 272)
local COLOR = kind ~= "bw"           -- a color radio
local GAME_COLOR = kind == "color"   -- the color game (else StickTime BW)
local floor = math.floor
local fails = 0
local function fail(msg) fails = fails + 1; if fails < 25 then print("FAIL: " .. msg) end end

-- ---------------------------------------------------------------- globals
LCD_W, LCD_H = W, H
local env = _G
local flags = COLOR and {
  INVERS = 0x01, VCENTER = 0x02, CENTER = 0x04, RIGHT = 0x08, LEFT = 0, SHADOWED = 0x80, BLINK = 0x1000,
  PREC1 = 0x20, PREC2 = 0x30, SOLID = 0xff, DOTTED = 0x55, BOLD = 0x100, TINSIZE = 0x200, SMLSIZE = 0x300,
  MIDSIZE = 0x400, DBLSIZE = 0x500, XXLSIZE = 0x600 } or {
  BLINK = 0x01, INVERS = 0x02, BOLD = 0x40, LEFT = 0, RIGHT = 0x04, CENTER = 0x20, PREC1 = 0x20, PREC2 = 0x30,
  FORCE = 0x02, ERASE = 0x04, ROUND = 0x08, TINSIZE = 0x100, SMLSIZE = 0x200, MIDSIZE = 0x300, DBLSIZE = 0x400,
  XXLSIZE = 0x500, SOLID = 0xff, DOTTED = 0x55 }
for k, v in pairs(flags) do env[k] = v end
EVT_VIRTUAL_ENTER, EVT_VIRTUAL_EXIT, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV = 514, 513, 7680, 7424
EVT_VIRTUAL_INC, EVT_VIRTUAL_DEC, EVT_VIRTUAL_MENU = 7680, 7424, 518
EVT_ENTER_BREAK, EVT_EXIT_BREAK = 514, 513
if COLOR then EVT_TOUCH_FIRST, EVT_TOUCH_BREAK, EVT_TOUCH_SLIDE, EVT_TOUCH_TAP = 4097, 4098, 4099, 4100 end
PLAY_NOW = 1
if not COLOR and H == 64 and W == 212 then GREY = function(x) return x * 0x10000 end end

local clock = 0
local sticks = { ail = 0, ele = 0, thr = -1024, rud = 0 }
function getTime() return floor(clock / 10) end
function getValue(id)
  local v = id == 1 and sticks.ail or id == 2 and sticks.ele or id == 3 and sticks.thr or id == 4 and sticks.rud or 0
  if v > 1024 then v = 1024 elseif v < -1024 then v = -1024 end
  return floor(v + 0.5)
end
function getFieldInfo(n)
  local ids = { ail = 1, ele = 2, thr = 3, rud = 4 }
  return ids[n] and { id = ids[n], name = n } or nil
end
function getStickMode() return 1 end
local tones = 0
function playTone() tones = tones + 1 end
function playHaptic() end

-- io in EdgeTX style, on an in-memory SD card
local SD = {}
io = {
  open = function(p, m) if m == "r" and not SD[p] then return nil end return { p = p, m = m, d = (m == "r") and SD[p] or "", pos = 1 } end,
  read = function(f, n) local s = string.sub(f.d, f.pos, f.pos + n - 1) f.pos = f.pos + #s return s end,
  write = function(f, ...) for _, s in ipairs({ ... }) do f.d = f.d .. tostring(s) end end,
  close = function(f) if f.m ~= "r" then SD[f.p] = f.d end end,
}
local DATA = GAME_COLOR and "/SCRIPTS/TOOLS/StickTime.dat" or "/SCRIPTS/TOOLS/StickTimeBW.dat"
-- a version 1 save file of FPV Sim (StickTime's old name): the new script must migrate it
local OLD = GAME_COLOR and "/SCRIPTS/TOOLS/FPVSim.dat" or "/SCRIPTS/TOOLS/FPVSimBW.dat"
SD[OLD] = "FPVSIM 2 1 3 30 100 3 5 1 1 0 4321 9876 5555 11111 0 0\n"

-- lcd with argument checks (what the C API would do)
local stat = { calls = 0, lines = 0, rejected = 0, tris = 0, rows = 0 }
local function num(v, what)
  if type(v) ~= "number" then fail(what .. ": not a number (" .. tostring(v) .. ")") return 0 end
  if v ~= v then fail(what .. ": NaN") return 0 end
  if v > 2147483647 or v < -2147483648 then fail(what .. ": out of int32 range " .. v) return 0 end
  return floor(v)
end
lcd = {}
function lcd.clear() stat.calls = stat.calls + 1 end
function lcd.drawLine(x1, y1, x2, y2, pat, fl)
  stat.calls, stat.lines = stat.calls + 1, stat.lines + 1
  x1, y1, x2, y2 = num(x1, "drawLine x1"), num(y1, "drawLine y1"), num(x2, "drawLine x2"), num(y2, "drawLine y2")
  num(pat, "drawLine pattern")
  if not COLOR then
    if fl == nil then fail("B&W drawLine without flags") end
    if x1 < 0 or y1 < 0 or x2 < 0 or y2 < 0 or x1 > W or x2 > W or y1 > H or y2 > H then stat.rejected = stat.rejected + 1 end
  elseif x1 > W or y1 > H or x2 > W or y2 > H then
    -- luaLcdDrawLine (color): any end beyond the right/bottom edge -> nothing drawn
    stat.rejected = stat.rejected + 1
  end
end
function lcd.drawFilledRectangle(x, y, w, h, f, o)
  stat.calls = stat.calls + 1 num(x, "rect x") num(y, "rect y") num(w, "rect w") num(h, "rect h")
  if not COLOR and (floor(x) < 0 or floor(y) < 0) then fail("B&W filled rect at negative position " .. x .. "," .. y) end
end
function lcd.drawRectangle(x, y, w, h) stat.calls = stat.calls + 1 num(x, "rect x") num(y, "rect y") end
function lcd.drawFilledTriangle(x1, y1, x2, y2, x3, y3, f)
  stat.calls, stat.tris = stat.calls + 1, stat.tris + 1
  local a, b, c = num(y1, "tri y1"), num(y2, "tri y2"), num(y3, "tri y3")
  num(x1, "tri x1") num(x2, "tri x2") num(x3, "tri x3")
  local lo, hi = math.min(a, b, c), math.max(a, b, c)
  if lo < 0 then lo = 0 end
  if hi > H - 1 then hi = H - 1 end
  if hi >= lo then stat.rows = stat.rows + hi - lo + 1 end
  if math.max(a, b, c) - math.min(a, b, c) > 20000 then fail("huge triangle " .. a .. " " .. b .. " " .. c) end
end
function lcd.drawText(x, y, s, f)
  stat.calls = stat.calls + 1 x, y = num(x, "text x"), num(y, "text y")
  if type(s) ~= "string" then fail("text not string") end
  -- the B&W game on a color screen: its menus and HUD must stay on the screen
  if kind == "bwcolor" and (x < 0 or x > W or y < 0 or y > H - 12) then fail("text off the screen at " .. x .. "," .. y .. ": " .. s) end
end
function lcd.drawNumber(x, y, v, f) stat.calls = stat.calls + 1 num(x, "num x") num(y, "num y") num(v, "num v") end
function lcd.sizeText(s, f) return #s * 9, (f and f >= 0x500) and 37 or 19 end
function lcd.RGB(r, g, b) return ((floor(r) * 0 + 1) * 0x10000) + 0x8000 end
STICKTIME_TEST = {}
-- the B&W game's files, as color.lua loads them (the source: the 32-bit core.luac is for radios)
function loadScript(p, mode, e) return loadfile("../sdcard" .. p, "t", e) end

-- ------------------------------------------------------------------- load
-- EdgeTX gives strings no metatable: s:sub() style calls fail on a radio, so here too
debug.setmetatable("", nil)
local chunk, err = loadfile(path)
if not chunk then print("LOAD ERROR " .. err) os.exit(1) end
collectgarbage() collectgarbage()
local mem0 = collectgarbage("count")
local script = chunk()
local T = STICKTIME_TEST
script.init()
collectgarbage()
local memInit = collectgarbage("count")

-- settings and bests migrated from the version 1 file
if T.S.track ~= 2 or T.S.rates ~= 3 or T.S.tilt ~= 30 or T.S.twr ~= 6 or T.S.laps ~= 5 then
  fail(string.format("v1 settings not migrated: track %s rates %s tilt %s twr %s laps %s", T.S.track, T.S.rates, T.S.tilt, T.S.twr, T.S.laps))
end
do
  local l1, r1 = T.best(1)
  local l2, r2 = T.best(2)
  if l1 ~= 4321 or r1 ~= 9876 or l2 ~= 5555 or r2 ~= 11111 then fail("v1 best times not migrated") end
  -- and saved under the new name right away
  local s = SD[DATA]
  if not s or string.sub(s, 1, 7) ~= "FPVSIM2" or not string.find(s, "l1=4321", 1, true) then
    fail("the old save was not written to " .. DATA)
  end
end
local NT = T.info()

local instr = 0
local function counted(f, ...)
  local n = 0
  debug.sethook(function() n = n + 100 end, "", 100)
  local r = f(...)
  debug.sethook()
  return r, n
end

-- FRAME_MS=20 simulates firmware that calls run() faster than stock EdgeTX (50 ms)
local FRAME_MS = tonumber(os.getenv and os.getenv("FRAME_MS") or "") or 50
local FPS = math.floor(1000 / FRAME_MS + 0.5)
local maxInstr, sumInstr, frames, maxRows, sumRows = 0, 0.0, 0, 0, 0.0   -- float sums: 32-bit ints overflow on long runs
local function frame(ev, touch)
  clock = clock + FRAME_MS
  stat.lines, stat.tris, stat.rows = 0, 0, 0
  local ok, r, n = pcall(counted, script.run, ev or 0, touch)
  if not ok then fail("run error: " .. tostring(r)) return 0 end
  frames = frames + 1
  sumInstr = sumInstr + n * 1.0
  if n > maxInstr then maxInstr = n end
  sumRows = sumRows + stat.rows * 1.0
  if stat.rows > maxRows then maxRows = stat.rows end
  return r
end

local function state() local t = { T.get() } return t[16], t end
-- run frames for n * 50 ms of radio time
local function steps(n) for i = 1, math.max(1, math.floor(n * 50 / FRAME_MS + 0.5)) do frame(0) end end

-- ------------------------------------------------------------ autopilot
-- angle mode: steer toward a lead point on the gate axis, hold the aim height
local function autopilot(target)
  local _, s = state()
  local px, py, pz, vx, vy, vz, fx, fy, fz = s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9]
  local ng = target or s[18]
  local cx, cy, cz, nx, ny, nz, k, ax, ay, az = T.gate(ng)
  local d = (px - ax) * nx + (py - ay) * ny + (pz - az) * nz
  if target and d > 0 then nx, nz, d = -nx, -nz, -d end      -- gate rush: either direction counts
  local lead = math.min(14, math.max(0, -d * 0.55))
  local tx, ty, tz = ax - nx * lead, ay - ny * lead, az - nz * lead
  local hd = math.sqrt((px - ax) ^ 2 + (pz - az) ^ 2)
  if k == 3 then
    -- dive gate: arrive 3 m above it, then drop through once centred
    tx, tz = ax, az
    ty = hd > 1.2 and ay + 3 or ay - 4
  end
  local dx, dz = tx - px, tz - pz
  local dist = math.sqrt(dx * dx + dz * dz) + 1e-6
  local hx, hz = fx, fz
  local hl = math.sqrt(hx * hx + hz * hz) + 1e-6
  hx, hz = hx / hl, hz / hl
  local cross = hz * dx - hx * dz
  local dot = hx * dx + hz * dz
  local herr = math.atan2 and math.atan2(cross, dot) or math.atan(cross, dot)
  sticks.rud = math.max(-1, math.min(1, herr * 1.6)) * 1024
  local vf = vx * hx + vz * hz
  local vs = vx * hz - vz * hx
  local vdes = math.min(11, 3 + dist * 0.35)
  if math.abs(herr) > 0.6 then vdes = 3 end
  if k == 3 then vdes = math.min(vdes, hd * 0.6) end
  sticks.ele = math.max(-0.75, math.min(0.75, (vdes - vf) * 0.12)) * 1024
  sticks.ail = math.max(-0.6, math.min(0.6, -vs * 0.15 + herr * 0.25)) * 1024
  local _, twr = T.info()
  local tilt = math.min(0.8, math.abs(sticks.ele / 1024) * 0.9)
  local hover = ((1 / twr - 0.015) / 0.985) ^ (1 / 1.6) / math.cos(tilt)
  local t = hover + (ty - py) * 0.08 - vy * 0.1
  sticks.thr = (math.max(0, math.min(1, t)) * 2 - 1) * 1024
end

local function idleSticks() sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, -1024 end

-- ------------------------------------------------------------ scenarios
-- 1. menus: walk every item, open settings, change every option both ways
local OPTN = GAME_COLOR and 20 or 18
steps(20)
for i = 1, 9 do frame(EVT_VIRTUAL_NEXT) frame(0) end
for i = 1, 9 do frame(EVT_VIRTUAL_PREV) frame(0) end
-- Settings is item 6: from item 1 press NEXT 5 times
for i = 1, 5 do frame(EVT_VIRTUAL_NEXT) end
frame(EVT_VIRTUAL_ENTER)
if state() ~= 2 then fail("settings did not open, state " .. state()) end
for item = 1, OPTN do
  frame(EVT_VIRTUAL_ENTER)
  for j = 1, 3 do frame(EVT_VIRTUAL_INC) end
  for j = 1, 3 do frame(EVT_VIRTUAL_DEC) end
  frame(EVT_VIRTUAL_EXIT)
  frame(EVT_VIRTUAL_NEXT)
end
if T.S.rates ~= 4 then fail("editing a rate value should switch to custom rates (rates " .. T.S.rates .. ")") end
frame(EVT_VIRTUAL_ENTER)   -- on 'Back'
if state() ~= 1 then fail("settings exit did not return to menu, state " .. state()) end
-- track cycling via edit mode on item 5 (focus is back on Settings, item 6)
frame(EVT_VIRTUAL_PREV)
frame(EVT_VIRTUAL_ENTER) frame(EVT_VIRTUAL_INC) frame(EVT_VIRTUAL_INC) frame(EVT_VIRTUAL_INC) frame(EVT_VIRTUAL_ENTER)
if T.S.track ~= 5 then fail("track edit should move 2 -> 5 (track " .. T.S.track .. ")") end
if GAME_COLOR then frame(EVT_TOUCH_TAP, { x = 40, y = 100 }) end   -- tap somewhere in the menu
T.state(1)

-- 2. full autopilot races on every track (angle mode, 3 AI pilots)
local results = {}
T.set("mode", 2)
T.set("laps", 2)
T.set("ai", 3)
T.set("skill", 1)
for track = 1, NT do
  T.track(track)
  T.start(1)
  idleSticks()
  local t0 = clock
  local done = false
  for f = 1, FPS * 260 do
    local st = state()
    if st == 4 then autopilot() else idleSticks() end
    if st == 8 then done = true break end
    frame(0)
  end
  local lg, lapStart, nl, laps, total, crashes = T.race()
  local _, _, _, pos, nai = T.info()
  local aiDone = 0
  for a = 1, nai do
    local _, _, _, k, d = T.ai(a)
    if d > 0 then aiDone = aiDone + 1 end
  end
  local name = select(11, T.info())
  results[#results + 1] = { track = track, name = name, done = done, laps = nl, total = total, crashes = crashes,
    secs = (clock - t0) / 1000, lap1 = laps[1], lap2 = laps[2], pos = pos, nai = nai, aiDone = aiDone }
  if not done then fail("track " .. track .. ": race not finished (laps " .. nl .. ", last gate " .. lg .. ", crashes " .. crashes .. ")") end
  if crashes > 0 then fail("track " .. track .. ": autopilot crashed " .. crashes .. " times") end
  -- let the AI pilots finish, the result screen keeps the player's place
  steps(20 * 60)
  frame(EVT_VIRTUAL_EXIT)
  frame(0)
end
T.set("ai", 0)

-- 3. acro stress: random sticks, crashes, respawns, pause/resume/restart in every mode
T.set("mode", 1)
T.set("wind", 2)
T.set("wash", 1)
T.set("quad", 2)
T.track(7)
local seed = 7
local function rnd() seed = (seed * 16807) % 2147483647 return seed / 2147483647 end
for m = 2, 4 do
  T.start(m)
  for f = 1, 1200 do
    if f % 40 == 0 then
      sticks.ail, sticks.ele, sticks.rud = (rnd() * 2 - 1) * 1024, (rnd() * 2 - 1) * 1024, (rnd() * 2 - 1) * 800
      sticks.thr = (rnd() * 1.6 - 0.6) * 1024
    end
    local ev = 0
    if f == 300 then ev = EVT_VIRTUAL_EXIT end            -- pause
    if f == 305 then ev = EVT_VIRTUAL_NEXT end
    if f == 306 then ev = EVT_VIRTUAL_NEXT end
    if f == 307 then ev = EVT_VIRTUAL_ENTER end           -- settings from pause
    if f == 310 then ev = EVT_VIRTUAL_EXIT end            -- back to pause
    if f == 312 then ev = EVT_VIRTUAL_EXIT end            -- resume
    if GAME_COLOR and f == 500 then frame(EVT_TOUCH_TAP, { x = floor(W / 2), y = 10 }) end
    frame(ev)
  end
end
T.set("wind", 0)
T.set("wash", 0)
T.set("quad", 1)
-- poses: straight up, straight down, inverted, inside a gate, inside a wall
for _, p in ipairs({ { 0, 5, 0, 0, 90, 0 }, { 0, 5, 0, 0, -90, 0 }, { 0, 5, 0, 45, 0, 180 }, { 0, 1.35, 0, 0, 0, 0 },
                     { 0, 1.35, -0.3, 0, 0, 90 }, { 0, 3, 34, 0, 0, 0 }, { 46, 10, 63, 90, 0, 0 }, { 30, 2, 20, 200, -10, 30 } }) do
  T.state(4)
  T.pose(p[1], p[2], p[3], p[4], p[5], p[6])
  idleSticks()
  frame(0)
end

-- 4. dive gate: drop straight through it from above (track 3, gate 5)
T.track(3)
T.start(2)
steps(70)
T.state(4)
T.next(5)
local gx5, gy5, gz5 = T.gate(5)
T.pose(gx5, gy5 + 3, gz5, 0, 0, 0)
idleSticks()
steps(30)
local _, s5 = state()
if s5[18] ~= 6 then fail("dive gate not registered (next gate " .. s5[18] .. ", state " .. s5[16] .. ")") else print("dive gate: pass registered") end
T.state(4)
T.next(5)
T.pose(gx5 + 2.1, gy5 + 3, gz5, 0, 0, 0)
steps(30)
if state() ~= 5 and state() ~= 6 then fail("hitting the dive gate frame should crash (state " .. state() .. ")") else print("dive gate frame: crash registered") end

-- 5. flags and hoops: wrong side of a flag does not count, the hoop rim crashes
T.track(4)
T.start(2)
steps(70)
do
  local cx, cy, cz, nx, ny, nz, k, ax, ay, az = T.gate(2)      -- flag, pass on its right (+x)
  local pole = cx - 6
  T.state(4) T.next(2)
  T.pose(pole - 3, 2, cz - 3, 0, 0, 0) T.vel(0, 0, 8)
  sticks.thr = -150
  steps(12)
  local _, s = state()
  if s[18] ~= 2 then fail("passing a flag on the wrong side should not count") end
  T.state(4) T.next(2)
  T.pose(pole + 3, 2, cz - 3, 0, 0, 0) T.vel(0, 0, 8)
  steps(12)
  _, s = state()
  if s[18] ~= 3 then fail("passing a flag on the right side should count (next " .. s[18] .. ")") else print("flag: sides checked") end
  cx, cy, cz = T.gate(6)                                        -- hoop
  T.state(4) T.next(6)
  T.pose(cx + 1.3, cy, cz - 3, 0, 0, 0) T.vel(0, 0, 8)
  steps(12)
  if state() ~= 5 and state() ~= 6 then fail("hitting the hoop rim should crash (state " .. state() .. ")") else print("hoop rim: crash registered") end
end
idleSticks()

-- 6a. a fast roll that stops (Fast rates, racer): the camera is drawn ahead to hide the screen's
-- delay, but must not overshoot where the quad stops and swing back
do
  local atan2 = math.atan2 or math.atan
  T.track(1) T.set("rates", 3) T.set("quad", 1) T.start(2)
  steps(8)
  T.state(4)
  T.pose(0, 60, 0, 0, 0, 0) T.vel(0, 0, 0)
  sticks.thr, sticks.ele, sticks.rud, sticks.ail = 0, 0, 0, 1024
  local function roll(rx_, ry_, last)
    local a = atan2(-ry_, rx_)
    while last and a - last > math.pi do a = a - 2 * math.pi end
    while last and a - last < -math.pi do a = a + 2 * math.pi end
    return a
  end
  local cam, body, peak = nil, nil, -1e9
  for i = 1, 26 do
    if i == 13 then sticks.ail = 0 end
    frame(0)
    local crx, cry = T.cam()
    cam = roll(crx, cry, cam)
    local s = { T.get() }
    body = roll(s[13], s[14], body)
    if i >= 6 and cam > peak then peak = cam end
  end
  local back = math.deg(peak - body)
  if state() ~= 4 then fail("roll check: the quad should still be flying (state " .. state() .. ")")
  elseif back > 10 then fail(string.format("the camera swings back %.1f deg when a fast roll stops", back))
  else print(string.format("fast roll stop: camera swings back %.1f deg", math.max(0, back))) end
  T.set("rates", 2)
  idleSticks()
end

-- 6. freestyle: flips, rolls and a gap shot score a combo
T.track(7)
T.set("mode", 1)
T.start(3)
steps(8)
T.state(4)
T.pose(-20, 25, -20, 45, 0, 0)
sticks.thr, sticks.ele, sticks.ail, sticks.rud = 200, 1024, 0, 0     -- full back pitch: back flips
steps(14)
sticks.ele, sticks.ail = 0, 1024                                     -- full roll right
steps(14)
sticks.ail = 0
local _, _, _, _, _, sc, _, _, chn = T.info()
if chn < 2 then fail("freestyle: flips and rolls should build a combo (tricks " .. chn .. ")") end
T.pose(-20, 25, -20, 45, 0, 0)
idleSticks()
sticks.thr = 0
steps(80)
_, _, _, _, _, sc, _, _, chn = T.info()
if sc <= 0 then fail("freestyle: the combo should be banked into the score") else print("freestyle: score " .. sc) end
-- gap shot through the ruin door
do
  local cx, cy, cz = T.gate(2)
  T.state(4)
  T.pose(cx, cy, cz - 4, 0, 0, 0) T.vel(0, 0, 9)
  sticks.thr = 0
  steps(6)
  _, _, _, _, _, sc, _, _, chn = T.info()
  if chn < 1 then fail("freestyle: flying through a gap should count as a trick") end
end
idleSticks()

-- 7. gate rush: the autopilot chases random gates until the clock runs out
T.track(1)
T.set("mode", 2)
T.start(4)
local rushDone = false
for f = 1, FPS * 240 do
  local st, s = state()
  if st == 4 then autopilot(s[18]) else idleSticks() end
  if st == 8 then rushDone = true break end
  frame(0)
end
local _, _, _, _, _, _, rn = T.info()
if not rushDone then fail("gate rush did not end") end
if rn < 3 then fail("gate rush: only " .. rn .. " gates") else print("gate rush: " .. rn .. " gates") end
frame(EVT_VIRTUAL_EXIT)
frame(0)

-- 8. persistence round trip
local saved = SD[DATA]
if not saved or string.sub(saved, 1, 7) ~= "FPVSIM2" then fail("nothing saved in the v2 format") end

-- exit from menu
T.state(1)
local r = frame(EVT_VIRTUAL_EXIT)
if r ~= 1 then fail("EXIT in main menu should quit (got " .. tostring(r) .. ")") end
if stat.rejected > 0 then fail(stat.rejected .. " lines would be rejected by the firmware") end

collectgarbage()
print(string.format("%s %s %dx%d  frames %d  instr/frame (incl. mock lcd) avg %d max %d  tri rows avg %d max %d  rejected lines %d",
  _VERSION, kind, W, H, frames, math.floor(sumInstr / frames), maxInstr, math.floor(sumRows / frames), maxRows, stat.rejected))
print(string.format("memory: script loaded+init %.1f KB, now %.1f KB", memInit - mem0, collectgarbage("count") - mem0))
for _, r in ipairs(results) do
  print(string.format("track %d %-12s finished=%s laps=%d total=%.2fs lap1=%.2f lap2=%.2f crashes=%d place %d/%d, AI finished %d (sim %.0fs)",
    r.track, r.name, tostring(r.done), r.laps, (r.total or 0) / 100, (r.lap1 or 0) / 100, (r.lap2 or 0) / 100, r.crashes or -1,
    r.pos, r.nai + 1, r.aiDone, r.secs))
end
print("saved: " .. string.gsub(tostring(saved), "\n", ""))
print(fails == 0 and "ALL OK" or (fails .. " FAILURES"))
