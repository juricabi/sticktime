local toolName = "TNS|StickTime Lite|TNE"
--[[ ======================================================================
  StickTime Lite v1.3  -  the small edition of StickTime for B&W radios.
  Made for radios with little memory (STM32F2: X7, X9D, X9D+, X9 Lite,
  X-Lite, TX12 MkI, T12, T8, T-Lite, T-Pro, LR3 Pro). Runs on every
  black & white EdgeTX radio with EdgeTX 2.11 or newer.

  Install : copy StickTimeLite.lua and the StickTimeLite folder to
            /SCRIPTS/TOOLS/, then start it from SYS > TOOLS.
  Fly     : your sticks fly the quad (acro or angle mode). EXIT pauses,
            ENTER selects, +/- (or the wheel) moves through the menus.
  Modes   : Time trial, Practice, Freestyle (tricks and combos) and
            Gate Rush (beat the clock), on seven tracks.
  Safety  : the radio keeps transmitting while the sim runs - keep the
            real quad unplugged or the RF module off.
====================================================================== ]]

-- Same flight model as the full StickTime, in as little code as possible: on these radios
-- every instruction, constant and string of the script stays in memory while it runs.
-- (Measured with test/memtest.lua on EdgeTX's own Lua and allocator: see the README.)
local lcd = lcd
local sqrt, sin, cos, floor = math.sqrt, math.sin, math.cos, math.floor
local getValue, getTime, drawLine, drawText, playTone = getValue, getTime, lcd.drawLine, lcd.drawText, playTone
local XM, YM, CX, CY = LCD_W - 1, LCD_H - 1, LCD_W / 2, LCD_H / 2
local SOLID, DOTTED, BLK, SML, INV = SOLID, DOTTED, FORCE, SMLSIZE, INVERS

-- states; game modes (gm): 1 time trial, 2 practice, 3 freestyle, 4 gate rush
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8   --#fold

-- the numbers in a string, read digit by digit: no string per number (garbage on a small heap)
local function nums(s)
  local t, n, v, sg, fr, byte = {}, 0, nil, 1, 0, string.byte
  for i = 1, #s + 1 do
    local c = byte(s, i) or 32
    if c >= 48 and c <= 57 then
      v = (v or 0) * 10 + c - 48
      if fr > 0 then fr = fr * 10 end
    elseif c == 46 then v, fr = v or 0, 1
    elseif c == 45 then sg = -1
    elseif v then
      n = n + 1
      t[n] = sg * (fr > 0 and v / fr or v)
      v, sg, fr = nil, 1, 0
    end
  end
  return t
end

-- settings: label, key, values, names or suffix
local S = { track = 1, quad = 1, twr = 5, mode = 1, rates = 2, tilt = 20, laps = 3, wind = 0 }
local OPTS = {
  { "Quad", "quad", { 1, 2 }, { "Racer", "Freestyle" } },
  { "Power", "twr", nums("3 4 5 6 7 8 10 12"), ":1" },
  { "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
  { "Rates", "rates", { 1, 2, 3 }, { "Soft", "Normal", "Fast" } },
  { "Camera tilt", "tilt", nums("0 10 15 20 25 30 35 40 50") },
  { "Laps", "laps", nums("1 2 3 5 10") },
  { "Wind", "wind", { 0, 1, 2 }, { "Off", "Light", "Strong" } },
}
-- Betaflight "actual" rates: roll/pitch center, max (deg/s), expo %, then yaw (Soft, Normal, Fast);
-- racer, freestyle: prop pitch speed (m/s), rotor drag, side and top drag, motor and rate lag (s)
local RATES = nums("70 400 35 70 350 30 100 600 50 100 500 40 150 850 45 130 700 40")
local QP = nums("86 .22 .009 .028 .02 .012 60 .18 .0072 .024 .03 .02")

-- tracks: the names; each track's gates and structures are in StickTimeLite/t<number>.txt (made
-- by build.py from src/sticktime_lite_tracks.txt) and only read when the track is picked
local TRACKS = { @TRACKNAMES@ }
local NT = @NTRACKS@   --#fold
local GT, DR = 0.28, 0.15   --#fold (gate frame thickness, quad radius in m)
-- per gate type: inner half width (ring radius, flag zone), half height, default center height
local GW = { 1.5, 1.5, 2, 1.25, 2.4, 6, 6, 2.2 }
local GH = { 1, 1, 2, 1.25, 2.4, 30, 30, 1.8 }
local GY = { 1.35, 5.5, 7, 2.4, 0, 0, 0, 2 }

-- gates: center, normal n, right r, up-in-plane a, aim point A; pillars (trees, legs, poles):
-- x z radius height; structures: boxes
local NG, gx, gy, gz, gk, gd = 0, {}, {}, {}, {}, {}
local gnx, gny, gnz, grx, grz, gax, gay, gaz, AX, AY, AZ = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local NP, qx, qz, qr, qh = 0, {}, {}, {}, {}
local NB, bx0, bx1, by0, by1, bz0, bz1 = 0, {}, {}, {}, {}, {}, {}
local spx, spz, shx, shz, tx0, tx1, tz0, tz1, wdx, wdz = 0, 0, 0, 1, 0, 0, 0, 0, 0, 1  -- start, bounds, wind

local seed = 1
local function rnd()
  seed = seed * 171 % 30269
  return seed / 30269
end

local buildTrack
do
local CS = { -1, 1, 1, -1, -1, 1, 1, -1 }          -- corners of a gate: s = CS[c], u = CS[c + 3]

local function pillar(x, z, r, h)
  NP = NP + 1
  qx[NP], qz[NP], qr[NP], qh[NP] = x, z, r, h
end

-- t<number>.txt: tree seed, trees, gates (x z type yaw height), "/", structures (x z half-width
-- half-depth bottom top). Gate types: 1 gate, 2 high gate, 3 dive gate (flat: fly down through
-- it), 4 hoop, 5 arch, 6 flag (pass on its right), 7 flag (pass on its left), 8 gap in a structure
buildTrack = function(t)
  local path = "/SCRIPTS/TOOLS/StickTimeLite/t" .. t .. ".txt"
  local f = io.open(path, "r")
  local s = f and io.read(f, 700) or ""           -- (EdgeTX reads into a buffer of that size)
  if f then io.close(f) end
  local g, sb = string.match(s, "([^/]*)/?(.*)")
  local d, b = nums(g), nums(sb)
  if #d < 12 then error("StickTime Lite: track file " .. path .. " is missing") end
  NG, NP, NB = 0, 0, 0
  for i = 1, #b, 6 do
    NB = NB + 1
    bx0[NB], bx1[NB], bz0[NB], bz1[NB] = b[i] - b[i + 2], b[i] + b[i + 2], b[i + 1] - b[i + 3], b[i + 1] + b[i + 3]
    by0[NB], by1[NB] = b[i + 4], b[i + 5]
  end
  for i = 3, #d, 5 do
    NG = NG + 1
    local k, a = d[i + 2], d[i + 3] * 0.0174533
    local hx, hz, x, z, y = sin(a), cos(a), d[i], d[i + 1], d[i + 4]
    if y <= 0 then y = GY[k] end
    local ax, ay, az, Ax, Ay, Az = x, k == 5 and 1.4 or y, z, 0, 1, 0
    if k == 6 or k == 7 then
      -- (x, z) is the pole; the gate itself is the pass zone beside it
      local s = k == 6 and 1 or -1
      pillar(x, z, 0.12, 3.4)
      ax, ay, az = x + hz * s * 2.5, 1.8, z - hx * s * 2.5
      x, z = x + hz * s * 6, z - hx * s * 6
    end
    gx[NG], gy[NG], gz[NG], gk[NG], grx[NG], grz[NG], AX[NG], AY[NG], AZ[NG] = x, y, z, k, hz, -hx, ax, ay, az
    if k == 3 then
      gnx[NG], gny[NG], gnz[NG], Ax, Ay, Az = 0, -1, 0, hx, 0, hz
    else
      gnx[NG], gny[NG], gnz[NG] = hx, 0, hz
    end
    gax[NG], gay[NG], gaz[NG] = Ax, Ay, Az
    -- a stand under a hoop; legs: two for a high gate, four for a dive gate
    if k == 4 then pillar(x, z, 0.08, y - GW[4] - GT) end
    if k == 2 or k == 3 then
      local w, h = GW[k] + GT * 0.5, GH[k] + (k == 3 and GT * 0.5 or GT)
      for c = 1, 4 do
        local s_, u = CS[c], CS[c + 3]
        if k == 3 or u < 0 then pillar(x + hz * w * s_ + Ax * h * u, z - hx * w * s_ + Az * h * u, GT * 0.5, y + Ay * h * u) end
      end
    end
  end
  shx, shz = gnx[1], gnz[1]
  spx, spz = AX[1] - shx * 14, AZ[1] - shz * 14
  tx0, tx1, tz0, tz1 = spx, spx, spz, spz
  for i = 1, NG + NB do
    local x0, x1, z0, z1 = gx[i], gx[i], gz[i], gz[i]
    if i > NG then x0, x1, z0, z1 = bx0[i - NG], bx1[i - NG], bz0[i - NG], bz1[i - NG] end
    if x0 < tx0 then tx0 = x0 end
    if x1 > tx1 then tx1 = x1 end
    if z0 < tz0 then tz0 = z0 end
    if z1 > tz1 then tz1 = z1 end
  end
  seed = d[1]
  local a = rnd() * 6.2832
  wdx, wdz = sin(a), cos(a)
  -- trees, away from the racing line, the structures and the other pillars
  local want, trees, tries = d[2], 0, 0
  while trees < want and tries < want * 20 do
    tries = tries + 1
    local x, z, ok = tx0 - 30 + rnd() * (tx1 - tx0 + 60), tz0 - 30 + rnd() * (tz1 - tz0 + 60), true
    for i = 0, NG do
      local px_, pz_ = AX[i] or spx, AZ[i] or spz
      local j = i % NG + 1
      local dx, dz = AX[j] - px_, AZ[j] - pz_
      local u = ((x - px_) * dx + (z - pz_) * dz) / (dx * dx + dz * dz)
      if u < 0 then u = 0 elseif u > 1 then u = 1 end
      dx, dz = px_ + dx * u - x, pz_ + dz * u - z
      if dx * dx + dz * dz < 100 then ok = false end
    end
    for i = 1, NB do
      if x > bx0[i] - 4 and x < bx1[i] + 4 and z > bz0[i] - 4 and z < bz1[i] + 4 then ok = false end
    end
    for i = 1, NP do
      local dx, dz = x - qx[i], z - qz[i]
      if dx * dx + dz * dz < 36 then ok = false end
    end
    if ok then
      trees = trees + 1
      local h = 6 + rnd() * 6
      pillar(x, z, h * 0.14, h)
    end
  end
end
end

-- saved settings and bests per track: lap, time trial, freestyle combo, gate rush
local BL, BR, BF, BG = {}, {}, {}, {}
for t = 1, NT do BL[t], BR[t], BF[t], BG[t] = 0, 0, 0, 0 end
local save, load
do
local FILE = "/SCRIPTS/TOOLS/StickTimeLite/data.txt"
local OLD = "/SCRIPTS/TOOLS/FPVLite/data.txt"              -- the save under the old name, FPV Sim Lite

save = function()
  local s = "FPVLITE2"
  for k, v in pairs(S) do s = s .. " " .. k .. "=" .. floor(v) end
  for t = 1, NT do
    s = s .. " l" .. t .. "=" .. floor(BL[t]) .. " r" .. t .. "=" .. floor(BR[t]) .. " f" .. t .. "=" .. BF[t] .. " g" .. t .. "=" .. BG[t]
  end
  local f = io.open(FILE, "w")
  if f then
    io.write(f, s)
    io.close(f)
  end
end

load = function()
  local f, old = io.open(FILE, "r"), false
  if not f then f, old = io.open(OLD, "r"), true end
  if not f then return end
  local s = io.read(f, 600)
  io.close(f)
  local h = type(s) == "string" and string.sub(s, 1, 8)
  if h ~= "FPVLITE2" and h ~= "FPVLITE1" then return end
  for k, n, v in string.gmatch(s, "(%a+)(%d*)=(%d+)") do
    v, n = tonumber(v), tonumber(n)
    -- the first Lite had four tracks: its 4th, the Grand Prix, is the 6th now
    if h == "FPVLITE1" then
      if n == 4 then n = 6 end
      if k == "track" and v == 4 then v = 6 end
    end
    local B = k == "l" and BL or k == "r" and BR or k == "f" and BF or k == "g" and BG
    if B then
      if n and n >= 1 and n <= NT then B[n] = v end
    elseif k == "track" then
      if v >= 1 and v <= NT then S.track = v end
    else
      -- settings: only the values the menu offers
      for _, o in ipairs(OPTS) do
        for _, x in ipairs(o[3]) do
          if o[2] == k and x == v then S[k] = v end
        end
      end
    end
  end
  if old then save() end                            -- under the new name right away
end
end

-- -------------------------------------------------------------- the quad
local px, py, pz, vx, vy, vz = 0, DR, 0, 0, 0, 0                      -- position, velocity (m, m/s)
local rx, ry, rz, ux, uy, uz, fx, fy, fz = 1, 0, 0, 0, 1, 0, 0, 0, 1   -- right, up, forward
local sA, sE, sT, sR, speed = 0, 0, 0, 0, 0
local wr0, wp0, wy0, Tm, grounded = 0, 0, 0, 0, true                  -- body rates (rad/s), thrust
local state, gm, from = MENU, 1, FLY
local gt, lastT, tState, tStart, fi, pt, smp = 0, 0, 0, 0, 5, 0, 0     -- clocks (10 ms ticks)
local lap, nextGate, lastGate, lapStart, total = 0, 1, 0, nil, 0
local rn, rt, newBest, msg, msgT, cd = 0, 0, false, nil, 0, -1
local P, SP = {}, {}                                                   -- quad in use; freestyle respawn
local tc, ts, F = 0.94, 0.34, 54                                       -- camera tilt, focal length

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

-- Betaflight "actual" rates: center sensitivity c, max rate m (deg/s), expo e (%)
local function rate(x, c, m, e)
  local a, x2 = x < 0 and -x or x, x * x
  e = e * 0.01
  return (x * c + (m - c) * a * x * (x2 * x2 * e + 1 - e)) * 0.0174533
end

local function rotate(ar, ap, ay)
  -- (no '~= 0' on floats: EdgeTX 2.11/2.12 floors floats in int/float equality)
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
  if gm == 3 then
    -- freestyle: where the quad was 1-2 s before the crash
    if SP[1] then place(SP[1], SP[2] + 0.5, SP[3], SP[4], SP[5]) else place(spx, DR, spz, shx, shz) end
  elseif i > 0 then
    place(AX[i] + gnx[i] * 1.5, AY[i] - (gk[i] == 3 and 1.5 or 0), AZ[i] + gnz[i] * 1.5, AX[j] - AX[i], AZ[j] - AZ[i])
  else
    place(spx, DR, spz, shx, shz)
  end
end

local function finish()
  state, tState = DONE, gt
  save()
  playTone(1800, 120, 0, 0)
  playTone(2400, 300, 0, 0)
end

-- ------------------------------------------------------------ freestyle
local sc, ch, chn, cht, prx = 0, 0, 0, 0, 9        -- score; combo points, tricks, last trick; proximity
local trick, tricks
do
local acc, t0, idle, thr, nrot = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
local hiY, hiT, inv, prox = 0, 0, 0, 0
local NAME, PTS = { "ROLL", "ROLL", "BACKFLIP", "FRONTFLIP", "360", "360" }, { 100, 100, 50 }

trick = function(name, pts)
  pts = floor(pts)
  ch, chn, cht, msg, msgT = ch + pts, chn + 1, gt, name .. " +" .. pts, gt
  playTone(1400 + chn * 120, 50, 0, 0)
end

-- dt < 0: reset (start, crash: the combo is lost)
tricks = function(dt)
  if dt < 0 then
    for a = 1, 3 do acc[a], nrot[a], idle[a] = 0, 0, 0 end
    hiY, inv, prox, ch, chn = 0, 0, 0, 0, 0
    return
  end
  -- full turns about each body axis (330 deg counts): rolls, flips, 360s
  for a = 1, 3 do
    local w, s = a == 1 and wr0 or a == 2 and wp0 or wy0, acc[a]
    if (w > 1.5 and s >= 0) or (w < -1.5 and s <= 0) then
      if nrot[a] < 1 and s > -0.01 and s < 0.01 then t0[a], thr[a] = gt, 0 end
      s, thr[a], idle[a] = s + w * dt, thr[a] + sT * dt, 0
      if s > 5.76 + nrot[a] * 6.2832 or s < -5.76 - nrot[a] * 6.2832 then
        nrot[a] = nrot[a] + 1
        local dur = (gt - t0[a]) * 0.01
        local name, pts = NAME[a * 2 - (s > 0 and 1 or 0)], PTS[a]
        if a == 2 and s > 0 and dur > 0.8 and thr[a] > dur * 0.4 then name, pts = "POWER LOOP", 250 end
        if nrot[a] == 2 then name, pts = "DOUBLE " .. name, pts * 1.5
        elseif nrot[a] > 2 then name, pts = "MULTI " .. name, pts * 2 end
        trick(name, pts)
        t0[a], thr[a] = gt, 0
      end
    else
      idle[a] = idle[a] + dt
      if idle[a] > 0.3 then s, nrot[a] = 0, 0 end
    end
    acc[a] = s
  end
  -- dive: a fast drop of 10 m or more that ends under control; hang time upside down; proximity
  if py > hiY or gt - hiT > 200 then hiY, hiT = py, gt end
  if hiY - py > 10 and vy > -2 then
    trick("DIVE " .. floor(hiY - py) .. "m", 60 + (hiY - py) * 6)
    hiY, hiT = py, gt
  end
  if uy < -0.5 then inv = inv + dt
  else
    if inv > 0.8 then trick("HANG TIME", inv * 60) end
    inv = 0
  end
  if prx < 1.5 and speed > 8 then prox = prox + dt
  else
    if prox > 0.3 then trick("PROXY", prox * 150) end
    prox = 0
  end
  -- a combo ends 2.5 s after its last trick: points x (1 + 0.5 per extra trick, up to 4)
  if chn > 0 and gt - cht > 250 then
    local v = floor(ch * (chn > 6 and 4 or 0.5 + chn * 0.5))
    sc = sc + v
    if v > BF[S.track] then
      BF[S.track], newBest, msg, msgT = v, true, "COMBO " .. v .. " BEST!", gt
      save()
    elseif chn > 1 then
      msg, msgT = "COMBO " .. v, gt
    end
    ch, chn = 0, 0
  end
end
end

local function gatePassed(i, fwd)
  if state == DONE then return end
  if gm == 3 then
    if gk[i] < 6 or gk[i] > 7 then trick("GAP", 150) end
    return
  end
  if i ~= nextGate then return end
  if gm == 4 then
    -- gate rush: every gate adds time, the next one is picked at random (no flags)
    rn = rn + 1
    local b = 6 - rn * 0.15
    if b < 2.5 then b = 2.5 end
    rt, lastGate = rt + b, i
    for _ = 1, 30 do
      nextGate = floor(rnd() * NG) + 1
      if nextGate ~= i and (gk[nextGate] < 6 or gk[nextGate] > 7) then break end
    end
    msg, msgT = "+" .. floor(b * 10) / 10 .. "s", gt
    playTone(1300 + rn * 30, 60, 0, 0)
    return
  end
  if not fwd then return end
  lastGate, nextGate = i, i % NG + 1
  if i > 1 then playTone(1300 + i * 60, 60, 0, 0) return end
  if lapStart then
    local lt, t = gt - lapStart, S.track
    msg, msgT = ((BL[t] < 1 or lt < BL[t]) and "BEST " or "LAP ") .. timeStr(lt), gt
    if BL[t] < 1 or lt < BL[t] then BL[t] = lt end
    lap = lap + 1
    playTone(2200, 160, 0, 0)
    if gm == 1 and lap > S.laps then
      total, lap = gt - tStart, S.laps
      if BR[t] < 1 or total < BR[t] then BR[t], newBest = total, true end
      finish()
      return
    end
    save()
  else
    lap = 1
    playTone(1600, 80, 0, 0)
  end
  lapStart = gt
end

local physics
do
local nearG, nearP = {}, {}
-- returns true on a crash
physics = function(dt)
  local Tmax, wr, wp = S.twr * 9.81, 0, 0
  if S.mode == 2 then
    -- angle mode: steer the up vector towards the stick tilt (45 deg at full stick)
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
    -- resting on the ground: stays level, can only yaw
    wr, wp, wr0, wp0 = 0, 0, 0, 0
    if uy < 0.999 then place(px, DR, pz, fx, fz) end
  end
  -- wind with gusts, weaker near the ground
  local wx, wz = 0, 0
  if S.wind > 0 and py > 0.3 then
    local g = (S.wind == 1 and 3 or 7) * (1 + 0.3 * sin(gt * 0.009) + 0.2 * sin(gt * 0.031))
    if py < 4 then g = g * py * 0.25 end
    wx, wz = wdx * g, wdz * g
  end
  local n = floor(dt * 80) + 1
  local h = dt / n
  local km, kr, VP, KH, KS, KU, sTx = h / (P[11] + h), h / (P[12] + h), P[7], P[8], P[9], P[10], sqrt(Tmax)
  -- broad phase once per frame (flags: their zone reaches 12 m from the center)
  local reach, ng, np = speed * dt + 7, 0, 0
  for i = 1, NG do
    local dx, dy, dz, r = px - gx[i], py - gy[i], pz - gz[i], gk[i] > 5 and reach + 6 or reach
    if dx < r and dx > -r and dy < r and dy > -r and dz < r and dz > -r then
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
    -- props lose thrust with inflow speed; rotor drag in the prop plane; quadratic body drag
    -- (air-relative velocity)
    local ax_, az_ = vx - wx, vz - wz
    local vu, vr, vf = ax_ * ux + vy * uy + az_ * uz, ax_ * rx + vy * ry + az_ * rz, ax_ * fx + vy * fy + az_ * fz
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
    if py > 250 or px < tx0 - 160 or px > tx1 + 160 or pz < tz0 - 160 or pz > tz1 + 160 then return true end
    -- gates: crossings of each nearby gate plane
    for j = 1, ng do
      local i = nearG[j]
      local d1, d0 = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i], gd[i]
      gd[i] = d1
      if (d0 < 0) ~= (d1 < 0) then
        local t = d0 / (d0 - d1)
        local qx_, qy_, qz_ = ox_ + (px - ox_) * t - gx[i], oy_ + (py - oy_) * t - gy[i], oz_ + (pz - oz_) * t - gz[i]
        local lx, ly, k = qx_ * grx[i] + qz_ * grz[i], qx_ * gax[i] + qy_ * gay[i] + qz_ * gaz[i], gk[i]
        local w = GW[k]
        if k == 4 or k == 5 then
          -- hoop or arch: inside the ring, or into the ring itself
          local r2 = lx * lx + ly * ly
          if r2 < (w - DR * 0.5) ^ 2 then gatePassed(i, d1 >= 0)
          elseif r2 < (w + GT + DR) ^ 2 then return true end
        else
          lx, ly = lx < 0 and -lx or lx, ly < 0 and -ly or ly
          if lx < w - DR * 0.5 and ly < GH[k] - DR * 0.5 then gatePassed(i, d1 >= 0)
          elseif k < 4 and lx < w + GT + DR and ly < GH[k] + GT + DR then return true end
        end
        if state ~= FLY and state ~= DONE then return end
      end
    end
    -- trees, legs, poles and structures
    for j = 1, np do
      local i = nearP[j]
      local dx, dz = px - qx[i], pz - qz[i]
      if py < qh[i] and dx * dx + dz * dz < (qr[i] + DR) ^ 2 then return true end
    end
    for i = 1, NB do
      if px > bx0[i] - DR and px < bx1[i] + DR and pz > bz0[i] - DR and pz < bz1[i] + DR and py < by1[i] + DR and py > by0[i] - DR then
        return true
      end
    end
  end
  -- keep the axes orthonormal
  local l = 1 / sqrt(fx * fx + fy * fy + fz * fz)
  fx, fy, fz = fx * l, fy * l, fz * l
  local d = rx * fx + ry * fy + rz * fz
  rx, ry, rz = rx - d * fx, ry - d * fy, rz - d * fz
  l = 1 / sqrt(rx * rx + ry * ry + rz * rz)
  rx, ry, rz = rx * l, ry * l, rz * l
  ux, uy, uz = fy * rz - fz * ry, fz * rx - fx * rz, fx * ry - fy * rx
  speed = sqrt(vx * vx + vy * vy + vz * vz)
  if gm == 3 then
    -- freestyle: distance to the nearest surface, for proximity runs
    local m = py + 0.7
    for j = 1, np do
      local i = nearP[j]
      if py < qh[i] then
        local dx, dz = px - qx[i], pz - qz[i]
        d = sqrt(dx * dx + dz * dz) - qr[i]
        if d < m then m = d end
      end
    end
    for i = 1, NB do
      local dx, dy, dz = bx0[i] - px, by0[i] - py, bz0[i] - pz
      if px - bx1[i] > dx then dx = px - bx1[i] end
      if py - by1[i] > dy then dy = py - by1[i] end
      if pz - bz1[i] > dz then dz = pz - bz1[i] end
      dx, dy, dz = dx > 0 and dx or 0, dy > 0 and dy or 0, dz > 0 and dz or 0
      d = sqrt(dx * dx + dy * dy + dz * dz)
      if d < m then m = d end
    end
    prx = m
  end
