local toolName = "TNS|FPV Sim Lite|TNE"
--[[ ======================================================================
FPV Sim Lite v1.2  -  the small edition of FPV Sim for B&W radios.
Made for radios with little memory (STM32F2: X7, X9D, X9D+, X9 Lite,
X-Lite, TX12 MkI, T12, T8, T-Lite, T-Pro, LR3 Pro). Runs on every
black & white EdgeTX radio with EdgeTX 2.11 or newer.
Install : copy FPVLite.lua and the FPVLite folder to /SCRIPTS/TOOLS/,
then start it from SYS > TOOLS.
Fly     : your sticks fly the quad (acro or angle mode). EXIT pauses,
ENTER selects, +/- (or the wheel) moves through the menus.
Safety  : the radio keeps transmitting while the sim runs - keep the
real quad unplugged or the RF module off.
====================================================================== ]]
local lcd = lcd
local sqrt, sin, cos, floor = math.sqrt, math.sin, math.cos, math.floor
local getValue, getTime, drawLine, drawText = getValue, getTime, lcd.drawLine, lcd.drawText
local XM, YM, CX, CY = LCD_W - 1, LCD_H - 1, LCD_W / 2, LCD_H / 2
local SOLID, DOTTED, BLK, SML, INV = SOLID, DOTTED, FORCE, SMLSIZE, INVERS
local E_ENTER, E_EXIT = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK
local E_NEXT, E_PREV, E_INC, E_DEC = EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV, EVT_VIRTUAL_INC, EVT_VIRTUAL_DEC
local GRY = type(GREY) == "function" and GREY(7) + FORCE or FORCE    -- horizon and grid
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8
local function nums(s)
local t = {}
for v in string.gmatch(s, "%-?[%d%.]+") do t[#t + 1] = tonumber(v) end
return t
end
local S = { track = 1, quad = 1, twr = 5, mode = 1, rates = 2, tilt = 20, laps = 3 }
local OPTS = {
{ "Quad", "quad", { 1, 2 }, { "Racer", "Freestyle" } },
{ "Power", "twr", nums("3 4 5 6 7 8 10 12"), ":1" },
{ "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
{ "Rates", "rates", { 1, 2, 3 }, { "Soft", "Normal", "Fast" } },
{ "Camera tilt", "tilt", nums("0 10 15 20 25 30 35 40 50") },
{ "Laps", "laps", nums("1 2 3 5 10") },
}
local RATES = nums("70 400 35 70 350 30 100 600 50 100 500 40 150 850 45 130 700 40")
local QP = nums("86 .22 .009 .028 .02 .012 60 .18 .0072 .024 .03 .02")
local TRACKS = {
"Meadow", 11, "0 0 1 0 0 6 34 1 20 0 26 58 2 70 0 56 52 1 120 0 66 22 1 180 0 52 -8 2 230 0 24 -22 1 270 0",
"Figure 8", 23, "-14 10 1 0 0 6 46 2 40 0 18 68 1 0 0 0 88 1 -90 0 -18 68 1 180 0 18 16 1 180 0 0 -4 1 -90 0",
"Dive Tower", 37, "0 0 1 0 0 10 30 1 20 0 12 60 2 0 0 0 84 2 -90 0 -28 84 3 -90 0 -36 52 1 180 0 -28 20 1 160 0 -12 -14 1 60 0",
"Grand Prix", 71, "0 0 1 0 0 0 40 1 0 0 10 80 2 20 6 36 104 1 70 2.5 64 106 1 100 0 88 96 1 120 0 110 76 3 180 0 " ..
"112 44 1 180 0 104 14 1 200 1.8 84 -8 2 250 8 56 -18 1 270 0 30 -28 1 290 2.5",
}
local NT = floor(#TRACKS / 3)
local GT, DR = 0.28, 0.15                          -- gate frame thickness, quad radius (m)
local GW, GH = { 1.5, 1.5, 2 }, { 1, 1, 2 }        -- inner half width / height per type
local CS = { -1, 1, 1, -1, -1, 1, 1, -1 }          -- corners of a gate: s = CS[c], u = CS[c + 3]
local NG, gx, gy, gz, gk, gd = 0, {}, {}, {}, {}, {}
local gnx, gny, gnz, grx, grz, gax, gay, gaz = {}, {}, {}, {}, {}, {}, {}, {}
local NP, qx, qz, qr, qh = 0, {}, {}, {}, {}
local spx, spz, shx, shz, x0, x1, z0, z1 = 0, 0, 0, 1, 0, 0, 0, 0   -- start pad, heading, bounds
local seed = 1
local function rnd()
seed = seed * 171 % 30269
return seed / 30269
end
local function pillar(x, z, r, h)
NP = NP + 1
qx[NP], qz[NP], qr[NP], qh[NP] = x, z, r, h
end
local function buildTrack(t)
local d = nums(TRACKS[t * 3])
NG, NP = 0, 0
for i = 1, #d, 5 do
NG = NG + 1
local k, a = d[i + 2], d[i + 3] * 0.0174533
local hx, hz, x, z, y = sin(a), cos(a), d[i], d[i + 1], d[i + 4]
if y <= 0 then y = k == 1 and 1.35 or k == 2 and 5.5 or 7 end
gx[NG], gy[NG], gz[NG], gk[NG], grx[NG], grz[NG] = x, y, z, k, hz, -hx
local Ax, Ay, Az = 0, 1, 0
if k == 3 then
gnx[NG], gny[NG], gnz[NG], Ax, Ay, Az = 0, -1, 0, hx, 0, hz
else
gnx[NG], gny[NG], gnz[NG] = hx, 0, hz
end
gax[NG], gay[NG], gaz[NG] = Ax, Ay, Az
if k > 1 then
local w, h = GW[k] + GT * 0.5, GH[k] + (k == 3 and GT * 0.5 or GT)
for c = 1, 4 do
local s_, u = CS[c], CS[c + 3]
if k == 3 or u < 0 then pillar(x + hz * w * s_ + Ax * h * u, z - hx * w * s_ + Az * h * u, GT * 0.5, y + Ay * h * u) end
end
end
end
shx, shz = gnx[1], gnz[1]
spx, spz = gx[1] - shx * 14, gz[1] - shz * 14
x0, x1, z0, z1 = spx, spx, spz, spz
for i = 1, NG do
if gx[i] < x0 then x0 = gx[i] end
if gx[i] > x1 then x1 = gx[i] end
if gz[i] < z0 then z0 = gz[i] end
if gz[i] > z1 then z1 = gz[i] end
end
seed = TRACKS[t * 3 - 1]
local trees, tries = 0, 0
while trees < 9 and tries < 200 do
tries = tries + 1
local x, z, ok = x0 - 30 + rnd() * (x1 - x0 + 60), z0 - 30 + rnd() * (z1 - z0 + 60), true
for i = 0, NG do
local px_, pz_ = gx[i] or spx, gz[i] or spz
local j = i % NG + 1
local dx, dz = gx[j] - px_, gz[j] - pz_
local u = ((x - px_) * dx + (z - pz_) * dz) / (dx * dx + dz * dz)
if u < 0 then u = 0 elseif u > 1 then u = 1 end
dx, dz = px_ + dx * u - x, pz_ + dz * u - z
if dx * dx + dz * dz < 100 then ok = false end
end
if ok then
trees = trees + 1
local h = 6 + rnd() * 6
pillar(x, z, h * 0.14, h)
end
end
end
local BL, BR, BG = {}, {}, {}
for t = 1, NT do BL[t], BR[t], BG[t] = 0, 0, 0 end
local FILE = "/SCRIPTS/TOOLS/FPVLite/data.txt"
local function save()
local s = "FPVLITE1"
for k, v in pairs(S) do s = s .. " " .. k .. "=" .. floor(v) end
for t = 1, NT do s = s .. " l" .. t .. "=" .. floor(BL[t]) .. " r" .. t .. "=" .. floor(BR[t]) .. " g" .. t .. "=" .. BG[t] end
local f = io.open(FILE, "w")
if f then
io.write(f, s)
io.close(f)
end
end
local function load()
local f = io.open(FILE, "r")
if not f then return end
local s = io.read(f, 400)
io.close(f)
if type(s) ~= "string" or string.sub(s, 1, 8) ~= "FPVLITE1" then return end
for k, n, v in string.gmatch(s, "(%a+)(%d*)=(%d+)") do
v, n = tonumber(v), tonumber(n)
local B = k == "l" and BL or k == "r" and BR or k == "g" and BG
if B then
if n and n >= 1 and n <= NT then B[n] = v end
elseif k == "track" then
if v >= 1 and v <= NT then S.track = v end
else
for _, o in ipairs(OPTS) do
for _, x in ipairs(o[3]) do
if o[2] == k and x == v then S[k] = v end
end
end
end
end
end
local px, py, pz, vx, vy, vz = 0, DR, 0, 0, 0, 0                      -- position, velocity (m, m/s)
local rx, ry, rz, ux, uy, uz, fx, fy, fz = 1, 0, 0, 0, 1, 0, 0, 0, 1   -- right, up, forward
local sA, sE, sT, sR, speed = 0, 0, 0, 0, 0
local wr0, wp0, wy0, Tm, grounded = 0, 0, 0, 0, true                  -- body rates (rad/s), thrust
local state, gm, from = MENU, 1, FLY
local gt, lastT, tState, tStart, fi, pt = 0, 0, 0, 0, 5, 0             -- clocks (10 ms ticks)
local lap, nextGate, lastGate, lapStart, total = 0, 1, 0, nil, 0
local rn, rt, newBest, msg, msgT, cd = 0, 0, false, nil, 0, -1
local P = {}                                                           -- rates and quad in use
local tc, ts, F = 0.94, 0.34, 54                                       -- camera tilt, focal length
local function beep(f, d)
if playTone then playTone(f, d, 0, 0) end
end
local function timeStr(cs)
local s = floor(cs / 100)
return string.format("%d:%02d.%d", floor(s / 60), s % 60, floor(cs % 100 / 10))
end
local function apply()
local r, q = S.rates * 6 - 6, S.quad * 6 - 6
for i = 1, 6 do P[i], P[i + 6] = RATES[r + i], QP[q + i] end
local t = S.tilt * 0.0174533
tc, ts = cos(t), sin(t)
F = CX / 1.19                                                        -- 100 deg field of view
end
local SRC = { "ail", "ele", "thr", "rud" }
local function stick(i)
local v = getValue(SRC[i]) / 1024
return v > 1 and 1 or v < -1 and -1 or v
end
local function rate(x, c, m, e)
local a, x2 = x < 0 and -x or x, x * x
e = e * 0.01
return (x * c + (m - c) * a * x * (x2 * x2 * e + 1 - e)) * 0.0174533
end
local function rotate(ar, ap, ay)
if ar > 1e-7 or ar < -1e-7 then
local c, s = cos(ar), sin(ar)
rx, ry, rz, ux, uy, uz = rx * c - ux * s, ry * c - uy * s, rz * c - uz * s, ux * c + rx * s, uy * c + ry * s, uz * c + rz * s
end
if ap > 1e-7 or ap < -1e-7 then
local c, s = cos(ap), sin(ap)
fx, fy, fz, ux, uy, uz = fx * c + ux * s, fy * c + uy * s, fz * c + uz * s, ux * c - fx * s, uy * c - fy * s, uz * c - fz * s
end
if ay > 1e-7 or ay < -1e-7 then
local c, s = cos(ay), sin(ay)
fx, fy, fz, rx, ry, rz = fx * c + rx * s, fy * c + ry * s, fz * c + rz * s, rx * c - fx * s, ry * c - fy * s, rz * c - fz * s
end
end
local function place(x, y, z, hx, hz)
local l = sqrt(hx * hx + hz * hz) + 0.001
hx, hz = hx / l, hz / l
px, py, pz, vx, vy, vz = x, y, z, 0, 0, 0
fx, fy, fz, rx, ry, rz, ux, uy, uz = hx, 0, hz, hz, 0, -hx, 0, 1, 0
grounded, speed, Tm, wr0, wp0, wy0 = y <= DR + 0.01, 0, 0, 0, 0, 0
for i = 1, NG do
gd[i] = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i]
end
end
local function respawn()
local i, j = lastGate, nextGate
if i > 0 then
place(gx[i] + gnx[i] * 1.5, gy[i] - (gk[i] == 3 and 1.5 or 0), gz[i] + gnz[i] * 1.5, gx[j] - gx[i], gz[j] - gz[i])
else
place(spx, DR, spz, shx, shz)
end
end
local function show(s)
msg, msgT = s, gt
end
local function finish()
state, tState = DONE, gt
save()
beep(1800, 120)
beep(2400, 300)
end
local function gatePassed(i, fwd)
if state == DONE or i ~= nextGate then return end
if gm == 3 then
rn = rn + 1
local b = 6 - rn * 0.15
if b < 2.5 then b = 2.5 end
rt = rt + b
lastGate = i
nextGate = floor(rnd() * (NG - 1)) + 1
if nextGate >= i then nextGate = nextGate + 1 end
show("+" .. floor(b * 10) / 10 .. "s")
beep(1300 + rn * 30, 60)
return
end
if not fwd then return end
lastGate, nextGate = i, i % NG + 1
if i > 1 then beep(1300 + i * 60, 60) return end
if lapStart then
local lt, t = gt - lapStart, S.track
show((BL[t] < 1 or lt < BL[t]) and "BEST " .. timeStr(lt) or "LAP " .. timeStr(lt))
if BL[t] < 1 or lt < BL[t] then BL[t] = lt end
lap = lap + 1
beep(2200, 160)
if gm == 1 and lap > S.laps then
total, lap = gt - tStart, S.laps
if BR[t] < 1 or total < BR[t] then BR[t], newBest = total, true end
finish()
return
end
save()
else
lap = 1
beep(1600, 80)
end
lapStart = gt
end
local nearG, nearP = {}, {}
local function physics(dt)
local Tmax, wr, wp = S.twr * 9.81, 0, 0
if S.mode == 2 then
local hx, hz = -rz, rx
local l = sqrt(hx * hx + hz * hz) + 0.0001
hx, hz = hx / l, hz / l
local dx, dz = hx * sE + hz * sA, hz * sE - hx * sA
wr, wp = (dx * rx + ry + dz * rz) * 8, -(dx * fx + fy + dz * fz) * 8
wr, wp = wr > 8 and 8 or wr < -8 and -8 or wr, wp > 8 and 8 or wp < -8 and -8 or wp
else
wr, wp = rate(sA, P[1], P[2], P[3]), -rate(sE, P[1], P[2], P[3])
end
local wy = rate(sR, P[4], P[5], P[6])
local T = Tmax * (0.015 + 0.985 * sT ^ 1.6)                  -- 1.5% idle, like DShot idle
if grounded and T < 10 then
wr, wp, wr0, wp0 = 0, 0, 0, 0
if uy < 0.999 then place(px, DR, pz, fx, fz) end
end
local n = floor(dt * 80) + 1
local h = dt / n
local km, kr, VP, KH, KS, KU, sTx = h / (P[11] + h), h / (P[12] + h), P[7], P[8], P[9], P[10], sqrt(Tmax)
local reach, ng, np = speed * dt + 7, 0, 0
for i = 1, NG do
local dx, dy, dz = px - gx[i], py - gy[i], pz - gz[i]
if dx * dx + dy * dy + dz * dz < reach * reach then
ng = ng + 1
nearG[ng] = i
else
gd[i] = dx * gnx[i] + dy * gny[i] + dz * gnz[i]
end
end
for i = 1, NP do
local dx, dz = px - qx[i], pz - qz[i]
if dx * dx + dz * dz < (reach + qr[i]) ^ 2 then
np = np + 1
nearP[np] = i
end
end
for _ = 1, n do
Tm = Tm + (T - Tm) * km
wr0, wp0, wy0 = wr0 + (wr - wr0) * kr, wp0 + (wp - wp0) * kr, wy0 + (wy - wy0) * kr
rotate(wr0 * h, wp0 * h, wy0 * h)
local vu, vr, vf = vx * ux + vy * uy + vz * uz, vx * rx + vy * ry + vz * rz, vx * fx + vy * fy + vz * fz
local Ta = Tm - vu * sqrt(Tm) * sTx / VP
Ta = Ta > Tm * 1.25 and Tm * 1.25 or Ta < 0 and 0 or Ta
local kh = KH * sqrt(Tm / Tmax + 0.02)
local au = Ta - KU * (vu < 0 and -vu or vu) * vu
local ar = -(kh + KS * (vr < 0 and -vr or vr)) * vr
local af = -(kh + KS * (vf < 0 and -vf or vf)) * vf
vx = vx + (ux * au + rx * ar + fx * af) * h
vy = vy + (uy * au + ry * ar + fy * af - 9.81) * h
vz = vz + (uz * au + rz * ar + fz * af) * h
local ox_, oy_, oz_ = px, py, pz
px, py, pz = px + vx * h, py + vy * h, pz + vz * h
grounded = py < DR
if grounded then
if vy < -6 or vx * vx + vz * vz > 196 or uy < 0.35 then return true end
py, vy = DR, vy < 0 and 0 or vy
vx, vz = vx * (1 - 7 * h), vz * (1 - 7 * h)
end
if py > 250 or px < x0 - 160 or px > x1 + 160 or pz < z0 - 160 or pz > z1 + 160 then return true end
for j = 1, ng do
local i = nearG[j]
local d1, d0 = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i], gd[i]
gd[i] = d1
if (d0 < 0) ~= (d1 < 0) then
local t = d0 / (d0 - d1)
local qx_, qy_, qz_ = ox_ + (px - ox_) * t - gx[i], oy_ + (py - oy_) * t - gy[i], oz_ + (pz - oz_) * t - gz[i]
local lx, ly, k = qx_ * grx[i] + qz_ * grz[i], qx_ * gax[i] + qy_ * gay[i] + qz_ * gaz[i], gk[i]
lx, ly = lx < 0 and -lx or lx, ly < 0 and -ly or ly
if lx < GW[k] - DR * 0.5 and ly < GH[k] - DR * 0.5 then gatePassed(i, d1 >= 0)
elseif lx < GW[k] + GT + DR and ly < GH[k] + GT + DR then return true end
if state ~= FLY and state ~= DONE then return end
end
end
for j = 1, np do
local i = nearP[j]
local dx, dz = px - qx[i], pz - qz[i]
if py < qh[i] and dx * dx + dz * dz < (qr[i] + DR) ^ 2 then return true end
end
end
local l = 1 / sqrt(fx * fx + fy * fy + fz * fz)
fx, fy, fz = fx * l, fy * l, fz * l
local d = rx * fx + ry * fy + rz * fz
rx, ry, rz = rx - d * fx, ry - d * fy, rz - d * fz
l = 1 / sqrt(rx * rx + ry * ry + rz * rz)
rx, ry, rz = rx * l, ry * l, rz * l
ux, uy, uz = fy * rz - fz * ry, fz * rx - fx * rz, fx * ry - fy * rx
speed = sqrt(vx * vx + vy * vy + vz * vz)
end
local function start(m)
gm, lap, nextGate, lastGate, lapStart, total = m, 0, 1, 0, nil, 0
rn, rt, newBest, msg, cd = 0, 30, false, nil, -1
place(spx, DR, spz, shx, shz)
state, tState = COUNT, gt
end
local function selectTrack(t)
S.track = t
buildTrack(t)
place(spx, DR, spz, shx, shz)
end
local function update(dt)
if state == COUNT then
local n = floor((gt - tState) / 100)
if n ~= cd then
cd = n
beep(n < 3 and 1000 or 2000, n < 3 and 120 or 400)
end
if n >= 3 then
state, tStart = FLY, gt
show("GO!")
end
elseif state == FLY or state == DONE then
if physics(dt) then
if state == DONE then respawn() else
state, tState = CRASHED, gt
beep(260, 400)
if playHaptic then playHaptic(60, 0) end
end
end
elseif state == CRASHED then
if gt - tState > 120 then
respawn()
state, tState = READY, gt
end
elseif state == READY then
local e = gt - tState
if e > 25 and (e > 200 or sA * sA + sE * sE + sR * sR > 0.015 or sT > 0.3) then state = FLY end
end
if gm == 3 and state ~= COUNT and state ~= DONE then
rt = rt - dt
if rt <= 0 then
rt = 0
if rn > BG[S.track] then BG[S.track], newBest = rn, true end
finish()
end
end
end
local kx, ky, kz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1
local function line2(x1, y1, x2, y2, pat, fl)
local dx, dy, t0, t1 = x2 - x1, y2 - y1, 0, 1
if dx > 1e-6 or dx < -1e-6 then
local ta, tb = -x1 / dx, (XM - x1) / dx
if ta > tb then ta, tb = tb, ta end
if ta > t0 then t0 = ta end
if tb < t1 then t1 = tb end
elseif x1 < 0 or x1 > XM then return end
if dy > 1e-6 or dy < -1e-6 then
local ta, tb = -y1 / dy, (YM - y1) / dy
if ta > tb then ta, tb = tb, ta end
if ta > t0 then t0 = ta end
if tb < t1 then t1 = tb end
elseif y1 < 0 or y1 > YM then return end
if t0 <= t1 then
drawLine(floor(x1 + dx * t0 + 0.5), floor(y1 + dy * t0 + 0.5), floor(x1 + dx * t1 + 0.5), floor(y1 + dy * t1 + 0.5), pat, fl)
end
end
local function line3(x1, y1, z1, x2, y2, z2, pat, fl)
x1, y1, z1, x2, y2, z2 = x1 - kx, y1 - ky, z1 - kz, x2 - kx, y2 - ky, z2 - kz
local X1, Y1, Z1 = x1 * krx + y1 * kry + z1 * krz, x1 * kux + y1 * kuy + z1 * kuz, x1 * kfx + y1 * kfy + z1 * kfz
local X2, Y2, Z2 = x2 * krx + y2 * kry + z2 * krz, x2 * kux + y2 * kuy + z2 * kuz, x2 * kfx + y2 * kfy + z2 * kfz
if Z1 < 0.2 then
if Z2 < 0.2 then return end
local t = (0.2 - Z1) / (Z2 - Z1)
X1, Y1, Z1 = X1 + (X2 - X1) * t, Y1 + (Y2 - Y1) * t, 0.2
elseif Z2 < 0.2 then
local t = (0.2 - Z2) / (Z1 - Z2)
X2, Y2, Z2 = X2 + (X1 - X2) * t, Y2 + (Y1 - Y2) * t, 0.2
end
line2(CX + X1 * F / Z1, CY - Y1 * F / Z1, CX + X2 * F / Z2, CY - Y2 * F / Z2, pat, fl)
end
local function render3D()
local d = (state == FLY or state == DONE) and fi * 0.003 or 0
local a1, a2, a3, b1, b2, b3, e1, e2, e3 = rx, ry, rz, ux, uy, uz, fx, fy, fz
rotate(wr0 * d, wp0 * d, wy0 * d)
kx, ky, kz = px + vx * d, py + vy * d, pz + vz * d
if ky < 0.05 then ky = 0.05 end
krx, kry, krz = rx, ry, rz
kfx, kfy, kfz = fx * tc + ux * ts, fy * tc + uy * ts, fz * tc + uz * ts
kux, kuy, kuz = ux * tc - fx * ts, uy * tc - fy * ts, uz * tc - fz * ts
rx, ry, rz, ux, uy, uz, fx, fy, fz = a1, a2, a3, b1, b2, b3, e1, e2, e3
lcd.clear()
local a, b, c = kry, kuy, F * kfy
if (a < 0 and -a or a) <= (b < 0 and -b or b) then
if b > 1e-5 or b < -1e-5 then line2(0, CY + (c - CX * a) / b, XM, CY + (c + (XM - CX) * a) / b, SOLID, GRY) end
else
line2(CX + (-CY * b - c) / a, 0, CX + ((YM - CY) * b - c) / a, YM, SOLID, GRY)
end
local gx0, gz0 = floor(kx / 10) * 10, floor(kz / 10) * 10
for i = -3, 4 do
line3(gx0 + i * 10, 0, gz0 - 35, gx0 + i * 10, 0, gz0 + 35, DOTTED, GRY)
line3(gx0 - 35, 0, gz0 + i * 10, gx0 + 35, 0, gz0 + i * 10, DOTTED, GRY)
end
for i = 1, NG do
local dx, dy, dz = gx[i] - kx, gy[i] - ky, gz[i] - kz
local z, x = dx * kfx + dy * kfy + dz * kfz, dx * krx + dy * kry + dz * krz
if z > -4 and z < 90 and (x < 0 and -x or x) < z * 1.19 + 4 then
local nxt, k = i == nextGate, gk[i]
local pat, w, h = (nxt or z < 12) and SOLID or DOTTED, GW[k] + GT, GH[k] + GT
for _ = 1, (nxt or z < 30) and 2 or 1 do
local Rx, Rz, Ax, Ay, Az = grx[i] * w, grz[i] * w, gax[i] * h, gay[i] * h, gaz[i] * h
local x1, y1, z1, x2, z2 = gx[i] - Rx - Ax, gy[i] - Ay, gz[i] - Rz - Az, gx[i] + Rx - Ax, gz[i] + Rz - Az
local x3, y3, z3, x4, z4 = gx[i] + Rx + Ax, gy[i] + Ay, gz[i] + Rz + Az, gx[i] - Rx + Ax, gz[i] - Rz + Az
line3(x1, y1, z1, x2, y1, z2, pat, BLK)
line3(x2, y1, z2, x3, y3, z3, pat, BLK)
line3(x3, y3, z3, x4, y3, z4, pat, BLK)
line3(x4, y3, z4, x1, y1, z1, pat, BLK)
w, h = GW[k], GH[k]
end
end
end
for i = 1, NP do
local x, z, h = qx[i], qz[i], qh[i]
local dx, dz = x - kx, z - kz
local d = dx * kfx + (h * 0.5 - ky) * kfy + dz * kfz
local l = dx * krx + (h * 0.5 - ky) * kry + dz * krz
if d > -h and d < 90 and (l < 0 and -l or l) < d * 1.19 + 6 then
line3(x, 0, z, x, h, z, SOLID, BLK)
if qr[i] > 0.5 and d < 45 then
l = h * 0.24 / (sqrt(dx * dx + dz * dz) + 0.01)
dx, dz, d = dz * l, -dx * l, h * 0.25
line3(x - dx, d, z - dz, x, h, z, SOLID, BLK)
line3(x + dx, d, z + dz, x, h, z, SOLID, BLK)
line3(x - dx, d, z - dz, x + dx, d, z + dz, SOLID, BLK)
end
end
end
end
local function hud()
local l = gm < 3
lcd.drawNumber(1, 1, l and floor((lapStart and gt - lapStart or 0) / 10) or floor(rt * 10), PREC1 + SML + LEFT)
drawText(XM, 1, l and ((lap > 0 and lap or 1) .. (gm == 1 and "/" .. S.laps or "")) or rn .. "", SML + RIGHT)
local i = nextGate
local dx, dy, dz = gx[i] - kx, gy[i] - ky, gz[i] - kz
local X, Y, Z = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
if Z < 1 or X * F > (CX - 3) * Z or -X * F > (CX - 3) * Z or Y * F > (CY - 3) * Z or -Y * F > (CY - 3) * Z then
if Z < 0 and X * X + Y * Y < 1 then X, Y = 0, -1 end
local l2 = sqrt(X * X + Y * Y) + 0.0001
local ex, ey = X / l2, -Y / l2
local k = (CX - 6) / ((ex < 0 and -ex or ex) + 0.0001)
local k2 = (CY - 6) / ((ey < 0 and -ey or ey) + 0.0001)
if k2 < k then k = k2 end
local tx, ty = CX + ex * k, CY + ey * k
line2(tx, ty, tx - ex * 5 - ey * 3, ty - ey * 5 + ex * 3, SOLID, BLK)
line2(tx, ty, tx - ex * 5 + ey * 3, ty - ey * 5 - ex * 3, SOLID, BLK)
end
local th = floor(sT * 30)
if th > 0 then lcd.drawFilledRectangle(0, YM - th, 2, th, BLK) end
drawLine(CX - 4, CY, CX - 2, CY, SOLID, BLK)
drawLine(CX + 2, CY, CX + 4, CY, SOLID, BLK)
if msg and gt - msgT < 200 then drawText(CX, 10, msg, SML + CENTER) end
end
local focus, scroll, editing = 1, 0, false
local MAIN = { "Time trial", "Practice", "Gate rush", "Track", "Settings", "Exit" }
local PAUSE = { "Resume", "Restart", "Menu" }
local function optIdx(o)
for j = 1, #o[3] do
if o[3][j] == S[o[2]] then return j end
end
return 1
end
local function label(i)
if state == MENU then
if i ~= 4 then return MAIN[i] end
local t = TRACKS[S.track * 3 - 2]
return editing and "< " .. t .. " >" or "Track: " .. t
end
return OPTS[i] and OPTS[i][1] or "Back"
end
local function box(y)
lcd.drawFilledRectangle(8, y, XM - 15, YM + 1 - y * 2, ERASE)
lcd.drawRectangle(8, y, XM - 15, YM + 1 - y * 2, BLK)
end
local function render()
if state == MENU or state == SETUP then
lcd.clear()
local n, y = #MAIN, 15
if state == MENU then
local t = S.track
drawText(1, 0, "FPV SIM", MIDSIZE)
drawText(XM, 0, "LITE", SML + RIGHT)
local b = (focus == 1 and BR or BL)[t]
drawText(XM, 7, "best " .. (focus == 3 and BG[t] .. " gates" or b > 0 and timeStr(b) or "--"), SML + RIGHT)
else
drawText(1, 0, "SETTINGS", SML + INV)
n, y = #OPTS + 1, 9
end
local rows = floor((YM + 1 - y) / 8)
if rows > n then rows = n end
if focus - scroll > rows then scroll = focus - rows end
if focus <= scroll then scroll = focus - 1 end
for r = 1, rows do
local i = scroll + r
local o, f = OPTS[i], i == focus and INV or 0
drawText(2, y, label(i), SML + ((editing and state == SETUP) and 0 or f))
if state == SETUP and o then
local j = optIdx(o)
drawText(XM - 1, y, type(o[4]) == "table" and o[4][j] or o[3][j] .. (o[4] or ""), SML + RIGHT + (editing and f or 0))
end
y = y + 8
end
return
end
render3D()
if state == DONE then
box(4)
drawText(12, 7, newBest and "NEW RECORD!" or gm == 3 and "TIME UP" or "FINISHED", SML + INV)
drawText(12, 17, gm == 3 and "Gates " .. rn .. "  best " .. BG[S.track] or "Total " .. timeStr(total), SML)
if gm < 3 then drawText(12, 26, "Best lap " .. timeStr(BL[S.track]), SML) end
drawText(12, YM - 15, "ENTER again  EXIT menu", SML)
return
end
hud()
if state == COUNT then
drawText(CX - 4, CY - 16, 3 - floor((gt - tState) / 100) .. "", DBLSIZE)
elseif state == CRASHED then
drawText(CX - 24, CY - 8, "CRASH", DBLSIZE + INV)
elseif state == READY then
drawText(CX - 14, CY - 14, "READY", SML + INV)
elseif state == PAUSED then
box(10)
for i = 1, 3 do drawText(22, 6 + i * 11, PAUSE[i], i == focus and INV or 0) end
end
end
local function handle(e)
local nav = e == E_NEXT and 1 or e == E_PREV and -1 or 0
if state == MENU or state == SETUP then
local n = state == MENU and #MAIN or #OPTS + 1
if editing then
local d = e == E_INC and 1 or e == E_DEC and -1 or 0
if state == MENU and d ~= 0 then
selectTrack((S.track + d - 1) % NT + 1)
save()
elseif d ~= 0 then
local o = OPTS[focus]
S[o[2]] = o[3][(optIdx(o) + d - 1) % #o[3] + 1]
apply()
elseif e == E_ENTER or e == E_EXIT then
editing = false
end
return 0
end
focus = (focus + nav - 1) % n + 1
if e == E_ENTER then
if state == SETUP then
if focus == n then e = E_EXIT else editing = true end
elseif focus <= 3 then start(focus)
elseif focus == 4 then editing = true
elseif focus == 5 then state, focus, scroll = SETUP, 1, 0
else return 1 end
end
if e == E_EXIT then
if state == MENU then return 1 end
save()
state, focus, scroll = MENU, 5, 0
end
elseif state == PAUSED then
focus = (focus + nav - 1) % 3 + 1
if e == E_EXIT or (e == E_ENTER and focus == 1) then state = from
elseif e == E_ENTER and focus == 2 then start(gm)
elseif e == E_ENTER then state, focus, scroll = MENU, 1, 0 end
elseif state == DONE then
if e == E_ENTER then start(gm) elseif e == E_EXIT then state, focus, scroll = MENU, 1, 0 end
elseif e == E_EXIT then
from, state, focus = state, PAUSED, 1
end
return 0
end
local function init()
for i = 1, 4 do
local f = getFieldInfo and getFieldInfo(SRC[i])
if f then SRC[i] = f.id end
end
load()
apply()
selectTrack(S.track)
lastT = getTime()
end
local function run(event)
local now = getTime()
local dtk = now - lastT
lastT = now
dtk = dtk > 10 and 10 or dtk < 0 and 0 or dtk
fi = fi + (dtk - fi) * 0.2
local paused = state == PAUSED or state == SETUP or state == MENU
gt = gt + (paused and 0 or dtk)
local t = pt + (paused and 0 or fi)
t = t > gt + 1 and gt + 1 or t < gt - 1 and gt - 1 or t
local dts = (t - pt) * 0.01
pt = t
sA, sE, sR = stick(1), stick(2), stick(4)
sT = (stick(3) + 1) * 0.5
if handle(event or 0) ~= 0 then return 1 end
update(dts > 0 and dts or 0)
render()
return 0
end
return { init = init, run = run }
