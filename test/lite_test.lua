-- Headless test of FPV Sim Lite (Lua 5.3 with EdgeTX's number settings, or Lua 5.2).
-- Usage: lua lite_test.lua build/fpvlite_test.lua [W H]
-- Menus and settings, time trials and practice on every track with an autopilot, gate rush,
-- crashes, pause, save and reload, B&W drawing rules, VM instructions per frame.
local path, W, H = arg[1], tonumber(arg[2] or 128), tonumber(arg[3] or 64)
local floor = math.floor
local atan2 = math.atan2 or math.atan
local fails = 0
local function fail(msg) fails = fails + 1 if fails < 25 then print("FAIL: " .. msg) end end

LCD_W, LCD_H = W, H
local F = { BLINK = 0x01, INVERS = 0x02, BOLD = 0x40, LEFT = 0, RIGHT = 0x04, CENTER = 0x20, PREC1 = 0x20,
  PREC2 = 0x30, FORCE = 0x02, ERASE = 0x04, ROUND = 0x08, TINSIZE = 0x100, SMLSIZE = 0x200, MIDSIZE = 0x300,
  DBLSIZE = 0x400, XXLSIZE = 0x500, SOLID = 0xff, DOTTED = 0x55 }
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
function playTone() tones = tones + 1 end
function playHaptic() end
local SD = {}
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
    if x1 < 0 or y1 < 0 or x2 < 0 or y2 < 0 or x1 >= W or x2 >= W or y1 >= H or y2 >= H then st.bad = st.bad + 1 end
  end,
  drawText = function(x, y, s) st.calls = st.calls + 1 num(x, "text x") num(y, "text y")
    if type(s) ~= "string" then fail("drawText: not a string") end end,
  drawNumber = function(x, y, v) st.calls = st.calls + 1 num(x, "num x") num(y, "num y") num(v, "num v") end,
  drawRectangle = function(x, y) st.calls = st.calls + 1 num(x, "rect x") num(y, "rect y") end,
  drawFilledRectangle = function(x, y, w, h)
    st.calls = st.calls + 1
    if num(x, "fill x") < 0 or num(y, "fill y") < 0 or num(w, "fill w") < 0 or num(h, "fill h") < 0 then fail("negative fill") end
  end,
}

-- load in an environment without the libraries B&W radios lack
FPVSIM_TEST = {}
local f = assert(loadfile(path, "t", setmetatable({}, { __index = function(_, k)
  if hidden[k] then error("uses '" .. k .. "', which B&W radios do not have", 2) end
  return _G[k]
end, __newindex = function(_, k) fail("sets global " .. tostring(k)) end })))
local script = f()
local T = FPVSIM_TEST
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
  local cx, cy, cz, nx, ny, nz, k = T.gate(target or s[18])
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
for _ = 1, 3 do frame(EVT_VIRTUAL_NEXT) end           -- Track
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
for i = 1, 6 do
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
  print(string.format("track %d %-11s time trial: finished=%s laps=%d total=%.2fs best lap %.2fs crashes=%d",
    t, name, tostring(state() == DONE), lap, total / 100, bl / 100, crashes))
  if state() ~= DONE then fail("track " .. t .. ": time trial not finished") end
  if crashes > 0 then fail("track " .. t .. ": autopilot crashed " .. crashes .. " times") end
  if br <= 0 or bl <= 0 or br < bl * 2 then fail("track " .. t .. ": best race/lap not recorded right") end
  idle()
  frame(EVT_VIRTUAL_EXIT)                              -- results -> menu
  if state() ~= MENU then fail("EXIT on the results should go to the menu") end
end

-- practice: laps keep counting
T.track(1)
T.start(2)
steps(70)
for _ = 1, 2400 do
  if state() == FLY then autopilot() else idle() end
  frame(0)
end
local _, _, _, plap = T.info()
if plap < 3 then fail("practice: only " .. plap .. " laps in 120 s") end

-- 3. gate rush: random gates either way, 30 s plus bonuses, ends by itself
T.track(2)
T.start(3)
steps(70)
local rushSteps = 0
while state() ~= DONE and rushSteps < 4000 do
  local _, s = state()
  if state() == FLY then autopilot(s[18]) else idle() end
  frame(0)
  rushSteps = rushSteps + 1
end
local _, _, _, _, _, rn = T.info()
local _, _, bg = T.best(2)
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
T.pose(cx + nz * 1.6 - nx * 6, cy, cz - nx * 1.6 - nz * 6, math.deg(atan2(nx, nz)), 0, 0)
T.vel(nx * 10, 0, nz * 10)
sticks.thr = 0
steps(15)
if state() ~= CRASHED then fail("no crash into the gate frame (state " .. state() .. ")") end
idle()

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
for _ = 1, 3 do frame(EVT_VIRTUAL_NEXT) end
frame(EVT_VIRTUAL_ENTER)
while T.S.track ~= 3 do frame(EVT_VIRTUAL_INC) end
frame(EVT_VIRTUAL_ENTER)
for _ = 1, 3 do frame(EVT_VIRTUAL_PREV) end
if frame(EVT_VIRTUAL_EXIT) ~= 1 then fail("EXIT in the menu should close the tool") end

-- 6. saved and loaded again by a new instance
local saved = SD["/SCRIPTS/TOOLS/FPVLite/data.txt"]
if not saved then fail("nothing saved") else
  FPVSIM_TEST = {}
  local s2 = f()
  local T2 = FPVSIM_TEST
  s2.init()
  for k, v in pairs(T.S) do
    if T2.S[k] ~= v then fail("setting " .. k .. " not restored: " .. tostring(v) .. " vs " .. tostring(T2.S[k])) end
  end
  if T2.S.track ~= 3 then fail("track not restored") end
  for t = 1, NT do
    local a1, a2, a3 = T.best(t)
    local b1, b2, b3 = T2.best(t)
    if floor(a1) ~= b1 or floor(a2) ~= b2 or a3 ~= b3 then fail("bests of track " .. t .. " not restored") end
  end
  print("saved: " .. saved)
end
-- a broken save file is ignored
SD["/SCRIPTS/TOOLS/FPVLite/data.txt"] = "FPVLITE1 track=99 twr=13 mode=x laps=-1 l1=abc"
FPVSIM_TEST = {}
local s3 = f()
s3.init()
if FPVSIM_TEST.S.track ~= 1 or FPVSIM_TEST.S.twr ~= 5 then fail("bad save values were not rejected") end
s3.run(0)

print(string.format("%s %s %dx%d  frames %d  instr/frame avg %d max %d  lines %d  off-screen lines %d  tones %d",
  _VERSION, path:match("[^/]+$"), W, H, frames, floor(instrSum / frames), instrMax, st.lines, st.bad, tones))
if st.bad > 0 then fail(st.bad .. " lines with points off the screen (B&W refuses them)") end
print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
