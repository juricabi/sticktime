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
PLAY_NOW, PLAY_BACKGROUND = 0x10, 0x20         -- EdgeTX's values
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
function getStickMode() return 2 end      -- EdgeTX 3.0+: the mode, 1 to 4
local tones = 0
function playTone() tones = tones + 1 end
local buzz = 0
function playHaptic() buzz = buzz + 1 end

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
SD[OLD] = "FPVSIM 2 1 3 30 100 2 5 1 1 0 4321 9876 5555 11111 0 0\n"

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
-- the B&W game's files, as color.lua loads them (the source: the 32-bit core.luac is for radios).
-- As on EdgeTX, a third argument (env) leaves the chunk with no globals at all: api_general.cpp
-- clears the stack before it reads the argument.
-- StickTime BW's core is its test build (build/, with the STICKTIME_TEST hooks; the shipped one
-- has none)
function loadScript(p, mode, ...)
  local f = string.find(p, "StickTimeBW/core.lua", 1, true) and "build/sticktime_bw_test.lua" or "../sdcard" .. p
  if select("#", ...) > 0 then return loadfile(f, "t", nil) end
  return loadfile(f, "t")
end

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
-- (the old 4:1 is below the racer's Power range: it comes back as Stock)
if T.S.track ~= 2 or T.S.rates ~= 3 or T.S.tilt ~= 30 or T.S.twr ~= 0 or T.S.laps ~= 5 then
  fail(string.format("v1 settings not migrated: track %s rates %s tilt %s twr %s laps %s", T.S.track, T.S.rates, T.S.tilt, T.S.twr, T.S.laps))
end
do
  local l1, r1 = T.best(1)
  local l2, r2 = T.best(2)
  -- (Meadow's are not: its layout is new since 1.7.0)
  if l1 ~= 0 or r1 ~= 0 or l2 ~= 5555 or r2 ~= 11111 then fail("v1 best times not migrated") end
  -- and saved under the new name right away
  local s = SD[DATA]
  if not s or string.sub(s, 1, 7) ~= "FPVSIM2" or not string.find(s, "l2=5555", 1, true) then
    fail("the old save was not written to " .. DATA)
  end
end
T.set("twr", 6)                                  -- the tests below fly at 6:1, the default
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
-- stick (0..1) that gives `load` times the weight in thrust: inverse of the quad's thrust curve
function hoverStick(load)
  local twr, i0, n, dz, tk = T.thrust()
  local r, lo, hi = math.max(0, (load / twr - i0) / (1 - i0)), 0, 1
  for _ = 1, 40 do                      -- (1 - tk) x^n + tk x^8 rises with x: bisect
    local x = (lo + hi) / 2
    if (1 - tk) * x ^ n + tk * x ^ 8 < r then lo = x else hi = x end
  end
  return dz + (1 - dz) * hi
end

-- angle mode: steer toward a lead point on the gate axis, hold the aim height
local function autopilot(target)
  local _, s = state()
  local px, py, pz, vx, vy, vz, fx, fy, fz = s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9]
  local ng = target or s[18]
  local cx, cy, cz, nx, ny, nz, k, ax, ay, az = T.gate(ng)
  local d = (px - ax) * nx + (py - ay) * ny + (pz - az) * nz
  if target and d > 0 then nx, nz, d = -nx, -nz, -d end      -- gate rush: either direction counts
  local lead = math.min(14, math.max(0, -d * 0.55))
  -- swung wide past the gate plane: go round and come back square to it, not edge-on
  if d > 0 and not target then lead = 8 end
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
  -- too high for a frame or hoop (the low gate of a split-S): slow enough to sink to it in time
  if k < 6 and k ~= 3 and py - ty > 0.7 then vdes = math.min(vdes, math.max(0.5, 2 * hd / (py - ty))) end
  sticks.ele = math.max(-0.75, math.min(0.75, (vdes - vf) * 0.12)) * 1024
  sticks.ail = math.max(-0.6, math.min(0.6, -vs * 0.15 + herr * 0.25)) * 1024
  local tilt = math.min(0.8, math.abs(sticks.ele / 1024) * 0.9)
  local hover = hoverStick(1 / math.cos(tilt))
  -- height: stiff enough to hold a gate's height when the wind's translational lift shifts the hover
  local t = hover + (ty - py) * 0.15 - vy * 0.15
  sticks.thr = (math.max(0, math.min(1, t)) * 2 - 1) * 1024
end

local function idleSticks() sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, -1024 end

-- ------------------------------------------------------------ scenarios
-- 1. menus: walk every item, open settings, change every option both ways
local OPTN = GAME_COLOR and 24 or 21
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
  if track == 1 then
    -- the end screen: the wheel moves from Again to Menu, ENTER takes it
    frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)
    if state() ~= 1 then fail("end screen: wheel and ENTER should open the menu (state " .. state() .. ")") end
  elseif track == 2 then
    -- ENTER on Again (where the end screen starts) races again
    frame(EVT_VIRTUAL_ENTER)
    if state() ~= 3 then fail("end screen: ENTER should race again (state " .. state() .. ")") end
    T.state(1)
  else
    frame(EVT_VIRTUAL_EXIT)
  end
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
    if f == 307 then ev = EVT_VIRTUAL_NEXT end
    if f == 308 then ev = EVT_VIRTUAL_ENTER end           -- settings from pause
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

