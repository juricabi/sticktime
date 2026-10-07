local toolName = "TNS|FPV Sim BW|TNE"
--[[ ======================================================================
  FPV Sim BW v1.0  -  a real 3D FPV quad simulator that runs on your radio
  Black & white version - EdgeTX 128x64 and 212x64 radios

  Install : copy this file to /SCRIPTS/TOOLS/ on the radio SD card and
            start it from SYS > TOOLS (or SD card browser > Execute).
  Fly     : your sticks fly the quad (acro or angle mode). The radio
            handles stick mode 1-4. EXIT = pause/back, ENTER = select,
            rotary / +- / up-down = move. Touch screens: tap.
  Safety  : the radio keeps transmitting while the sim runs - keep the
            real quad unplugged or the RF module off.
  Credits : inspired by lua-fpv-sim by Alexey Stankevich (@AlexeyStn);
            this is an independent rewrite with a full 3D engine.
====================================================================== ]]

local lcd = lcd
local sqrt, sin, cos, floor = math.sqrt, math.sin, math.cos, math.floor
local fmt = string.format
local getValue, getTime = getValue, getTime
local W, H = LCD_W, LCD_H
local drawLine, fillRect, drawText, drawNumber = lcd.drawLine, lcd.drawFilledRectangle, lcd.drawText, lcd.drawNumber
local SOLID, DOTTED = SOLID, DOTTED
local TEST = FPVSIM_TEST
local XM, YM = W - 1, H - 1
local BLK = FORCE          -- B&W default draw mode is XOR: FORCE sets pixels black

local EV = {
  ENTER = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EXIT = EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK,
  NEXT = EVT_VIRTUAL_NEXT, PREV = EVT_VIRTUAL_PREV, INC = EVT_VIRTUAL_INC, DEC = EVT_VIRTUAL_DEC,
  TAP = EVT_TOUCH_TAP,
}

-- game states
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8