end
end

local function start(m)
  gm, lap, nextGate, lastGate, lapStart, total = m, 0, 1, 0, nil, 0
  rn, rt, newBest, msg, cd, sc, smp = 0, 30, false, nil, -1, 0, gt
  for j = 1, 10 do SP[j] = nil end
  tricks(-1)
  place(spx, DR, spz, shx, shz)
  -- freestyle starts right away, the others after a countdown
  state, tState = m == 3 and READY or COUNT, gt
end

local function selectTrack(t)
  S.track = t
  buildTrack(t)
  collectgarbage()                                  -- what building left behind, before flying
  place(spx, DR, spz, shx, shz)
end

local function update(dt)
  if state == COUNT then
    local n = floor((gt - tState) / 100)
    if n ~= cd then
      cd = n
      playTone(n < 3 and 1000 or 2000, n < 3 and 120 or 400, 0, 0)
    end
    if n >= 3 then
      state, tStart, msg, msgT = FLY, gt, "GO!", gt
    end
  elseif state == FLY or state == DONE then
    if physics(dt) then
      if state == DONE then respawn() else
        state, tState = CRASHED, gt
        if gm == 3 then tricks(-1) end
        playTone(260, 400, 0, 0)
        if playHaptic then playHaptic(60, 0) end
      end
    elseif gm == 3 and state == FLY then
      tricks(dt)
      -- respawn point: where the quad was 1-2 s ago
      if gt - smp >= 100 then
        smp = gt
        for j = 1, 5 do SP[j] = SP[j + 5] end
        SP[6], SP[7], SP[8], SP[9], SP[10] = px, py, pz, fx, fz
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
  if gm == 4 and state ~= COUNT and state ~= DONE then
    rt = rt - dt
    if rt <= 0 then
      rt = 0
      if rn > BG[S.track] then BG[S.track], newBest = rn, true end
      finish()
    end
  end