-- 4. dive gate: drop straight through it from above (track 3, gate 6)
T.track(3)
T.start(2)
steps(70)
T.state(4)
T.next(6)
local gx5, gy5, gz5 = T.gate(6)
T.pose(gx5, gy5 + 3, gz5, 0, 0, 0)
idleSticks()
steps(30)
local _, s5 = state()
if s5[18] ~= 7 then fail("dive gate not registered (next gate " .. s5[18] .. ", state " .. s5[16] .. ")") else print("dive gate: pass registered") end
T.state(4)
T.next(6)
T.pose(gx5 + 2.1, gy5 + 3, gz5, 0, 0, 0)
steps(30)
do
  local st, s = state()
  if st ~= 4 or s[18] ~= 6 or s[2] < gy5 then
    fail(string.format("the dive gate frame should stop the quad on top (state %d, next gate %d, %.2f m over it)", st, s[18], s[2] - gy5))
  else print(string.format("dive gate frame: the quad stops on it (%.2f m over the gate)", s[2] - gy5)) end
end

-- 4b. the next gate's marker turns green when lined up to go through it (the color game): a hoop
-- from in front within 70 deg, heading within 70 deg of the way through and pointed at it (not
-- turned away, not beside it heading past, not from behind or far to the side); a flag before it
-- on its free side, any heading; a dive gate from above
if GAME_COLOR then
  local atan2 = math.atan2 or math.atan
  local function deg(nx, nz) return atan2(nx, nz) * 57.29578 end
  local function at(i, back, side, up, turn)
    local _, _, _, nx, ny, nz, _, ax, ay, az = T.gate(i)
    local rx, rz = nz, -nx
    T.pose(ax - nx * back + rx * side, ay - ny * back + (up or 0), az - nz * back + rz * side, deg(nx, nz) + (turn or 0), 0, 0)
    return T.lined(i)
  end
  T.track(4)
  T.start(2)
  steps(5)
  local hoop = { at(6, 8, 0, 0, 10), at(6, 4, 8, 0, -63.4), at(6, 8, 0, 0, 180), at(6, 8, 0, 0, 40), at(6, -8, 0), at(6, 3, 9), at(6, 4, 8) }
  local flag = { at(2, 6, 0), at(2, 6, 0, 0, 120), at(2, -6, 0) }
  do                                                            -- beyond the pole: the flag's wrong side
    local fx, _, fz, nx, _, nz, _, ax, ay, az = T.gate(2)
    T.pose(ax - (fx - ax) * 5 / 3.5 - nx * 6, ay, az - (fz - az) * 5 / 3.5 - nz * 6, deg(nx, nz), 0, 0)
    flag[4] = T.lined(2)
  end
  if not (hoop[1] and hoop[2] and not hoop[3] and not hoop[4] and not hoop[5] and not hoop[6] and not hoop[7] and flag[1] and flag[2] and not flag[3] and not flag[4]) then
    fail("lined up: hoop " .. table.concat({ tostring(hoop[1]), tostring(hoop[2]), tostring(hoop[3]), tostring(hoop[4]), tostring(hoop[5]), tostring(hoop[6]), tostring(hoop[7]) }, " ") ..
      ", flag " .. tostring(flag[1]) .. " " .. tostring(flag[2]) .. " " .. tostring(flag[3]) .. " " .. tostring(flag[4]))
  end
  T.track(3)
  T.start(2)
  steps(5)
  local gx, gy, gz = T.gate(6)                                  -- the dive gate
  T.pose(gx, gy + 4, gz, 0, 0, 0)
  local above = T.lined(6)
  T.pose(gx, gy + 4, gz, 135, 0, 0)
  local turned = T.lined(6)
  T.pose(gx + 8, gy + 1, gz, 0, 0, 0)
  local side = T.lined(6)
  T.pose(gx, gy - 3, gz, 0, 0, 0)
  local below = T.lined(6)
  if not (above and turned and not side and not below) then
    fail("lined up: dive gate " .. tostring(above) .. " " .. tostring(turned) .. " " .. tostring(side) .. " " .. tostring(below))
  else print("next gate marker: green when lined up and pointed at it (hoop, flag on its free side, dive gate; not from behind, far to the side, beside it or turned away)") end
  -- flown along the racing line at 15 m/s, every gate of the eight tracks is green on its final
  -- approach (the last fifth of the leg into it)
  local late = {}
  for t = 1, 8 do
    T.track(t)
    T.start(2)
    steps(2)
    local ng = T.ng()
    for j = 1, ng do
      local i = (j - 2) % ng + 1
      for q = 16, 19 do
        local s = q / 20
        local x, y, z = T.line(i, s)
        local x0, _, z0 = T.line(i, s - 0.01)
        local x1, _, z1 = T.line(i, s + 0.01)
        local tx, tz = x1 - x0, z1 - z0
        local l = math.sqrt(tx * tx + tz * tz) + 1e-6
        T.pose(x, y, z, deg(tx, tz), 0, 0)
        T.vel(tx / l * 15, 0, tz / l * 15)
        if not T.lined(j) then late[#late + 1] = t .. ":" .. j .. "@" .. s break end
      end
    end
  end
  T.vel(0, 0, 0)
  if #late > 0 then fail("next gate marker not green on the racing line's final approach: " .. table.concat(late, " "))
  else print("next gate marker: green on every final approach of the racing line, all eight tracks") end
end

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
  local st, s = state()
  if st ~= 4 or s[18] ~= 6 or s[3] > cz or s[6] > 1 then
    fail(string.format("the hoop rim should stop the quad in front of it (state %d, next gate %d, %.2f m past it, %.1f m/s on)", st, s[18], s[3] - cz, s[6]))
  else print("hoop rim: the quad stops in front of it") end
end
idleSticks()

-- 5b. ground effect: at the throttle that holds a hover high up, the quad rises near the ground
do
  local mode, twr = T.S.mode, T.S.twr
  T.set("mode", 2) T.set("twr", 5)
  local hover = (hoverStick(1) * 2 - 1) * 1024
  local function vyAfter(y)
    T.track(1) T.start(2) steps(70) T.state(4)
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
  if stLow ~= 4 or stHigh ~= 4 or not (vLow > vHigh + 0.05) then fail("no ground effect near the ground") end
  T.set("mode", mode) T.set("twr", twr)
  idleSticks()
end

-- 5d. flips (the airmode mixer): at full throttle the motors' differential drops the collective, so a
-- full-stick flip ends lower than without it; near hover it lifts it
do
  local mode, rates = T.S.mode, T.S.rates
  T.set("mode", 1) T.set("rates", 2)              -- Acro, Normal rates: 600 deg/s, one turn in 0.6 s
  local function flip(thr, am)
    T.track(1) T.start(2) steps(70) T.state(4)
    local old = T.qp("am", am)
    local _, s0 = state()
    T.pose(s0[1], 80, s0[3], 0, 0, 0) T.vel(0, 0, 0)
    sticks.ail, sticks.ele, sticks.rud, sticks.thr = 1024, 0, 0, thr
    steps(12)                                      -- 0.6 s of full roll: about one turn
    sticks.ail = 0
    steps(6)
    local st, s = state()
    T.qp("am", old)
    return s[2] - 80, st
  end
  local am, hover = T.qp("am"), (hoverStick(1) * 2 - 1) * 1024
  local fW, s1 = flip(1024, am)
  local fO, s2 = flip(1024, 0)
  local hW, s3 = flip(hover, am)
  local hO, s4 = flip(hover, 0)
  print(string.format("flips: full throttle %+.2f m (%+.2f without the mixer), hover throttle %+.2f m (%+.2f without)", fW, fO, hW, hO))
  if s1 ~= 4 or s2 ~= 4 or s3 ~= 4 or s4 ~= 4 or not (fW < fO - 0.15 and hW > hO + 0.05) then
    fail("flips don't shift the thrust as an airmode mixer")
  end
  T.set("mode", mode) T.set("rates", rates)
  idleSticks()
end

-- 5c. Vibration: a hard landing buzzes once when it is on, none when it is off (and flies on)
do
  local vib = T.S.vib
  T.track(1) T.start(2) steps(70) T.state(4)
  local _, s0 = state()
  idleSticks()
  for v = 1, 0, -1 do
    T.set("vib", v)
    T.state(4) T.pose(s0[1], 3, s0[3], 0, 0, 0) T.vel(0, -15, 0)
    local b = buzz
    steps(6)
    if state() ~= 4 then fail("a hard landing should not end the flight (state " .. state() .. ")") end
    if (buzz > b) ~= (v == 1) then fail("Vibration " .. (v == 1 and "on" or "off") .. ": " .. (buzz - b) .. " buzzes on a hard landing") end
  end
  print("vibration: buzz on a hard landing only with Vibration on")
  T.set("vib", vib)
  idleSticks()
end

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

-- 7. gate rush: the autopilot chases random gates until the clock runs out (the same gates
-- every run: the random numbers start where they do when the script loads)
T.track(1)
T.set("mode", 2)
T.seed(7)
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

-- 9. a save from before layout 2 (flag sides swapped on the Slalom and the Grand Prix) loses
-- those tracks' lap and race bests and keeps everything else; one from before layout 3 (new
-- Meadow, Dive Tower, Hoop Forest and Grand Prix) loses theirs; a layout 3 save keeps them all
for _, c in ipairs({ { "", 0, 0, 0 }, { "lay=2 ", 5000, 12000, 0 }, { "lay=3 ", 5000, 12000, 1 } }) do
  SD[DATA] = "FPVSIM2 " .. c[1] .. "track=4 l1=4321 r1=9876 l4=5000 r4=12000 g4=9 f4=300 l6=7000 r6=15000 l2=3000 f1=50\n"
  STICKTIME_TEST = {}
  chunk().init()
  local L = STICKTIME_TEST
  local a1, a2, _, a4 = L.best(1)
  local b1, b2, b3, b4 = L.best(4)
  local c1, c2 = L.best(6)
  local k = c[4] == 1
  if L.S.track ~= 4 or a1 ~= (k and 4321 or 0) or a2 ~= (k and 9876 or 0) or a4 ~= 50 or L.best(2) ~= 3000
    or b1 ~= c[2] or b2 ~= c[3] or b3 ~= 9 or b4 ~= 300 or c1 ~= (k and 7000 or 0) or c2 ~= (k and 15000 or 0) then
    fail(string.format("layout %s save: bests %s %s %s / %s %s %s %s / %s %s", c[1], a1, a2, a4, b1, b2, b3, b4, c1, c2))
  end