-- ------------------------------------------------------------ settings
local S = { track = 1, mode = 1, rates = 2, tilt = 20, fov = 100, power = 2, laps = 3, map = 1, sticks = 0, fps = 0 }
local KEYS = { "track", "mode", "rates", "tilt", "fov", "power", "laps", "map", "sticks", "fps" }
local OPTS = {
  { "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
  { "Rates", "rates", { 1, 2, 3 }, { "Soft", "Normal", "Fast" } },
  { "Camera tilt", "tilt", { 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50 }, nil, "" },
  { "Field of view", "fov", { 80, 90, 100, 110, 120 }, nil, "" },
  { "Power", "power", { 1, 2, 3 }, { "Low 3:1", "Mid 4:1", "High 6:1" } },
  { "Race laps", "laps", { 1, 2, 3, 5, 10 } },
  { "Show FPS", "fps", { 0, 1 }, { "Off", "On" } },
}
-- Betaflight "actual" rates (center deg/s, max deg/s, expo) and thrust/weight
local CFG = { rc = { 70, 100, 150 }, rm = { 400, 600, 850 }, re = { 0.35, 0.5, 0.45 }, twr = { 3, 4, 6 } }

-- -------------------------------------------------------------- tracks
-- gate list: x, z, type, yaw(deg). type 1 = gate on the ground,
-- 2 = high gate on legs, 3 = dive gate (flat, fly down through it)
local TRACKS = {
  { "Meadow", 11, { 0,0,1,0, 6,34,1,20, 26,58,2,70, 56,52,1,120, 66,22,1,180, 52,-8,2,230, 24,-22,1,270 } },
  { "Figure 8", 23, { -14,10,1,0, 6,46,2,40, 18,68,1,0, 0,88,1,-90, -18,68,1,180, 18,16,1,180, 0,-4,1,-90 } },
  { "Dive Tower", 37, { 0,0,1,0, 10,30,1,20, 12,60,2,0, 0,84,2,-90, -28,84,3,-90, -36,52,1,180, -28,20,1,160, -12,-14,1,60 } },
}
local NT = #TRACKS
local GT = 0.28                       -- gate frame thickness (m)
local GHW = { 1.5, 1.5, 2.0 }         -- inner half width per type
local GHH = { 1.0, 1.0, 2.0 }         -- inner half height per type
local GCY = { 1.35, 5.5, 7.0 }        -- center height per type

-- gates (struct of arrays: fast indexed access in the hot loops)
local NG, gx, gy, gz, gk, gd = 0, {}, {}, {}, {}, {}
local gnx, gny, gnz, grx, grz, gax, gay, gaz = {}, {}, {}, {}, {}, {}, {}, {}
-- pillars: trees (k=1) and gate legs (k=2) - also used for collisions
local NP, qx, qz, qr, qh, qk = 0, {}, {}, {}, {}, {}
-- start pad and track bounds
local TR = { px = 0, pz = -14, hx = 0, hz = 1, x0 = 0, x1 = 1, z0 = 0, z1 = 1 }

local buildTrack
do
  local seed = 1
  local function rnd()
    seed = seed * 171 % 30269
    return seed / 30269
  end
  local function addPillar(x, z, r, h, k)
    NP = NP + 1
    qx[NP], qz[NP], qr[NP], qh[NP], qk[NP] = x, z, r, h, k
  end
  local function segDist2(x, z, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local l = dx * dx + dz * dz
    local t = 0
    if l > 0 then t = ((x - ax) * dx + (z - az) * dz) / l end
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    dx, dz = ax + dx * t - x, az + dz * t - z
    return dx * dx + dz * dz
  end
  buildTrack = function(t)
    local d = TRACKS[t][3]
    NG, NP = 0, 0
    for i = 1, #d, 4 do
      NG = NG + 1
      local k, yaw = d[i + 2], d[i + 3] * 0.0174533
      local hx, hz = sin(yaw), cos(yaw)
      local x, z, y = d[i], d[i + 1], GCY[k]
      gx[NG], gy[NG], gz[NG], gk[NG] = x, y, z, k
      grx[NG], grz[NG] = hz, -hx
      if k == 3 then
        gnx[NG], gny[NG], gnz[NG] = 0, -1, 0
        gax[NG], gay[NG], gaz[NG] = hx, 0, hz
      else
        gnx[NG], gny[NG], gnz[NG] = hx, 0, hz
        gax[NG], gay[NG], gaz[NG] = 0, 1, 0
      end
      local iw, ih = GHW[k], GHH[k]
      if k == 2 then
        local o = iw + GT * 0.5
        addPillar(x + hz * o, z - hx * o, GT * 0.5, y - ih - GT, 2)
        addPillar(x - hz * o, z + hx * o, GT * 0.5, y - ih - GT, 2)
      elseif k == 3 then
        local ow, oh = iw + GT * 0.5, ih + GT * 0.5
        for sx = -1, 1, 2 do
          for sz = -1, 1, 2 do
            addPillar(x + hz * ow * sx + hx * oh * sz, z - hx * ow * sx + hz * oh * sz, GT * 0.5, y, 2)
          end
        end
      end
    end
    TR.hx, TR.hz = gnx[1], gnz[1]
    TR.px, TR.pz = gx[1] - TR.hx * 14, gz[1] - TR.hz * 14
    local x0, x1, z0, z1 = TR.px, TR.px, TR.pz, TR.pz
    for i = 1, NG do
      if gx[i] < x0 then x0 = gx[i] end
      if gx[i] > x1 then x1 = gx[i] end
      if gz[i] < z0 then z0 = gz[i] end
      if gz[i] > z1 then z1 = gz[i] end
    end
    TR.x0, TR.x1, TR.z0, TR.z1 = x0, x1, z0, z1
    -- scenery trees, kept away from the racing line
    seed = TRACKS[t][2]
    local n, tries = 0, 0
    while n < 8 and tries < 300 do
      tries = tries + 1
      local x = x0 - 30 + rnd() * (x1 - x0 + 60)
      local z = z0 - 30 + rnd() * (z1 - z0 + 60)
      local ok = segDist2(x, z, TR.px, TR.pz, gx[1], gz[1]) > 100
      for i = 1, NG do
        local j = i % NG + 1
        if ok and segDist2(x, z, gx[i], gz[i], gx[j], gz[j]) < 100 then ok = false end
      end
      for i = 1, NP do
        local dx, dz = x - qx[i], z - qz[i]
        if ok and dx * dx + dz * dz < 36 then ok = false end
      end
      if ok then
        n = n + 1
        local h = 6 + rnd() * 6
        addPillar(x, z, h * 0.14, h, 1)
      end
    end
  end
end

-- --------------------------------------------------------- persistence
local bestLap, bestRace = {}, {}
for t = 1, NT do bestLap[t], bestRace[t] = 0, 0 end
local DATA = "/SCRIPTS/TOOLS/FPVSimBW.dat"

local function loadData()
  local f = io.open(DATA, "r")
  if not f then return end
  local s = io.read(f, 512)
  io.close(f)
  if type(s) ~= "string" or string.sub(s, 1, 6) ~= "FPVSIM" then return end
  local v, n = {}, 0
  for num in string.gmatch(s, "%-?%d+") do
    n = n + 1
    v[n] = tonumber(num)
  end
  for i = 1, #KEYS do
    if v[i] then S[KEYS[i]] = v[i] end
  end
  for t = 1, NT do
    bestLap[t] = v[#KEYS + t * 2 - 1] or 0
    bestRace[t] = v[#KEYS + t * 2] or 0
  end
  if S.track < 1 or S.track > NT then S.track = 1 end
end

local function saveData()
  local s = "FPVSIM"
  for i = 1, #KEYS do s = s .. " " .. floor(S[KEYS[i]]) end
  for t = 1, NT do s = s .. " " .. floor(bestLap[t]) .. " " .. floor(bestRace[t]) end
  local f = io.open(DATA, "w")
  if f then
    io.write(f, s .. "\n")
    io.close(f)
  end
end

-- ----------------------------------------------------------- game state
local px, py, pz, vx, vy, vz = 0, 0.15, 0, 0, 0, 0                 -- quad position / velocity (m, m/s)
local rx, ry, rz, ux, uy, uz, fx, fy, fz = 1, 0, 0, 0, 1, 0, 0, 0, 1 -- quad right / up / forward axes
local sA, sE, sT, sR, speed = 0, 0, 0, 0, 0                           -- sticks, speed
local DR, NEAR = 0.15, 0.2                                            -- quad radius, camera near plane
local P = { rc = 100, rm = 600, re = 0.5, twr = 4, angle = false, tc = 0.9, ts = 0.42 }
local state, prevState, pausedFrom, gmode = MENU, MENU, FLY, 1      -- gmode: 1 race, 2 practice, 3 free fly
local gt, lastT, tState, tStart = 0, 0, 0, 0                          -- game clock in 10 ms ticks
local lapStart, lap, nextGate, lastGate = nil, 0, 1, 0
local R = { laps = {}, n = 0, total = 0, newLap = false, newRace = false, msg = nil, msgT = 0, good = true,
            ready = 0, crashes = 0, cn = -1, fps = 0, fpsN = 0, fpsT = 0 }

local function timeStr(cs)
  cs = floor(cs)
  local s = floor(cs / 100)
  if s >= 60 then return fmt("%d:%02d.%02d", floor(s / 60), s % 60, cs % 100) end
  return fmt("%d.%02d", s, cs % 100)
end

local function beep(f, d, flags)
  if playTone then playTone(f, d, 0, flags or 0) end
end

local function showMsg(s, good)
  R.msg, R.msgT, R.good = s, gt, good
end

-- -------------------------------------------------------------- physics
local readSticks, rotate, placeDrone, respawn, physics
do
  local G, KQ, KL, KU = 9.81, 0.022, 0.12, 0.9
  local SRC = { "ail", "ele", "thr", "rud" }
  local grounded = true
  local nearG, nearP = {}, {}

  local function clamp1(v)
    if v > 1 then return 1 elseif v < -1 then return -1 end
    return v
  end

  readSticks = function(resolve)
    if resolve then
      for i = 1, 4 do
        local f = getFieldInfo and getFieldInfo(SRC[i])
        if f then SRC[i] = f.id end
      end
      return
    end
    sA = clamp1(getValue(SRC[1]) / 1024)
    sE = clamp1(getValue(SRC[2]) / 1024)
    sR = clamp1(getValue(SRC[4]) / 1024)
    sT = (getValue(SRC[3]) + 1024) / 2048
    if sT < 0 then sT = 0 elseif sT > 1 then sT = 1 end
  end

  local function rate(x)
    local a = x < 0 and -x or x
    local x2 = x * x
    return (x * P.rc + (P.rm - P.rc) * a * x * (x2 * x2 * P.re + 1 - P.re)) * 0.0174533
  end

  rotate = function(ar, ap, ay)
    -- (no '~= 0' on floats: EdgeTX 2.11/2.12 floors floats in int/float equality, so 0.02 ~= 0 is false there)
    if ar > 1e-7 or ar < -1e-7 then  -- roll right
      local c, s = cos(ar), sin(ar)
      rx, ry, rz, ux, uy, uz = rx * c - ux * s, ry * c - uy * s, rz * c - uz * s, ux * c + rx * s, uy * c + ry * s, uz * c + rz * s
    end
    if ap > 1e-7 or ap < -1e-7 then  -- pitch nose up
      local c, s = cos(ap), sin(ap)
      fx, fy, fz, ux, uy, uz = fx * c + ux * s, fy * c + uy * s, fz * c + uz * s, ux * c - fx * s, uy * c - fy * s, uz * c - fz * s
    end
    if ay > 1e-7 or ay < -1e-7 then  -- yaw right
      local c, s = cos(ay), sin(ay)
      fx, fy, fz, rx, ry, rz = fx * c + rx * s, fy * c + ry * s, fz * c + rz * s, rx * c - fx * s, ry * c - fy * s, rz * c - fz * s
    end
  end

  local function orthonormalize()
    local l = 1 / sqrt(fx * fx + fy * fy + fz * fz)
    fx, fy, fz = fx * l, fy * l, fz * l
    local d = rx * fx + ry * fy + rz * fz
    rx, ry, rz = rx - d * fx, ry - d * fy, rz - d * fz
    l = 1 / sqrt(rx * rx + ry * ry + rz * rz)
    rx, ry, rz = rx * l, ry * l, rz * l
    ux, uy, uz = fy * rz - fz * ry, fz * rx - fx * rz, fx * ry - fy * rx
  end

  placeDrone = function(x, y, z, hx, hz)
    px, py, pz, vx, vy, vz = x, y, z, 0, 0, 0
    local l = sqrt(hx * hx + hz * hz)
    hx, hz = hx / l, hz / l
    fx, fy, fz, rx, ry, rz, ux, uy, uz = hx, 0, hz, hz, 0, -hx, 0, 1, 0
    grounded = y <= DR + 0.01
    speed = 0
    for i = 1, NG do
      gd[i] = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i]
    end
  end

  respawn = function()
    if lastGate > 0 and gmode ~= 3 then
      local i, j = lastGate, nextGate
      local y = gy[i]
      if gk[i] == 3 then y = y - 1.5 end
      placeDrone(gx[i] + gnx[i] * 1.5, y, gz[i] + gnz[i] * 1.5, gx[j] - gx[i], gz[j] - gz[i])
    else
      placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
    end
  end

  local function crash()
    if state == DONE then respawn() return end
    state, tState, R.crashes = CRASHED, gt, R.crashes + 1
    beep(260, 400, PLAY_NOW)
    if playHaptic then playHaptic(60, 0) end
  end

  local function finishRace()
    R.total = gt - tStart
    local t = S.track
    if bestRace[t] == 0 or R.total < bestRace[t] then
      bestRace[t], R.newRace = R.total, true
    end
    state, tState = DONE, gt
    saveData()
    beep(1800, 120)
    beep(2400, 300)
  end

  local function gatePassed(i)
    if gmode == 3 or i ~= nextGate then return end
    lastGate, nextGate = i, i % NG + 1
    if i == 1 then
      if lapStart then
        local lt = gt - lapStart
        R.n = R.n + 1
        R.laps[R.n] = lt
        local b = bestLap[S.track]
        if b == 0 or lt < b then
          bestLap[S.track], R.newLap = lt, true
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  BEST!", true)
          saveData()
        else
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  +" .. timeStr(lt - b), false)
        end
        lap = lap + 1
        beep(2200, 160)
        if playHaptic then playHaptic(25, 0) end
        if gmode == 1 and lap > S.laps then finishRace() return end
      else
        lap = 1
        beep(1600, 80)
      end
      lapStart = gt
    else
      beep(1300 + i * 60, 60)
    end
  end

  physics = function(dt)
    local wr, wp
    if P.angle then
      -- self level: steer the up vector towards the stick-commanded tilt
      local hx, hz = -rz, rx
      local l = sqrt(hx * hx + hz * hz) + 0.0001
      hx, hz = hx / l, hz / l
      local tp, tr = sE * 0.9, sA * 0.9
      local dx, dz = hx * tp + hz * tr, hz * tp - hx * tr
      wr, wp = 7 * (dx * rx + ry + dz * rz), -7 * (dx * fx + fy + dz * fz)
      if wr > 7 then wr = 7 elseif wr < -7 then wr = -7 end
      if wp > 7 then wp = 7 elseif wp < -7 then wp = -7 end
    else
      wr, wp = rate(sA), -rate(sE)
    end
    local wy = rate(sR)
    local T = P.twr * G * (0.04 + 0.96 * sT ^ 1.6)
    if grounded and T < G * 1.02 then
      -- resting on the ground: stays level, can only yaw
      wr, wp = 0, 0
      if uy < 0.999 then placeDrone(px, DR, pz, fx, fz) end
    end
    local n = floor(dt * 80) + 1
    local h = dt / n
    local x0, x1, z0, z1 = TR.x0 - 160, TR.x1 + 160, TR.z0 - 160, TR.z1 + 160
    -- broad phase once per frame: only gates/pillars within reach get tested per substep
    local reach = speed * dt + 7
    local ng, np = 0, 0
    for i = 1, NG do
      local dx, dy, dz = px - gx[i], py - gy[i], pz - gz[i]
      if dx < reach and dx > -reach and dy < reach and dy > -reach and dz < reach and dz > -reach then
        ng = ng + 1
        nearG[ng] = i
      else
        gd[i] = dx * gnx[i] + dy * gny[i] + dz * gnz[i]   -- keep the side-of-plane fresh
      end
    end
    for i = 1, NP do
      local dx, dz, r = px - qx[i], pz - qz[i], reach + qr[i]
      if dx < r and dx > -r and dz < r and dz > -r then
        np = np + 1
        nearP[np] = i
      end
    end
    for _ = 1, n do
      rotate(wr * h, wp * h, wy * h)
      local vu = vx * ux + vy * uy + vz * uz
      local sp = sqrt(vx * vx + vy * vy + vz * vz)
      local k, a = KQ * sp + KL, T - KU * vu
      vx = vx + (ux * a - k * vx) * h
      vy = vy + (uy * a - k * vy - G) * h
      vz = vz + (uz * a - k * vz) * h
      local ox, oy, oz = px, py, pz
      px, py, pz = px + vx * h, py + vy * h, pz + vz * h
      grounded = false
      if py < DR then
        if vy < -5.5 or sp > 13 or uy < 0.35 then crash() return end
        py, grounded = DR, true
        if vy < 0 then vy = 0 end
        local fr = 1 - 7 * h
        vx, vz = vx * fr, vz * fr
      end
      if py > 120 or px < x0 or px > x1 or pz < z0 or pz > z1 then crash() return end
      -- gates: detect crossings of each nearby gate plane
      for j = 1, ng do
        local i = nearG[j]
        local cx, cy, cz = gx[i], gy[i], gz[i]
        local d1 = (px - cx) * gnx[i] + (py - cy) * gny[i] + (pz - cz) * gnz[i]
        local d0 = gd[i]
        gd[i] = d1
        if (d0 < 0) ~= (d1 < 0) then
          local t = d0 / (d0 - d1)
          local qx_, qy_, qz_ = ox + (px - ox) * t - cx, oy + (py - oy) * t - cy, oz + (pz - oz) * t - cz
          local lx = qx_ * grx[i] + qz_ * grz[i]
          local ly = qx_ * gax[i] + qy_ * gay[i] + qz_ * gaz[i]
          if lx < 0 then lx = -lx end
          if ly < 0 then ly = -ly end
          local iw, ih = GHW[gk[i]], GHH[gk[i]]
          if lx < iw - DR * 0.5 and ly < ih - DR * 0.5 then
            if d1 >= 0 then gatePassed(i) end
          elseif lx < iw + GT + DR and ly < ih + GT + DR then
            crash() return
          end
        end
      end
      -- trees and gate legs
      for j = 1, np do
        local i = nearP[j]
        local dx, dz, r = px - qx[i], pz - qz[i], qr[i] + DR
        if dx < r and dx > -r and dz < r and dz > -r and py < qh[i] and dx * dx + dz * dz < r * r then crash() return end
      end
    end
    orthonormalize()
    speed = sqrt(vx * vx + vy * vy + vz * vz)
  end
end

-- --------------------------------------------------------------- camera
local kpx, kpy, kpz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1
local PORTRAIT = H > W
local VX, VY, VW, VH = 0, 0, W, H
if PORTRAIT then VH = floor(W * 3 / 4) end
local CX, CY = VX + VW / 2, VY + VH / 2
local SC = VW / 128
local F, tanH = 160, 1.4

local function fpvCamera()
  local c, s = P.tc, P.ts
  kpx, kpy, kpz = px, py, pz
  krx, kry, krz = rx, ry, rz
  kfx, kfy, kfz = fx * c + ux * s, fy * c + uy * s, fz * c + uz * s
  kux, kuy, kuz = ux * c - fx * s, uy * c - fy * s, uz * c - fz * s
end

local function orbitCamera()
  local a = gt * 0.0012
  local cxw, czw = (TR.x0 + TR.x1) * 0.5, (TR.z0 + TR.z1) * 0.5
  local r = (TR.x1 - TR.x0 + TR.z1 - TR.z0) * 0.35 + 18
  kpx, kpy, kpz = cxw + r * sin(a), 9 + 3 * sin(a * 1.7), czw + r * cos(a)
  local dx, dy, dz = cxw - kpx, 1 - kpy, czw - kpz
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  kfx, kfy, kfz = dx / l, dy / l, dz / l
  l = sqrt(kfx * kfx + kfz * kfz)
  krx, kry, krz = kfz / l, 0, -kfx / l
  kux, kuy, kuz = kfy * krz - kfz * kry, kfz * krx - kfx * krz, kfx * kry - kfy * krx
end

local function applySettings()
  local r = S.rates
  P.rc, P.rm, P.re, P.twr = CFG.rc[r], CFG.rm[r], CFG.re[r], CFG.twr[S.power]
  P.angle = S.mode == 2
  local t = S.tilt * 0.0174533
  P.tc, P.ts = cos(t), sin(t)
  tanH = sin(S.fov * 0.00872665) / cos(S.fov * 0.00872665)
  F = (VW / 2) / tanH
end

-- visible objects sorted far -> near (painter's algorithm)
local ordZ, ordI, nOrd = {}, {}, 0
local function collectObjects(maxZ)
  nOrd = 0
  for n = 1, NG + NP do
    local i, X, Y, Z, rad = n, 0, 0, 0, 4
    if n <= NG then
      X, Y, Z = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    else
      i = n - NG
      if qk[i] == 1 then
        X, Y, Z = qx[i] - kpx, qh[i] * 0.4 - kpy, qz[i] - kpz
        rad = qh[i]
      else
        Z = -1e9
      end
      i = -i
    end
    local z = X * kfx + Y * kfy + Z * kfz
    if z > -4 and z < maxZ then
      local x = X * krx + Y * kry + Z * krz
      if x < 0 then x = -x end
      if z < 4 or x < z * tanH + rad then
        local j = nOrd
        while j > 0 and ordZ[j] < z do
          ordZ[j + 1], ordI[j + 1] = ordZ[j], ordI[j]
          j = j - 1
        end
        ordZ[j + 1], ordI[j + 1] = z, i
        nOrd = nOrd + 1
      end
    end
  end
end

local C = {}            -- colors (color radios) / grey levels (B&W)
local render3D, initGfx


-- =============================================================== B&W GFX
local line2
do
  local GRAYS = type(GREY) == "function"
  local GRD, GRD2 = 0, 0

  initGfx = function()
    -- grey levels: GREY(n) darkens by 15-n, FORCE makes it OR instead of XOR
    if GRAYS then GRD, GRD2 = GREY(12) + FORCE, GREY(7) + FORCE else GRD, GRD2 = FORCE, FORCE end
  end

  -- the B&W drawLine refuses off-screen points: clip in Lua (slab method)
  line2 = function(x1, y1, x2, y2, pat, fl)
    if x1 >= 0 and x1 <= XM and x2 >= 0 and x2 <= XM and y1 >= 0 and y1 <= YM and y2 >= 0 and y2 <= YM then
      drawLine(x1, y1, x2, y2, pat, fl)
      return
    end
    local dx, dy, t0, t1 = x2 - x1, y2 - y1, 0, 1
    if dx > -1e-6 and dx < 1e-6 then
      if x1 < 0 or x1 > XM then return end
    else
      local ta, tb = -x1 / dx, (XM - x1) / dx
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return end
    end
    if dy > -1e-6 and dy < 1e-6 then
      if y1 < 0 or y1 > YM then return end
    else
      local ta, tb = -y1 / dy, (YM - y1) / dy
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return end
    end
    drawLine(floor(x1 + dx * t0 + 0.5), floor(y1 + dy * t0 + 0.5), floor(x1 + dx * t1 + 0.5), floor(y1 + dy * t1 + 0.5), pat, fl)
  end

  local function line3(X1, Y1, Z1, X2, Y2, Z2, pat, fl)
    if Z1 < NEAR then
      if Z2 < NEAR then return end
      local t = (NEAR - Z1) / (Z2 - Z1)
      X1, Y1, Z1 = X1 + (X2 - X1) * t, Y1 + (Y2 - Y1) * t, NEAR
    elseif Z2 < NEAR then
      local t = (NEAR - Z2) / (Z1 - Z2)
      X2, Y2, Z2 = X2 + (X1 - X2) * t, Y2 + (Y1 - Y2) * t, NEAR
    end
    local s1, s2 = F / Z1, F / Z2
    line2(CX + X1 * s1, CY - Y1 * s1, CX + X2 * s2, CY - Y2 * s2, pat, fl)
  end

  local function drawGround()
    local a, b, c = kry, kuy, F * kfy
    local A, B = a < 0 and -a or a, b < 0 and -b or b
    if GRAYS then
      -- greyscale screens: fill the ground row by row (64 short calls)
      for y = 0, YM do
        local e = c - (y - CY) * b
        if A < 1e-5 then
          if e < 0 then drawLine(0, y, XM, y, SOLID, GRD) end
        else
          local xh = CX - e / a
          if a > 0 then
            if xh > 0 then drawLine(0, y, xh < XM and xh or XM, y, SOLID, GRD) end
          elseif xh < XM then
            drawLine(xh > 0 and xh or 0, y, XM, y, SOLID, GRD)
          end
        end
      end
    end
    if A <= B then
      if B < 1e-5 then return end
      line2(0, CY + (c - CX * a) / b, XM, CY + (c + (XM - CX) * a) / b, SOLID, GRD2)
    else
      line2(CX + (-CY * b - c) / a, 0, CX + ((YM - CY) * b - c) / a, YM, SOLID, GRD2)
    end
  end

  local function drawGrid()
    local bX = -kpx * krx - kpy * kry - kpz * krz
    local bY = -kpx * kux - kpy * kuy - kpz * kuz
    local bZ = -kpx * kfx - kpy * kfy - kpz * kfz
    local gs, gr = 10, 35
    local cxw, czw = floor(kpx / gs) * gs, floor(kpz / gs) * gs
    local pat, fl = DOTTED, BLK
    if GRAYS then pat, fl = SOLID, GRD2 end
    for i = -3, 4 do
      local x = cxw + i * gs
      local X0, Y0, Z0 = bX + x * krx, bY + x * kux, bZ + x * kfx
      local z1, z2 = czw - gr, czw + gr
      line3(X0 + z1 * krz, Y0 + z1 * kuz, Z0 + z1 * kfz, X0 + z2 * krz, Y0 + z2 * kuz, Z0 + z2 * kfz, pat, fl)
      local z = czw + i * gs
      X0, Y0, Z0 = bX + z * krz, bY + z * kuz, bZ + z * kfz
      local x1, x2 = cxw - gr, cxw + gr
      line3(X0 + x1 * krx, Y0 + x1 * kux, Z0 + x1 * kfx, X0 + x2 * krx, Y0 + x2 * kux, Z0 + x2 * kfx, pat, fl)
    end
  end

  local function drawGate(i, z)
    local nxt = i == nextGate and gmode ~= 3
    local pat = (nxt or z < 12) and SOLID or DOTTED
    local k = gk[i]
    local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    local cx, cy, cz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, z
    local r1, r3 = grx[i], grz[i]
    local Rx, Ry, Rz = r1 * krx + r3 * krz, r1 * kux + r3 * kuz, r1 * kfx + r3 * kfz
    local a1, a2, a3 = gax[i], gay[i], gaz[i]
    local Ax, Ay, Az = a1 * krx + a2 * kry + a3 * krz, a1 * kux + a2 * kuy + a3 * kuz, a1 * kfx + a2 * kfy + a3 * kfz
    local iw, ih = GHW[k], GHH[k]
    local s = 1
    while s <= 2 do
      local w, h = iw, ih
      if s == 1 then w, h = iw + GT, ih + GT end
      local wx, wy, wz, hx, hy, hz = Rx * w, Ry * w, Rz * w, Ax * h, Ay * h, Az * h
      line3(cx - wx + hx, cy - wy + hy, cz - wz + hz, cx + wx + hx, cy + wy + hy, cz + wz + hz, pat, BLK)
      line3(cx + wx + hx, cy + wy + hy, cz + wz + hz, cx + wx - hx, cy + wy - hy, cz + wz - hz, pat, BLK)
      line3(cx + wx - hx, cy + wy - hy, cz + wz - hz, cx - wx - hx, cy - wy - hy, cz - wz - hz, pat, BLK)
      line3(cx - wx - hx, cy - wy - hy, cz - wz - hz, cx - wx + hx, cy - wy + hy, cz - wz + hz, pat, BLK)
      if z > 30 and not nxt then s = 3 else s = s + 1 end
    end
    if k > 1 then
      local lh = k == 2 and gy[i] - ih - GT or gy[i]
      local ex, ey, ez = kry * lh, kuy * lh, kfy * lh
      local lw = iw + GT * 0.5
      for sx = -1, 1, 2 do
        for sz = (k == 3 and -1 or 1), 1, 2 do
          local la = k == 3 and (ih + GT * 0.5) * sz or -(ih + GT)
          local X, Y, Z = cx + Rx * lw * sx + Ax * la, cy + Ry * lw * sx + Ay * la, cz + Rz * lw * sx + Az * la
          line3(X, Y, Z, X - ex, Y - ey, Z - ez, SOLID, BLK)
        end
      end
    end
  end

  local function drawTree(i, z)
    local h = qh[i]
    local dx, dy, dz = qx[i] - kpx, -kpy, qz[i] - kpz
    local bX, bY, bZ = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local tX, tY, tZ = bX + kry * h, bY + kuy * h, bZ + kfy * h
    line3(bX, bY, bZ, tX, tY, tZ, SOLID, BLK)
    if z < 40 then
      local w = h * 0.24
      local q = h * 0.25
      local mX, mY, mZ = bX + kry * q, bY + kuy * q, bZ + kfy * q
      local lX, lY, lZ, rX, rY, rZ = mX - krx * w, mY - kux * w, mZ - kfx * w, mX + krx * w, mY + kux * w, mZ + kfx * w
      line3(tX, tY, tZ, lX, lY, lZ, SOLID, BLK)
      line3(tX, tY, tZ, rX, rY, rZ, SOLID, BLK)
      line3(lX, lY, lZ, rX, rY, rZ, SOLID, BLK)
    end
  end

  render3D = function()
    lcd.clear()
    drawGround()
    drawGrid()
    collectObjects(90)
    for j = 1, nOrd do
      local id = ordI[j]
      if id > 0 then drawGate(id, ordZ[j]) else drawTree(-id, ordZ[j]) end
    end
  end
end

-- ---------------------------------------------------------- game flow
local function startRace(m)
  gmode = m
  lap, nextGate, lastGate, lapStart = 0, 1, 0, nil
  R.n, R.total, R.newLap, R.newRace, R.crashes, R.msg, R.cn = 0, 0, false, false, 0, nil, -1
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  state, tState = COUNT, gt
end

local function selectTrack(t)
  S.track = t
  buildTrack(t)
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
end

local function update(dt)
  if state == COUNT then
    local n = floor((gt - tState) / 100)
    if n ~= R.cn then
      R.cn = n
      if n < 3 then beep(1000, 120) end
    end
    if n >= 3 then
      state, tStart = FLY, gt
      beep(2000, 400)
      showMsg("GO!", true)
    end
  elseif state == FLY or state == DONE then
    physics(dt)
  elseif state == CRASHED then
    if gt - tState > 120 then
      respawn()
      state, R.ready = READY, gt
    end
  elseif state == READY then
    local e = gt - R.ready
    if e > 25 and (e > 200 or sA > 0.12 or sA < -0.12 or sE > 0.12 or sE < -0.12 or sR > 0.12 or sR < -0.12 or sT > 0.3) then
      state = FLY
    end
  end
end

-- menus
local focus, scroll, editing = 1, 0, false
local MAIN_ITEMS = { "Race", "Practice", "Free fly", "Track", "Settings", "Exit" }
local PAUSE_ITEMS = { "Resume", "Restart", "Settings", "Main menu" }

local function optIndex(o)
  local v = S[o[2]]
  for j = 1, #o[3] do
    if o[3][j] == v then return j end
  end
  return 1
end

local function optStep(o, d)
  local vals = o[3]
  local j = optIndex(o) + d
  if j < 1 then j = #vals elseif j > #vals then j = 1 end
  S[o[2]] = vals[j]
  applySettings()
end

local function optText(o)
  if o[4] then return o[4][optIndex(o)] end
  return S[o[2]] .. (o[5] or "")
end

local function setLabel(i)
  if i > #OPTS then return "Back" end
  return OPTS[i][1]
end

local function setValue(i)
  if i > #OPTS then return nil end
  return optText(OPTS[i])
end

local render, hitTest, pauseHit, initUI


-- ================================================================ B&W UI
do
  initUI = function() end

  local function drawHUD()
    if gmode ~= 3 then
      drawNumber(1, 1, floor(lapStart and (gt - lapStart) / 10 or 0), PREC1 + SMLSIZE + LEFT)
      local s = (lap > 0 and lap or 1) .. ""
      if gmode == 1 then s = s .. "/" .. S.laps end
      drawText(XM, 1, s, SMLSIZE + RIGHT)
      local i = nextGate
      local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
      local X, Y, Z = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
      local onScreen = false
      if Z > 1 then
        local sx, sy = CX + X * F / Z, CY - Y * F / Z
        if sx > 3 and sx < XM - 3 and sy > 3 and sy < YM - 3 then onScreen = true end
      end
      if not onScreen then
        local ex, ey = X, -Y
        if Z < 0 and ex * ex + ey * ey < 1 then ex, ey = 0, 1 end
        local l = sqrt(ex * ex + ey * ey) + 0.0001
        ex, ey = ex / l, ey / l
        local k = (CX - 6) / ((ex < 0 and -ex or ex) + 0.0001)
        local k2 = (CY - 6) / ((ey < 0 and -ey or ey) + 0.0001)
        if k2 < k then k = k2 end
        local tx, ty = CX + ex * k, CY + ey * k
        line2(tx, ty, tx - ex * 5 - ey * 3, ty - ey * 5 + ex * 3, SOLID, BLK)
        line2(tx, ty, tx - ex * 5 + ey * 3, ty - ey * 5 - ex * 3, SOLID, BLK)
      end
    end
    local th = floor(sT * 30)
    if th > 0 then fillRect(0, YM - th, 2, th, BLK) end
    drawLine(CX - 4, CY, CX - 2, CY, SOLID, BLK)
    drawLine(CX + 2, CY, CX + 4, CY, SOLID, BLK)
    if S.fps == 1 then drawNumber(XM, YM - 6, R.fps, SMLSIZE + RIGHT) end
  end

  local function drawList(title, n, label, value)
    local y = 0
    if title then
      drawText(1, 0, title, SMLSIZE + INVERS)
      y = 9
    end
    local rows = floor((H - y) / 9)
    if rows > n then rows = n end
    if focus - scroll > rows then scroll = focus - rows end
    if focus <= scroll then scroll = focus - 1 end
    for r = 1, rows do
      local i = scroll + r
      local ry = y + (r - 1) * 9
      drawText(2, ry + 1, label(i), SMLSIZE + ((i == focus and not editing) and INVERS or 0))
      local v = value and value(i)
      if v then drawText(XM - 1, ry + 1, v, SMLSIZE + RIGHT + ((i == focus and editing) and INVERS or 0)) end
    end
  end

  render = function()
    if state == MENU or (state == SETUP and prevState == MENU) then
      lcd.clear()
      if state == MENU then
        local t = S.track
        drawText(1, 0, "FPV SIM", MIDSIZE)
        drawText(XM, 1, TRACKS[t][1], SMLSIZE + RIGHT)
        if bestLap[t] > 0 then drawText(XM, 8, timeStr(bestLap[t]), SMLSIZE + RIGHT) end
        for i = 1, #MAIN_ITEMS do
          local s = MAIN_ITEMS[i]
          if i == 1 then s = "Race " .. S.laps .. " laps" end
          if i == 4 then s = "Track: " .. TRACKS[t][1] end
          if i == focus and editing then s = "< " .. TRACKS[t][1] .. " >" end
          drawText(4, 15 + (i - 1) * 8, s, SMLSIZE + (i == focus and INVERS or 0))
        end
      else
        drawList("SETTINGS", #OPTS + 1, setLabel, setValue)
      end
      return
    end
    fpvCamera()
    render3D()
    if state == SETUP then
      fillRect(0, 0, W, H, ERASE)
      drawList("SETTINGS", #OPTS + 1, setLabel, setValue)
      return
    end
    drawHUD()
    if state == COUNT then
      drawText(CX - 4, CY - 16, tostring(3 - floor((gt - tState) / 100)), DBLSIZE)
    elseif state == CRASHED then
      drawText(CX - 24, CY - 8, "CRASH", DBLSIZE + INVERS)
    elseif state == READY then
      drawText(CX - 14, CY - 14, "READY", SMLSIZE + INVERS)
    elseif state == PAUSED then
      fillRect(14, 6, W - 28, H - 12, ERASE)
      lcd.drawRectangle(14, 6, W - 28, H - 12, BLK)
      for i = 1, #PAUSE_ITEMS do
        drawText(22, 10 + (i - 1) * 11, PAUSE_ITEMS[i], i == focus and INVERS or 0)
      end
    elseif state == DONE then
      fillRect(8, 4, W - 16, H - 8, ERASE)
      lcd.drawRectangle(8, 4, W - 16, H - 8, BLK)
      drawText(12, 7, R.newRace and "NEW RECORD!" or "FINISHED", SMLSIZE + INVERS)
      drawText(12, 17, "Total " .. timeStr(R.total), SMLSIZE)
      local b = 0
      for i = 1, R.n do
        if b == 0 or R.laps[i] < b then b = R.laps[i] end
      end
      drawText(12, 26, "Best lap " .. timeStr(b), SMLSIZE)
      drawText(12, H - 16, "ENTER again  EXIT menu", SMLSIZE)
    end
    if R.msg and state == FLY then
      if gt - R.msgT < 200 then
        drawText(CX, 10, R.msg, SMLSIZE + CENTER)
      else
        R.msg = nil
      end
    end
  end

  hitTest = function() return nil end
  pauseHit = function() return false end
end

-- ------------------------------------------------------------ input
local handleEvent
do
  local function listNav(event, n)
    if event == EV.NEXT then
      focus = focus % n + 1
    elseif event == EV.PREV then
      focus = (focus - 2) % n + 1
    end
  end

  local function toMenu()
    state, focus, scroll, editing = MENU, 1, 0, false
    placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  end

  local function stepTrack(d)
    local t = S.track + d
    if t < 1 then t = NT elseif t > NT then t = 1 end
    selectTrack(t)
    saveData()
  end

  local function mainSelect(i, frac)
    if i <= 3 then startRace(i)
    elseif i == 4 then stepTrack((frac and frac < 0.4) and -1 or 1)
    elseif i == 5 then prevState, state, focus, scroll, editing = MENU, SETUP, 1, 0, false
    elseif i == 6 then return 1
    end
    return 0
  end

  local function pauseSelect(i)
    if i == 1 then state = pausedFrom
    elseif i == 2 then startRace(gmode)
    elseif i == 3 then prevState, state, focus, scroll, editing = PAUSED, SETUP, 1, 0, false
    elseif i == 4 then toMenu()
    end
  end

  handleEvent = function(event, touch)
    local tapI, tapF
    if EV.TAP and event == EV.TAP and touch then tapI, tapF = hitTest(touch.x, touch.y) end
    if state == MENU then
      if tapI then
        focus = tapI
        return mainSelect(tapI, tapF)
      end
      if editing then
        if event == EV.INC or event == EV.NEXT then stepTrack(1)
        elseif event == EV.DEC or event == EV.PREV then stepTrack(-1)
        elseif event == EV.ENTER or event == EV.EXIT then editing = false end
        return 0
      end
      listNav(event, #MAIN_ITEMS)
      if event == EV.ENTER then
        if focus == 4 then
          editing = true
          return 0
        end
        return mainSelect(focus, nil)
      elseif event == EV.EXIT then
        return 1
      end
    elseif state == SETUP then
      local n = #OPTS + 1
      if tapI then
        focus = tapI
        if tapI == n then event = EV.EXIT else optStep(OPTS[tapI], tapF < 0.4 and -1 or 1) end
      elseif editing then
        if event == EV.INC or event == EV.NEXT then optStep(OPTS[focus], 1)
        elseif event == EV.DEC or event == EV.PREV then optStep(OPTS[focus], -1)
        elseif event == EV.ENTER or event == EV.EXIT then editing = false end
        return 0
      else
        listNav(event, n)
        if event == EV.ENTER then
          if focus == n then event = EV.EXIT else editing = true end
        end
      end
      if event == EV.EXIT then
        saveData()
        editing = false
        if prevState == PAUSED then
          state, focus, scroll = PAUSED, 3, 0
        else
          state, focus, scroll = MENU, 5, 0
        end
      end
    elseif state == PAUSED then
      if tapI then
        pauseSelect(tapI)
        return 0
      end
      listNav(event, #PAUSE_ITEMS)
      if event == EV.ENTER then pauseSelect(focus)
      elseif event == EV.EXIT then state = pausedFrom end
    elseif state == DONE then
      if tapI == 1 or event == EV.ENTER then startRace(gmode)
      elseif tapI == 2 or event == EV.EXIT then toMenu() end
    else
      -- flying: EXIT or the on-screen pause button pauses
      if event == EV.EXIT or (EV.TAP and event == EV.TAP and touch and pauseHit(touch.x, touch.y)) then
        pausedFrom, prevState, state, focus, scroll = state, state, PAUSED, 1, 0
      end
    end
    return 0
  end
end

-- ------------------------------------------------------------ entry
local function init()
  readSticks(true)
  loadData()
  initGfx()
  initUI()
  applySettings()
  selectTrack(S.track)
  lastT = getTime()
  R.fpsT = lastT
  if TEST then
    TEST.get = function() return px, py, pz, vx, vy, vz, fx, fy, fz, ux, uy, uz, rx, ry, rz, state, lap, nextGate, NG, gt end
    TEST.gate = function(i) return gx[i], gy[i], gz[i], gnx[i], gny[i], gnz[i], gk[i] end
    TEST.start = function(m) startRace(m) end
    TEST.state = function(s) state = s end
    TEST.set = function(k, v)
      S[k] = v
      applySettings()
    end
    TEST.track = function(t) selectTrack(t) end
    TEST.pose = function(x, y, z, yaw, pitch, roll)
      yaw = yaw * 0.0174533
      placeDrone(x, y, z, sin(yaw), cos(yaw))
      rotate(0, pitch * 0.0174533, 0)
      rotate(roll * 0.0174533, 0, 0)
    end
    TEST.vel = function(a, b, c) vx, vy, vz = a, b, c end
    TEST.lapclock = function(t)
      lapStart, tStart = gt - t, gt - t - 640
      if lap < 1 then lap = 1 end
    end
    TEST.next = function(i) nextGate, lastGate = i, (i - 2) % NG + 1 end
    TEST.race = function() return lastGate, lapStart, R.n, R.laps, R.total, R.crashes, tStart end
  end
end

local function run(event, touch)
  local now = getTime()
  local dtk = now - lastT
  lastT = now
  if dtk > 10 then dtk = 10 elseif dtk < 0 then dtk = 0 end
  if state ~= PAUSED and state ~= SETUP then gt = gt + dtk end
  readSticks()
  if handleEvent(event or 0, touch) ~= 0 then return 1 end
  update(dtk / 100)
  render()
  R.fpsN = R.fpsN + 1
  if now - R.fpsT >= 100 then
    R.fps, R.fpsN, R.fpsT = R.fpsN, 0, now
  end
  return 0
end

return { init = init, run = run }