end

-- ----------------------------------------------------------------- drawing
local render, handle
do
-- greyscale screens (212x64): grey ground, grey horizon and grid
local GREYS = type(GREY) == "function"
local GRD, GRY = FORCE, FORCE
if GREYS then GRD, GRY = GREY(12) + FORCE, GREY(7) + FORCE end
local RC, RS = {}, {}                              -- ring points every 30 deg
for j = 1, 12 do RC[j], RS[j] = cos(j * 0.5236), sin(j * 0.5236) end
-- camera position and axes; B&W screens show a frame right away (15 ms ahead)
local kx, ky, kz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1

-- B&W drawLine refuses points off the screen: clip in Lua (slab method)
local function line2(x1, y1, x2, y2, pat, fl)
  local dx, dy, t0_, t1 = x2 - x1, y2 - y1, 0, 1
  if dx > 1e-6 or dx < -1e-6 then
    local ta, tb = -x1 / dx, (XM - x1) / dx
    if ta > tb then ta, tb = tb, ta end
    if ta > t0_ then t0_ = ta end
    if tb < t1 then t1 = tb end
  elseif x1 < 0 or x1 > XM then return end
  if dy > 1e-6 or dy < -1e-6 then
    local ta, tb = -y1 / dy, (YM - y1) / dy
    if ta > tb then ta, tb = tb, ta end
    if ta > t0_ then t0_ = ta end
    if tb < t1 then t1 = tb end
  elseif y1 < 0 or y1 > YM then return end
  if t0_ <= t1 then
    drawLine(floor(x1 + dx * t0_ + 0.5), floor(y1 + dy * t0_ + 0.5), floor(x1 + dx * t1 + 0.5), floor(y1 + dy * t1 + 0.5), pat, fl)
  end