end


-- 11. medals: Bronze, Silver and Gold are the Easy, Medium and Hard AI pilot's lap; the AI flies
-- its second lap within a few percent of that (its pilots are up to 2% faster or slower)
do
  local out = {}
  T.set("ai", 1)
  T.set("laps", 2)
  for _, track in ipairs({ 1, 4, 8 }) do
    T.track(track)
    local m1, m2, m3, medal = T.medals()
    if not (m3 > 0 and m3 < m2 and m2 < m1) then fail(string.format("medals: track %d times out of order (%s %s %s)", track, m1, m2, m3)) end
    if medal(m3) ~= 3 or medal(m3 + 1) ~= 2 or medal(m1) ~= 1 or medal(m1 + 1) ~= 0 or medal(0) ~= 0 then
      fail("medals: wrong medal for a lap time on track " .. track)
    end
    local s = { "track " .. track }
    for skill = 1, 3 do
      T.set("skill", skill)
      T.start(1)
      idleSticks()
      local ng = select(19, T.get())
      local t1, t2
      for _ = 1, FPS * 240 do
        frame(0)
        local k = select(4, T.ai(1))
        local gt = select(20, T.get())
        if k == ng + 1 and not t1 then t1 = gt end
        if k == 2 * ng + 1 then t2 = gt break end
      end
      local m = ({ m1, m2, m3 })[skill]
      if not t2 then fail("medals: the AI didn't finish 2 laps on track " .. track)
      elseif math.abs((t2 - t1) / m - 1) > 0.04 then
        fail(string.format("medals: track %d skill %d: AI lap %.2f s, medal %.2f s", track, skill, (t2 - t1) / 100, m / 100))
      end
      s[#s + 1] = string.format("%.2f/%.2f", ((t2 or 0) - (t1 or 0)) / 100, m / 100)
      T.state(1)
      frame(0)
    end
    out[#out + 1] = table.concat(s, " ")
  end
  T.set("ai", 0)
  print("medals (AI lap/medal, easy medium hard): " .. table.concat(out, ", "))
end

-- 12. contacts: nothing forces a respawn. A wall scraped at a shallow angle slows the quad a little,
-- one hit head-on stops it dead and knocks it about (a prop strike); upside down on the ground it
-- can't take off, a roll stick flips it back over (turtle mode); the pause menu respawns it
do
  local mode = T.S.mode
  T.set("mode", 2)
  local hover = (hoverStick(1) * 2 - 1) * 1024
  T.track(7) T.start(2) steps(70)
  local x0, x1, y0, y1, z0, z1 = T.box(1)                       -- a wall 8 m long along x, 0.5 m thick
  local ym = math.min(y1 - 0.8, 2.5)
  -- scrape: 5 m/s along its south face, 1.2 m/s into it
  T.state(4) T.pose(x0 + 1, ym, z0 - 0.3, 90, 0, 0) T.vel(5, 0, 1.2)
  sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, hover
  steps(8)
  local st, s = state()
  local sp = math.sqrt(s[4] ^ 2 + s[6] ^ 2)
  if st ~= 4 or s[3] > z0 - 0.14 or sp < 3 or T.stun() > 0 or s[1] > x1 then
    fail(string.format("a scrape along a wall: state %d, %.2f m into the wall, %.1f m/s left, stun %.2f", st, s[3] - z0 + 0.15, sp, T.stun()))
  end
  print(string.format("wall scrape: flies on at %.1f m/s", sp))
  -- head on at 20 m/s
  local c0 = select(6, T.race())
  T.state(4) T.pose((x0 + x1) / 2, ym, z0 - 2, 0, 0, 0) T.vel(0, 0, 20)
  steps(4)
  st, s = state()
  local st2 = T.stun()
  if st ~= 4 or s[3] > z0 - 0.14 or s[6] > 0.5 or select(6, T.race()) ~= c0 + 1 or st2 <= 0 then
    fail(string.format("a head-on hit at 20 m/s: state %d, %.2f m into the wall, %.1f m/s on, hits %d, stun %.2f",
      st, s[3] - z0 + 0.15, s[6], select(6, T.race()) - c0, st2))
  end
  steps(40)
  st, s = state()
  if st ~= 4 and st ~= 6 then fail("after a head-on hit the quad should still be flying (state " .. st .. ")") end
  print(string.format("head-on hit at 20 m/s: stopped at the wall, still flying 2 s later (%.1f m up)", s[2]))
  -- a level landing at 3 m/s is no prop strike (the skids take it), the same tilted 45 deg is
  T.track(1) T.start(2) steps(70)
  local _, s9 = state()
  T.set("mode", 1)                                 -- (Acro: Angle mode would level it on the way down)
  for _, c in ipairs({ { 0, false }, { 45, true } }) do
    T.state(4) T.pose(s9[1] + 3, 0.6, s9[3], 0, 0, c[1]) T.vel(0, -3, 0)
    idleSticks()
    local h0, struck = select(6, T.race()), false
    for _ = 1, math.floor(FPS * 0.25 + 0.5) do                 -- 0.25 s: down from 0.6 m
      frame(0)
      if T.stun() > 0 then struck = true end
    end
    if struck ~= c[2] or (select(6, T.race()) > h0) ~= c[2] then
      fail(string.format("a landing at 3 m/s rolled %d deg: prop strike %s, should be %s", c[1], tostring(struck), tostring(c[2])))
    end
  end
  -- turtle: upside down on the ground, full throttle doesn't lift it, a roll stick flips it over
  T.track(1) T.start(2) steps(70)
  local _, s0 = state()
  T.state(4) T.pose(s0[1] + 3, 0.15, s0[3], 0, 0, 180)
  sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, 1024
  steps(10)
  st, s = state()
  if st ~= 4 or s[2] > 0.3 or s[11] > 0 then fail(string.format("upside down on the ground it should stay there (state %d, %.2f m up, up %.2f)", st, s[2], s[11])) end
  sticks.thr, sticks.ail = -1024, 1024
  steps(24)
  sticks.ail = 0
  steps(2)
  st, s = state()
  if s[11] < 0.99 then fail(string.format("turtle: a roll stick should flip it back over (up %.2f)", s[11])) end
  sticks.thr = 1024
  steps(10)
  st, s = state()
  if st ~= 4 or s[2] < 1.5 then fail(string.format("after the turtle it should take off (%.2f m up)", s[2])) end
  print("turtle: flipped back over with the roll stick and took off")
  -- the pause menu's Respawn: back at the last gate, ready to go
  T.next(3)
  frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)
  st, s = state()
  local _, _, _, _, _, _, _, ax, ay, az = T.gate(2)
  local dd = math.sqrt((s[1] - ax) ^ 2 + (s[3] - az) ^ 2)
  if st ~= 6 or dd > 3 then fail(string.format("pause, Respawn: should be ready at gate 2 (state %d, %.1f m away)", st, dd)) end
  print("pause menu: Respawn puts the quad back at the last gate")
  idleSticks()
  T.set("mode", mode)
end

-- 13. ghost (Practice): the first lap becomes the ghost, saved on the SD card (a faster lap would
-- replace it); the ghost flies along with the next lap near the quad; a new start loads it; another
-- track's file is not taken; Ghost Off records nothing. (The color game only)
if GAME_COLOR then
  local mode = T.S.mode
  T.set("mode", 2)
  T.track(1) T.start(2)
  idleSticks()
  local gmax, gfile = select(10, T.ghost())
  local path = gfile .. "1.txt"
  SD[path] = nil
  local laps, near, far, seen = {}, 0, 0, 0
  for _ = 1, FPS * 120 do
    local st, s = state()
    if st == 4 then autopilot() else idleSticks() end
    frame(0)
    local n, iv, lap, on, gx, gy, gz = T.ghost()
    local nl = select(3, T.race())
    if nl >= 1 and on then
      seen = seen + 1
      local d = math.sqrt((gx - s[1]) ^ 2 + (gy - s[2]) ^ 2 + (gz - s[3]) ^ 2)
      if d < 15 then near = near + 1 else far = far + 1 end
    end
    if nl >= 2 then break end
  end
  frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_EXIT)    -- a pause: the saves wait for a break
  local _, _, nl, lt = T.race()
  local n, iv, glap = T.ghost()
  local best = math.min(lt[1] or 1e9, lt[2] or 1e9)
  if nl < 2 then fail("ghost: the autopilot should fly 2 practice laps (" .. nl .. ")")
  elseif n < 2 or n > gmax or glap ~= best then
    fail(string.format("ghost: %d samples (max %d), its lap %s, the best of %s %s %s", n, gmax, tostring(glap), lt[1], lt[2], lt[3]))
  end
  if not SD[path] or #SD[path] ~= 49 + n * 9 then fail("ghost: not saved as " .. path .. " (" .. (SD[path] and #SD[path] or 0) .. " bytes)") end
  if seen < FPS * 10 or near < seen * 0.8 then fail(string.format("ghost: shown %d frames, within 15 m of the quad %d of them", seen, near)) end
  print(string.format("ghost: laps %.2f %.2f s, the ghost %d samples every %.1f s (%.2f s lap), within 15 m of the quad %d%% of the time",
    (lt[1] or 0) / 100, (lt[2] or 0) / 100, n, iv / 100, glap / 100, math.floor(near * 100 / math.max(1, seen))))
  -- a new start reads it back
  local saved = SD[path]
  local inst2
  STICKTIME_TEST = {}
  inst2 = chunk()
  inst2.init()
  local L = STICKTIME_TEST
  L.track(1) L.start(2)
  local n2, iv2, lap2 = L.ghost()
  if n2 ~= n or iv2 ~= iv or lap2 ~= glap then fail(string.format("ghost: read back %d samples / %s / %s, saved %d / %s / %s", n2, iv2, lap2, n, iv, glap)) end
  -- another track's file (other gates) is not this track's ghost
  SD[gfile .. "2.txt"] = saved
  L.track(2) L.start(2)
  if L.ghost() ~= 0 then fail("ghost: another track's ghost was taken") end
  SD[gfile .. "2.txt"] = nil
  STICKTIME_TEST = T
  -- Ghost Off: nothing recorded
  SD[path] = nil
  T.set("ghost", 0)
  T.track(1) T.start(2)
  for _ = 1, FPS * 70 do
    local st = state()
    if st == 4 then autopilot() else idleSticks() end
    frame(0)
    if select(3, T.race()) >= 1 then break end
  end
  if SD[path] or T.ghost() ~= 0 then fail("ghost: recorded with Ghost Off") end
  T.set("ghost", 1)
  idleSticks()
  T.set("mode", mode)
end

-- 14. battery: Off changes nothing; a fresh pack flies as without it (Betaflight's sag compensation)
-- and a drained one loses thrust on a punch; it runs down only while flying; at the end of a pack it
-- warns, limps, then the motors stop and EMPTY ends the flight without counting a crash, with a fresh
-- pack; a hit keeps the pack, Respawn brings a fresh one; 2x has twice the capacity
do
  local quad, twr, mode = T.S.quad, T.S.twr, T.S.mode
  T.track(1) T.set("mode", 2) T.set("quad", 1) T.set("twr", 0)
  local function fly(b)
    idleSticks()
    T.set("batt", b) T.start(2) steps(70) T.state(4)
  end
  local function hold(thr, n)                    -- n frames 60 m up at this throttle (never crashes)
    for _ = 1, n do
      T.pose(0, 60, 0, 0, 0, 0)
      sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, thr
      frame(0)
    end
  end
  local function punch(b, s)                     -- 1 s of full throttle from 60 m: the thrust, a share of full
    fly(b)
    if s then T.bat("s", s) end
    T.pose(0, 60, 0, 0, 0, 0) T.vel(0, 0, 0)
    sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, 1024
    steps(20)
    return select(4, T.audio())
  end
  local fOff = punch(0)
  if T.bat("s") ~= 1 then fail("battery Off: the pack ran down") end
  local fFresh = punch(1)
  local iFresh, vFresh, sFresh = T.bat("i"), T.bat("v"), T.bat("s")
  local fLow = punch(1, 0.3)
  if math.abs(fFresh - fOff) > 1e-4 then fail(string.format("battery: a fresh pack should fly as without it (thrust %.4f, %.4f off)", fFresh, fOff)) end
  if math.abs(iFresh - 95) > 1 or vFresh > 4.05 or vFresh < 3.63 or sFresh > 0.985 then
    fail(string.format("battery: a 1 s punch on a fresh racer pack: %.1f A, %.2f V a cell, charge %.3f", iFresh, vFresh, sFresh))
  end
  if fLow > 0.9 or fLow < 0.7 then fail(string.format("battery: a punch at 30%% charge should lose thrust (%.2f of full)", fLow)) end
  -- pausing stops it
  fly(1)
  hold(0, 10)
  local s0, t0 = T.bat("s"), T.bat("t")
  frame(EVT_VIRTUAL_EXIT) steps(40)
  if state() ~= 7 or T.bat("s") ~= s0 or T.bat("t") ~= t0 then fail("battery: the pack ran down while paused") end
  frame(EVT_VIRTUAL_EXIT)
  -- Long: twice the capacity, half the share of it used
  hold(1024, FPS)
  local uReal, mReal = s0 - T.bat("s"), T.bat("mah")
  fly(2)
  hold(1024, FPS)
  local uLong, mLong = 1 - T.bat("s"), T.bat("mah")
  if mLong ~= 2 * mReal or math.abs(uLong * 2 / uReal - 1) > 0.1 then fail(string.format("battery Long: %d mAh used %.4f, Real %d mAh used %.4f", mLong, uLong, mReal, uReal)) end
  -- the end of a pack at 2 g (fast forward flight): LOW, LAND, the motors stop, EMPTY
  fly(1)
  T.bat("s", 0.15) T.bat("v", 3.7)
  local cruise, n0, tLow, tLand, tEnd = (hoverStick(2) * 2 - 1) * 1024, tones
  for f = 1, FPS * 120 do
    hold(cruise, 1)
    local w = T.bat("w")
    if w >= 1 and not tLow then tLow = f / FPS end
    if w >= 2 and not tLand then tLand = f / FPS end
    if state() ~= 4 then tEnd = f / FPS break end
  end
  local _, why = T.bat("s")
  local crashes = select(6, T.race())
  if state() ~= 5 or why ~= "EMPTY" or crashes ~= 0 then
    fail(string.format("battery: the end of a pack should be EMPTY, not a crash (state %d, %s, %d crashes)", state(), tostring(why), crashes))
  elseif not (tLow and tLand and tLow < tLand and tLand + 5 < tEnd and tEnd > 25 and tEnd < 70) then
    fail(string.format("battery: from 15%% at 2 g LOW %s s, LAND %s s, EMPTY %s s", tostring(tLow), tostring(tLand), tostring(tEnd)))
  elseif tones - n0 < 5 then fail("battery: no warning beeps")
  end
  idleSticks()
  steps(30)
  if state() ~= 6 or T.bat("s") ~= 1 then fail("battery: EMPTY should respawn with a fresh pack (state " .. state() .. ")") end
  -- a hard hit keeps the pack (and counts); the pause menu's Respawn brings a fresh one
  fly(1)
  T.bat("s", 0.5)
  T.pose(0, 0.4, 0, 0, 0, 45) T.vel(0, -15, 0)      -- (rolled 45 deg: the props strike)
  steps(30)
  local s1, why1 = T.bat("s")
  if state() ~= 4 or why1 or select(6, T.race()) ~= 1 or s1 > 0.5 or s1 < 0.49 then
    fail(string.format("battery: a hit should keep the pack (state %d, %s, charge %.3f)", state(), tostring(why1), s1))
  end
  frame(EVT_VIRTUAL_EXIT) frame(EVT_VIRTUAL_NEXT) frame(EVT_VIRTUAL_ENTER)
  if state() ~= 6 or T.bat("s") ~= 1 then fail(string.format("battery: Respawn should bring a fresh pack (state %d, charge %.3f)", state(), T.bat("s"))) end
  -- the pause and finish screens with the pack's flight time and mAh used
  T.state(4) frame(EVT_VIRTUAL_EXIT) frame(0) frame(EVT_VIRTUAL_EXIT)
  T.state(8) frame(0) frame(0)
  print(string.format("battery: punch on a fresh pack %.0f A, thrust %.3f (%.3f off); at 30%% %.2f; Long %d mAh; " ..
    "from 15%% at 2 g: LOW %.1f s, LAND %.1f s, EMPTY %.1f s", iFresh, fFresh, fOff, fLow, mLong, tLow or -1, tLand or -1, tEnd or -1))
  T.set("batt", 0) T.set("quad", quad) T.set("twr", twr) T.set("mode", mode)
  idleSticks()
  T.state(1)
  frame(0)
end

-- 10. custom tracks: StickTimeTracks/c1-c8.txt are tracks 9-16 (empty slots skipped); a slot's
-- bests start over when a different track (another id) is put in it; a broken file is left out
do
  local CT = "/SCRIPTS/TOOLS/StickTimeTracks/c"
  SD[CT .. "1.txt"] = "Test Loop\n1 4242 7 9  0 0 1 0 0  0 40 1 0 0  30 60 4 90 3  40 20 1 180 0 / 20 30 3 3 0 4 2\n"
  SD[CT .. "3.txt"] = "Hoops\r\n1 77 3 18  0 0 4 0 2.5  20 30 4 45 2  0 60 4 180 3\r\n"
  SD[CT .. "5.txt"] = "Broken\n2 1 1 9 0 0 1 0 0\n"                       -- a format this version can't read
  -- made by hand: a blank first line, a gate type and a structure kind the game doesn't have
  SD[CT .. "2.txt"] = "\nOdd File\n1 55 3 9  0 0 1 0 0  30 0 9 0 0 / 10 10 1 1 0 2 7\n"
  local inst
  for _, c in ipairs({ { 4242, 3000 }, { 999, 0 } }) do
    SD[DATA] = "FPVSIM2 lay=2 track=12 l9=3000 i9=" .. c[1] .. " l11=2500\n"
    STICKTIME_TEST = {}
    inst = chunk()
    inst.init()
    local L = STICKTIME_TEST
    local nt = L.info()
    if nt ~= 11 then fail("custom tracks: the last track should be 11 (c3), is " .. tostring(nt)) end
    if L.S.track ~= 1 then fail("custom tracks: a save pointing at an empty slot should fall back to track 1") end
    if L.best(9) ~= c[2] then fail(string.format("custom tracks: track 9's best lap should be %d (saved id %d), is %s", c[2], c[1], tostring(L.best(9)))) end
    if L.best(11) ~= 0 then fail("custom tracks: track 11's best was saved without its id, it should start over") end
  end
  local L = STICKTIME_TEST
  L.track(9)
  local name, nb = select(11, L.info()), select(10, L.info())
  local x, y, z, _, _, _, k = L.gate(3)
  if name ~= "Test Loop" or nb ~= 1 or x ~= 30 or z ~= 60 or k ~= 4 then
    fail(string.format("custom tracks: track 9 built wrong (%s, %s structures, gate 3 at %s %s type %s)", tostring(name), tostring(nb), tostring(x), tostring(z), tostring(k)))
  end
  L.track(10)
  local name10, nb10 = select(11, L.info()), select(10, L.info())
  if name10 ~= "Odd File" or select(19, L.get()) ~= 2 or nb10 ~= 0 then
    fail(string.format("custom tracks: a hand-made file with unknown types should fly as two gates, no structures (%s, %s gates, %s)",
      tostring(name10), tostring(select(19, L.get())), tostring(nb10)))
  end
  L.track(11)
  local name11 = select(11, L.info())
  if name11 ~= "Hoops" then fail("custom tracks: track 11 (CRLF file) should be 'Hoops', is " .. tostring(name11)) end
  -- fly it: a race with AI pilots on the custom track
  L.track(9) L.set("ai", 2) L.start(1)
  sticks.thr = 300
  for _ = 1, 200 do
    clock = clock + 50
    local ok, e = pcall(inst.run, 0)
    if not ok then fail("custom tracks: run error " .. tostring(e)) break end
  end
  local st = select(16, L.get())
  if st ~= 4 and st ~= 5 and st ~= 6 then fail("custom tracks: the race on track 9 isn't flying (state " .. tostring(st) .. ")") end
  idleSticks()
  print(string.format("custom tracks: 9 '%s' and 11 '%s' listed (c5 left out), bests kept for the same id, race running", name, name11))
  for i = 1, 8 do SD[CT .. i .. ".txt"] = nil end
end

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