end

-- a world-space line: to camera space, cut at the near plane, project
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

-- a quadrilateral a b c d in world space
local function quad(a1, a2, a3, b1, b2, b3, c1, c2, c3, d1, d2, d3, p)
  line3(a1, a2, a3, b1, b2, b3, p, BLK)
  line3(b1, b2, b3, c1, c2, c3, p, BLK)
  line3(c1, c2, c3, d1, d2, d3, p, BLK)
  line3(d1, d2, d3, a1, a2, a3, p, BLK)
end

-- ------------------------------------------------------------------ menus
local focus, scroll, editing = 1, 0, false
local MAIN = { "Time trial", "Practice", "Freestyle", "Gate rush", "Track", "Settings", "Exit" }
local PAUSE = { "Resume", "Restart", "Menu" }

local function optIdx(o)
  for j = 1, #o[3] do
    if o[3][j] == S[o[2]] then return j end
  end
  return 1
end

local function box(y)
  lcd.drawFilledRectangle(8, y, XM - 15, YM + 1 - y * 2, ERASE)
  lcd.drawRectangle(8, y, XM - 15, YM + 1 - y * 2, BLK)
end

render = function()
  if state == MENU or state == SETUP then
    lcd.clear()
    local n, y = #MAIN, 15
    if state == MENU then
      local t = S.track
      local b = (focus == 1 and BR or BL)[t]
      drawText(1, 0, "StickTime", MIDSIZE)
      drawText(XM, 0, "LITE", SML + RIGHT)
      local u = XM > 127                            -- room for the units (212 px screens)
      drawText(XM, 7, "best " .. (focus == 3 and BF[t] .. (u and " pts" or "") or focus == 4 and BG[t] ..
        (u and " gates" or "") or b > 0 and timeStr(b) or "--"), SML + RIGHT)
    else
      drawText(1, 0, "SETTINGS", SML + INV)
      n, y = #OPTS + 1, 9
    end
    -- the list, scrolled to keep the focus in view
    local rows = floor((YM + 1 - y) / 8)
    if rows > n then rows = n end
    if focus - scroll > rows then scroll = focus - rows end
    if focus <= scroll then scroll = focus - 1 end
    for r = 1, rows do
      local i = scroll + r
      local o, f = OPTS[i], i == focus and INV or 0
      local l = o and o[1] or "Back"
      if state == MENU then
        l = MAIN[i]
        if i == 5 then
          l = TRACKS[S.track]
          l = editing and "< " .. l .. " >" or "Track: " .. l
        end
      end
      drawText(2, y, l, SML + ((editing and state == SETUP) and 0 or f))
      if state == SETUP and o then
        local j = optIdx(o)
        drawText(XM - 1, y, type(o[4]) == "table" and o[4][j] or o[3][j] .. (o[4] or ""), SML + RIGHT + (editing and f or 0))
      end
      y = y + 8
    end
    return
  end
  do
  -- camera: where the quad will be when the frame shows, tilted up
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
  -- ground (grey on greyscale screens), horizon, then a 10 m grid on the ground
  local a, b, c = kry, kuy, F * kfy
  local A, B = a < 0 and -a or a, b < 0 and -b or b
  if GREYS then
    for y = 0, YM do
      local e = c - (y - CY) * b
      if A < 1e-5 then
        if e < 0 then drawLine(0, y, XM, y, SOLID, GRD) end
      else
        local xh = CX - e / a
        if a > 0 then
          if xh > 0 then drawLine(0, y, xh < XM and floor(xh) or XM, y, SOLID, GRD) end
        elseif xh < XM then
          drawLine(xh > 0 and floor(xh) or 0, y, XM, y, SOLID, GRD)
        end
      end
    end
  end
  if A <= B then
    if B > 1e-5 then line2(0, CY + (c - CX * a) / b, XM, CY + (c + (XM - CX) * a) / b, SOLID, GRY) end
  else
    line2(CX + (-CY * b - c) / a, 0, CX + ((YM - CY) * b - c) / a, YM, SOLID, GRY)
  end
  local gx0, gz0 = floor(kx / 10) * 10, floor(kz / 10) * 10
  for i = -3, 4 do
    line3(gx0 + i * 10, 0, gz0 - 35, gx0 + i * 10, 0, gz0 + 35, DOTTED, GRY)
    line3(gx0 - 35, 0, gz0 + i * 10, gx0 + 35, 0, gz0 + i * 10, DOTTED, GRY)
  end
  -- gates in view: the next one solid, far ones dotted and without the inner frame
  for i = 1, NG do
    local k = gk[i]
    local dx, dy, dz, r = gx[i] - kx, gy[i] - ky, gz[i] - kz, k > 5 and 10 or 4
    local z, x = dx * kfx + dy * kfy + dz * kfz, dx * krx + dy * kry + dz * krz
    if z > -r and z < 90 and (x < 0 and -x or x) < z * 1.19 + r then
      local nxt = i == nextGate and gm ~= 3
      local p, w, h = (nxt or z < 12) and SOLID or DOTTED, GW[k], GH[k]
      if k == 6 or k == 7 then
        -- flag: a cloth on the outer side of the pole (the pole is drawn with the pillars)
        local s = k == 6 and w or -w
        local x1, z1 = gx[i] - grx[i] * s, gz[i] - grz[i] * s
        local x2, z2 = x1 - grx[i] * s * 0.15, z1 - grz[i] * s * 0.15
        line3(x1, 3.4, z1, x2, 2.9, z2, SOLID, BLK)
        line3(x2, 2.9, z2, x1, 1.7, z1, SOLID, BLK)
        if nxt then line3(x1, 2.9, z1, x2, 2.9, z2, SOLID, BLK) end
      elseif k == 4 or k == 5 then
        -- hoop (12 sides) or arch (half a ring): the outer ring, and the inner one when near
        w = w + GT
        for _ = 1, (nxt or z < 30) and 2 or 1 do
          local X, Y, Z = gx[i] + grx[i] * w, gy[i], gz[i] + grz[i] * w
          for j = 1, k == 4 and 12 or 6 do
            local c_, s_ = RC[j] * w, RS[j] * w
            local X2, Y2, Z2 = gx[i] + grx[i] * c_ + gax[i] * s_, gy[i] + gay[i] * s_, gz[i] + grz[i] * c_ + gaz[i] * s_
            line3(X, Y, Z, X2, Y2, Z2, p, BLK)
            X, Y, Z = X2, Y2, Z2
          end
          w = GW[k]
        end
      elseif k < 4 or nxt then
        -- a frame: outer and inner rectangle (one when far); a gap: only the next one, thin
        if k < 4 then w, h = w + GT, h + GT end
        for _ = 1, (k < 4 and (nxt or z < 30)) and 2 or 1 do
          local Rx, Rz, Ax, Ay, Az = grx[i] * w, grz[i] * w, gax[i] * h, gay[i] * h, gaz[i] * h
          quad(gx[i] - Rx - Ax, gy[i] - Ay, gz[i] - Rz - Az, gx[i] + Rx - Ax, gy[i] - Ay, gz[i] + Rz - Az,
               gx[i] + Rx + Ax, gy[i] + Ay, gz[i] + Rz + Az, gx[i] - Rx + Ax, gy[i] + Ay, gz[i] - Rz + Az, p)
          w, h = GW[k], GH[k]
        end
      end
    end
  end
  -- structures: the faces turned to the camera
  for i = 1, NB do
    local x0, x1, y0, y1, z0, z1 = bx0[i], bx1[i], by0[i], by1[i], bz0[i], bz1[i]
    local dx, dy, dz, r = (x0 + x1) * 0.5 - kx, (y0 + y1) * 0.5 - ky, (z0 + z1) * 0.5 - kz, x1 - x0 + y1 - y0 + z1 - z0
    local z, x = dx * kfx + dy * kfy + dz * kfz, dx * krx + dy * kry + dz * krz
    if z > -r and z < 90 + r and (x < 0 and -x or x) < z * 1.19 + r then
      local p = z < 60 and SOLID or DOTTED
      local f = kx < x0 and x0 or kx > x1 and x1
      if f then quad(f, y0, z0, f, y1, z0, f, y1, z1, f, y0, z1, p) end
      f = kz < z0 and z0 or kz > z1 and z1
      if f then quad(x0, y0, f, x1, y0, f, x1, y1, f, x0, y1, f, p) end
      f = ky > y1 and y1 or ky < y0 and y0
      if f then quad(x0, f, z0, x1, f, z0, x1, f, z1, x0, f, z1, p) end
    end
  end
  -- trees, legs and poles: a vertical line; trees get a canopy facing the camera
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
  if state == DONE then
    box(4)
    drawText(12, 7, newBest and "NEW RECORD!" or gm == 4 and "TIME UP" or "FINISHED", SML + INV)
    drawText(12, 17, gm == 4 and "Gates " .. rn .. "  best " .. BG[S.track] or "Total " .. timeStr(total), SML)
    if gm < 3 then drawText(12, 26, "Best lap " .. timeStr(BL[S.track]), SML) end
    drawText(12, YM - 15, "ENTER again  EXIT menu", SML)
    return
  end
  do
  -- HUD: lap time and lap, or score and combo, or time left and gates
  if gm == 3 then
    lcd.drawNumber(1, 1, sc, SML + LEFT)
    if chn > 0 then drawText(XM, 1, "x" .. chn .. " " .. ch, SML + RIGHT) end
  else
    local l = gm < 3
    lcd.drawNumber(1, 1, l and floor((lapStart and gt - lapStart or 0) / 10) or floor(rt * 10), PREC1 + SML + LEFT)
    drawText(XM, 1, l and ((lap > 0 and lap or 1) .. (gm == 1 and "/" .. S.laps or "")) or rn .. "", SML + RIGHT)
    -- next gate off screen: a marker at the edge on its side
    local i = nextGate
    local dx, dy, dz = AX[i] - kx, AY[i] - ky, AZ[i] - kz
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
  end
  local th = floor(sT * 30)
  if th > 0 then lcd.drawFilledRectangle(0, YM - th, 2, th, BLK) end
  drawLine(CX - 4, CY, CX - 2, CY, SOLID, BLK)
  drawLine(CX + 2, CY, CX + 4, CY, SOLID, BLK)
  if msg and gt - msgT < 200 then drawText(CX, 10, msg, SML + CENTER) end
  end
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

local E_ENTER, E_EXIT = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK
local E_NEXT, E_PREV, E_INC, E_DEC = EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV, EVT_VIRTUAL_INC, EVT_VIRTUAL_DEC
handle = function(e)
  local nav = e == E_NEXT and 1 or e == E_PREV and -1 or 0
  if state == MENU or state == SETUP then
    local n = state == MENU and #MAIN or #OPTS + 1
    if editing then
      -- INC and DEC: the wheel, +/- or up/down, the same on every radio
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
      elseif focus <= 4 then start(focus)
      elseif focus == 5 then editing = true
      elseif focus == 6 then state, focus, scroll = SETUP, 1, 0
      else return 1 end
    end
    if e == E_EXIT then
      if state == MENU then return 1 end
      save()
      state, focus, scroll = MENU, 6, 0
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
end

-- ------------------------------------------------------------------ entry
local function init()
  for i = 1, 4 do
    local f = getFieldInfo and getFieldInfo(SRC[i])
    if f then SRC[i] = f.id end
  end
  load()
  apply()
  selectTrack(S.track)
  lastT = getTime()
--#if TEST
  local T = STICKTIME_TEST
  if T then
    T.get = function() return px, py, pz, vx, vy, vz, fx, fy, fz, ux, uy, uz, rx, ry, rz, state, lap, nextGate, NG, gt end
    T.gate = function(i) return gx[i], gy[i], gz[i], gnx[i], gny[i], gnz[i], gk[i], AX[i], AY[i], AZ[i] end
    T.start = start
    T.track = selectTrack
    T.state = function(s) state = s end
    T.set = function(k, v) S[k] = v apply() end
    T.pose = function(x, y, z, yaw, pitch, roll)
      yaw = yaw * 0.0174533
      place(x, y, z, sin(yaw), cos(yaw))
      rotate(0, pitch * 0.0174533, 0)
      rotate(roll * 0.0174533, 0, 0)
    end
    T.vel = function(a, b, c) vx, vy, vz = a, b, c end
    T.next = function(i) nextGate, lastGate = i, (i - 2) % NG + 1 end
    T.lapclock = function(t) lapStart, tStart, msgT = gt - t, gt - t, gt - 1000 if lap < 1 then lap = 1 end end
    T.info = function() return NT, S.twr, gm, lap, total, rn, rt, TRACKS[S.track], NP, sc, chn, NB end
    T.best = function(t) return BL[t], BR[t], BG[t], BF[t] end
    T.ntracks = function() return NT end
    T.nmodes = function() return 4 end
    T.S = S
  end
--#endif
end

local function run(event)
  local now = getTime()
  local dtk = now - lastT
  lastT = now
  dtk = dtk > 10 and 10 or dtk < 0 and 0 or dtk
  -- smoothed frame interval (getTime() ticks every 10 ms); sim time within a tick of the clock
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
