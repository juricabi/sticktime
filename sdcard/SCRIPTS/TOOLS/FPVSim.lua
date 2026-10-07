local toolName = "TNS|FPV Sim|TNE"
--[[ ======================================================================
  FPV Sim v1.0  -  a real 3D FPV quad simulator that runs on your radio
  Color version - every EdgeTX color radio (480x272, 480x320, 320x480, 320x240, 800x480)

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
local fillTri = lcd.drawFilledTriangle

local EV = {
  ENTER = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EXIT = EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK,
  NEXT = EVT_VIRTUAL_NEXT, PREV = EVT_VIRTUAL_PREV, INC = EVT_VIRTUAL_INC, DEC = EVT_VIRTUAL_DEC,
  TAP = EVT_TOUCH_TAP,
}

-- game states
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8

-- ------------------------------------------------------------ settings
local S = { track = 1, mode = 1, rates = 2, tilt = 25, fov = 110, power = 2, laps = 3, map = 1, sticks = 0, fps = 0 }
local KEYS = { "track", "mode", "rates", "tilt", "fov", "power", "laps", "map", "sticks", "fps" }
local OPTS = {
  { "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
  { "Rates", "rates", { 1, 2, 3 }, { "Soft", "Normal", "Fast" } },
  { "Camera tilt", "tilt", { 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50 }, nil, "°" },
  { "Field of view", "fov", { 80, 90, 100, 110, 120 }, nil, "°" },
  { "Power", "power", { 1, 2, 3 }, { "Low 3:1", "Mid 4:1", "High 6:1" } },
  { "Race laps", "laps", { 1, 2, 3, 5, 10 } },
  { "Minimap", "map", { 0, 1 }, { "Off", "On" } },
  { "Stick view", "sticks", { 0, 1 }, { "Off", "On" } },
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
    while n < 18 and tries < 300 do
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
local DATA = "/SCRIPTS/TOOLS/FPVSim.dat"

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
local SC = VW / 480
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

-- ============================================================ COLOR GFX
do
  local RGB = lcd.RGB
  local NF = 6
  local MT, NMT = {}, 0
  local HAZE = { 214, 230, 242 }
  local HZN = floor(10 * SC + 0.5)        -- haze band height (px)
  local cSky, cGround, cGridN, cGridF, cMtn, cSnow, cPad, cPad2
  local hazeS, hazeG = {}, {}
  local fGate, fGateE, fNext, fNextE, fNextG, fTree, fTreeH, fTrunk, fPole = {}, {}, {}, {}, {}, {}, {}, {}, {}

  local function mixc(a, b, t)
    return RGB(floor(a[1] + (b[1] - a[1]) * t + 0.5), floor(a[2] + (b[2] - a[2]) * t + 0.5), floor(a[3] + (b[3] - a[3]) * t + 0.5))
  end

  local function ramp(dst, c, amount)
    for i = 1, NF do dst[i] = mixc(c, HAZE, (i - 1) / (NF - 1) * amount) end
  end

  initGfx = function()
    local sky, grass = { 92, 156, 226 }, { 84, 140, 62 }
    cSky, cGround = RGB(sky[1], sky[2], sky[3]), RGB(grass[1], grass[2], grass[3])
    cGridN, cGridF = RGB(66, 118, 50), RGB(76, 130, 58)
    cMtn, cSnow = RGB(128, 150, 182), RGB(232, 238, 246)
    cPad, cPad2 = RGB(255, 140, 20), RGB(250, 250, 250)
    C.white, C.black, C.accent, C.accent2 = RGB(255, 255, 255), RGB(0, 0, 0), RGB(255, 138, 0), RGB(255, 214, 64)
    C.good, C.bad, C.red, C.cyan = RGB(96, 232, 120), RGB(255, 96, 96), RGB(230, 30, 40), RGB(80, 220, 255)
    C.panel, C.panelBG, C.dim = RGB(14, 18, 28), RGB(22, 26, 36), RGB(170, 178, 192)
    for k = 0, 7 do hazeS[k + 1] = mixc(HAZE, sky, k / 8) end
    for k = 0, 3 do hazeG[k + 1] = mixc({ 150, 182, 140 }, grass, k / 4) end
    ramp(fGate, { 236, 238, 244 }, 0.8)
    ramp(fGateE, { 40, 44, 56 }, 0.85)
    ramp(fNext, { 255, 120, 0 }, 0.6)
    ramp(fNextE, { 90, 30, 0 }, 0.7)
    ramp(fNextG, { 255, 236, 90 }, 0.5)
    ramp(fTree, { 34, 92, 46 }, 0.85)
    ramp(fTreeH, { 62, 128, 60 }, 0.85)
    ramp(fTrunk, { 96, 64, 40 }, 0.85)
    ramp(fPole, { 70, 72, 82 }, 0.85)
    -- distant mountain range: triangles at infinity (only rotate with the camera)
    local s, az = 5, 0
    NMT = 0
    while az < 6.2 do
      s = s * 171 % 30269
      local el = (2.2 + (s % 40) / 10) * 0.0174533
      local hw = (9 + (s % 8)) * 0.0174533
      MT[NMT + 1], MT[NMT + 2], MT[NMT + 3] = sin(az) * cos(el), sin(el), cos(az) * cos(el)
      MT[NMT + 4], MT[NMT + 5], MT[NMT + 6] = sin(az - hw), 0, cos(az - hw)
      MT[NMT + 7], MT[NMT + 8], MT[NMT + 9] = sin(az + hw), 0, cos(az + hw)
      NMT = NMT + 9
      az = az + hw * (1.4 + (s % 9) / 10)
    end
  end

  -- 3D line in camera space: near-plane clip + project (C code clips to screen)
  local function line3(X1, Y1, Z1, X2, Y2, Z2, col)
    if Z1 < NEAR then
      if Z2 < NEAR then return end
      local t = (NEAR - Z1) / (Z2 - Z1)
      X1, Y1, Z1 = X1 + (X2 - X1) * t, Y1 + (Y2 - Y1) * t, NEAR
    elseif Z2 < NEAR then
      local t = (NEAR - Z2) / (Z1 - Z2)
      X2, Y2, Z2 = X2 + (X1 - X2) * t, Y2 + (Y1 - Y2) * t, NEAR
    end
    local s1, s2 = F / Z1, F / Z2
    drawLine(CX + X1 * s1, CY - Y1 * s1, CX + X2 * s2, CY - Y2 * s2, SOLID, col)
  end

  local function drawMountains()
    for i = 1, NMT, 9 do
      local ax, ay, az = MT[i], MT[i + 1], MT[i + 2]
      local Za = ax * kfx + ay * kfy + az * kfz
      if Za > 0.3 then
        local lx, lz, mx, mz = MT[i + 3], MT[i + 5], MT[i + 6], MT[i + 8]
        local Zl, Zr = lx * kfx + lz * kfz, mx * kfx + mz * kfz
        if Zl > 0.3 and Zr > 0.3 then
          local s = F / Za
          local Xa, Ya = CX + (ax * krx + ay * kry + az * krz) * s, CY - (ax * kux + ay * kuy + az * kuz) * s
          s = F / Zl
          local Xl, Yl = CX + (lx * krx + lz * krz) * s, CY - (lx * kux + lz * kuz) * s
          s = F / Zr
          local Xr, Yr = CX + (mx * krx + mz * krz) * s, CY - (mx * kux + mz * kuz) * s
          fillTri(Xa, Ya, Xl, Yl, Xr, Yr, cMtn)
          fillTri(Xa, Ya, Xa + (Xl - Xa) * 0.3, Ya + (Yl - Ya) * 0.3, Xa + (Xr - Xa) * 0.3, Ya + (Yr - Ya) * 0.3, cSnow)
        end
      end
    end
  end

  -- sky/ground split for any attitude: one rectangle + one thin wedge
  -- triangle (filled triangles cost one call per scanline on the radio)
  local function drawGround()
    local a, b, c = kry, kuy, F * kfy      -- ground where c + (x-CX)*a - (y-CY)*b < 0
    local x0, y0, x1, y1 = VX, VY, VX + VW, VY + VH
    local A, B = a < 0 and -a or a, b < 0 and -b or b
    local g = cGround
    local hx0, hy0, hx1, hy1
    if A <= B then
      if B < 1e-5 then
        if c < 0 then fillRect(x0, y0, VW, VH, g) end
        return
      end
      local yL, yR = CY + (c + (x0 - CX) * a) / b, CY + (c + (x1 - CX) * a) / b
      local lo, hi = yL, yR
      if lo > hi then lo, hi = hi, lo end
      if b > 0 then
        if lo < y1 then
          if hi <= y0 then fillRect(x0, y0, VW, VH, g)
          else
            if hi < y1 then
              local t = hi > y0 and hi or y0
              fillRect(x0, t, VW, y1 - t + 1, g)
            end
            if yL < yR then fillTri(x0, yL, x1, yR, x0, yR, g) else fillTri(x0, yL, x1, yR, x1, yL, g) end
          end
        end
      elseif hi > y0 then
        if lo >= y1 then fillRect(x0, y0, VW, VH, g)
        else
          if lo > y0 then fillRect(x0, y0, VW, (lo < y1 and lo or y1) - y0 + 1, g) end
          if yL > yR then fillTri(x0, yL, x1, yR, x0, yR, g) else fillTri(x0, yL, x1, yR, x1, yL, g) end
        end
      end
      hx0, hy0, hx1, hy1 = x0, yL, x1, yR
    else
      local xT, xB = CX + ((y0 - CY) * b - c) / a, CX + ((y1 - CY) * b - c) / a
      local lo, hi = xT, xB
      if lo > hi then lo, hi = hi, lo end
      if a > 0 then
        if hi > x0 then
          if lo >= x1 then fillRect(x0, y0, VW, VH, g)
          else
            if lo > x0 then fillRect(x0, y0, (lo < x1 and lo or x1) - x0 + 1, VH, g) end
            if xT < xB then fillTri(xT, y0, xB, y1, xT, y1, g) else fillTri(xT, y0, xB, y1, xB, y0, g) end
          end
        end
      elseif lo < x1 then
        if hi <= x0 then fillRect(x0, y0, VW, VH, g)
        else
          if hi < x1 then
            local t = hi > x0 and hi or x0
            fillRect(t, y0, x1 - t + 1, VH, g)
          end
          if xT > xB then fillTri(xT, y0, xB, y1, xT, y1, g) else fillTri(xT, y0, xB, y1, xB, y0, g) end
        end
      end
      hx0, hy0, hx1, hy1 = xT, y0, xB, y1
    end
    -- atmospheric haze: soft bands hugging the horizon
    local l = sqrt(a * a + b * b)
    local nx, ny = a / l, -b / l
    -- unit steps along the horizon normal (Chebyshev) so the bands have no gaps
    local m = (nx < 0 and -nx or nx) > (ny < 0 and -ny or ny) and (nx < 0 and -nx or nx) or (ny < 0 and -ny or ny)
    nx, ny = nx / m, ny / m
    local n = HZN
    for k = 0, n - 1 do
      drawLine(hx0 + nx * k, hy0 + ny * k, hx1 + nx * k, hy1 + ny * k, SOLID, hazeS[floor(k * 8 / n) + 1])
    end
    for k = 1, floor(n / 2) do
      drawLine(hx0 - nx * k, hy0 - ny * k, hx1 - nx * k, hy1 - ny * k, SOLID, hazeG[floor((k - 1) * 8 / n) + 1])
    end
  end

  -- ground grid: world lines on y=0, transformed incrementally
  local function drawGrid()
    local bX = -kpx * krx - kpy * kry - kpz * krz
    local bY = -kpx * kux - kpy * kuy - kpz * kuz
    local bZ = -kpx * kfx - kpy * kfy - kpz * kfz
    local gs, gr = 10, 60
    local cxw, czw = floor(kpx / gs) * gs, floor(kpz / gs) * gs
    local za, zb, xa, xb = czw - gr, czw + gr, cxw - gr, cxw + gr
    for i = -6, 6 do
      local near = i >= -3 and i <= 4
      local col = near and cGridN or cGridF
      local x = cxw + i * gs
      local X0, Y0, Z0 = bX + x * krx, bY + x * kux, bZ + x * kfx
      local z1, z2 = za, zb
      if near then z1, z2 = czw - 30, czw + 40 end
      line3(X0 + z1 * krz, Y0 + z1 * kuz, Z0 + z1 * kfz, X0 + z2 * krz, Y0 + z2 * kuz, Z0 + z2 * kfz, col)
      if near then
        line3(X0 + z2 * krz, Y0 + z2 * kuz, Z0 + z2 * kfz, X0 + zb * krz, Y0 + zb * kuz, Z0 + zb * kfz, cGridF)
        line3(X0 + za * krz, Y0 + za * kuz, Z0 + za * kfz, X0 + z1 * krz, Y0 + z1 * kuz, Z0 + z1 * kfz, cGridF)
      end
      local z = czw + i * gs
      X0, Y0, Z0 = bX + z * krz, bY + z * kuz, bZ + z * kfz
      local x1, x2 = xa, xb
      if near then x1, x2 = cxw - 30, cxw + 40 end
      line3(X0 + x1 * krx, Y0 + x1 * kux, Z0 + x1 * kfx, X0 + x2 * krx, Y0 + x2 * kux, Z0 + x2 * kfx, col)
      if near then
        line3(X0 + x2 * krx, Y0 + x2 * kux, Z0 + x2 * kfx, X0 + xb * krx, Y0 + xb * kux, Z0 + xb * kfx, cGridF)
        line3(X0 + xa * krx, Y0 + xa * kux, Z0 + xa * kfx, X0 + x1 * krx, Y0 + x1 * kux, Z0 + x1 * kfx, cGridF)
      end
    end
  end

  local function drawPad()
    local hx, hz = TR.hx, TR.hz
    local ox, oz, y = TR.px - kpx, TR.pz - kpz, -kpy
    for s = 1, 2 do
      local e = s == 1 and 1.5 or 0.9
      local col = s == 1 and cPad or cPad2
      local ax, az = ox + (hx - hz) * e, oz + (hz + hx) * e
      local bx, bz = ox + (hx + hz) * e, oz + (hz - hx) * e
      local cx, cz = ox + (hz - hx) * e, oz - (hz + hx) * e
      local dx, dz = ox - (hx + hz) * e, oz + (hx - hz) * e
      local AX, AY, AZ = ax * krx + y * kry + az * krz, ax * kux + y * kuy + az * kuz, ax * kfx + y * kfy + az * kfz
      local BX, BY, BZ = bx * krx + y * kry + bz * krz, bx * kux + y * kuy + bz * kuz, bx * kfx + y * kfy + bz * kfz
      local CX_, CY_, CZ_ = cx * krx + y * kry + cz * krz, cx * kux + y * kuy + cz * kuz, cx * kfx + y * kfy + cz * kfz
      local DX, DY, DZ = dx * krx + y * kry + dz * krz, dx * kux + y * kuy + dz * kuz, dx * kfx + y * kfy + dz * kfz
      line3(AX, AY, AZ, BX, BY, BZ, col)
      line3(BX, BY, BZ, CX_, CY_, CZ_, col)
      line3(CX_, CY_, CZ_, DX, DY, DZ, col)
      line3(DX, DY, DZ, AX, AY, AZ, col)
    end
  end

  -- one gate bar = quad between its outer and inner edge, filled with
  -- 1 px "ruled" lines (fast native Bresenham), or 2 triangles when huge
  local function bar(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, fill, e1, e2)
    if az < NEAR then
      if bz < NEAR then return end
      local t = (NEAR - az) / (bz - az)
      ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, NEAR
    elseif bz < NEAR then
      local t = (NEAR - bz) / (az - bz)
      bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, NEAR
    end
    if cz < NEAR then
      if dz < NEAR then return end
      local t = (NEAR - cz) / (dz - cz)
      cx, cy, cz = cx + (dx - cx) * t, cy + (dy - cy) * t, NEAR
    elseif dz < NEAR then
      local t = (NEAR - dz) / (cz - dz)
      dx, dy, dz = dx + (cx - dx) * t, dy + (cy - dy) * t, NEAR
    end
    local s = F / az
    ax, ay = CX + ax * s, CY - ay * s
    s = F / bz
    bx, by = CX + bx * s, CY - by * s
    s = F / cz
    cx, cy = CX + cx * s, CY - cy * s
    s = F / dz
    dx, dy = CX + dx * s, CY - dy * s
    local p, q = cx - ax, cy - ay
    local n = (p < 0 and -p or p) + (q < 0 and -q or q)
    p, q = dx - bx, dy - by
    local m = (p < 0 and -p or p) + (q < 0 and -q or q)
    if m > n then n = m end
    if n > 140 then
      -- bar fills the view: triangles, unless the coordinates are absurd (camera in the bar)
      if ay > -4 * H and ay < 5 * H and by > -4 * H and by < 5 * H and cy > -4 * H and cy < 5 * H and dy > -4 * H and dy < 5 * H then
        fillTri(ax, ay, bx, by, dx, dy, fill)
        fillTri(ax, ay, dx, dy, cx, cy, fill)
      end
    elseif n >= 2 then
      n = floor(n)
      local sx1, sy1, sx2, sy2 = (cx - ax) / n, (cy - ay) / n, (dx - bx) / n, (dy - by) / n
      local x1, y1, x2, y2 = ax, ay, bx, by
      for _ = 2, n do
        x1, y1, x2, y2 = x1 + sx1, y1 + sy1, x2 + sx2, y2 + sy2
        drawLine(x1, y1, x2, y2, SOLID, fill)
      end
    end
    drawLine(ax, ay, bx, by, SOLID, e1)
    drawLine(cx, cy, dx, dy, SOLID, e2)
  end

  local function drawGate(i, z)
    local fi = floor((z - 18) * 0.045) + 1
    if fi < 1 then fi = 1 elseif fi > NF then fi = NF end
    local fill, e1, e2 = fGate[fi], fGateE[fi], fGateE[fi]
    if i == nextGate and gmode ~= 3 then fill, e1, e2 = fNext[fi], fNextE[fi], fNextG[fi] end
    local k = gk[i]
    local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    local cx, cy, cz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, z
    local r1, r3 = grx[i], grz[i]
    local Rx, Ry, Rz = r1 * krx + r3 * krz, r1 * kux + r3 * kuz, r1 * kfx + r3 * kfz
    local a1, a2, a3 = gax[i], gay[i], gaz[i]
    local Ax, Ay, Az = a1 * krx + a2 * kry + a3 * krz, a1 * kux + a2 * kuy + a3 * kuz, a1 * kfx + a2 * kfy + a3 * kfz
    local iw, ih = GHW[k], GHH[k]
    local ow, oh = iw + GT, ih + GT
    if k > 1 then
      -- legs down to the ground
      local pc = fPole[fi]
      local lw = iw + GT * 0.5
      local h = k == 2 and gy[i] - oh or gy[i]
      local ex, ey, ez = kry * h, kuy * h, kfy * h
      for sx = -1, 1, 2 do
        for sz = (k == 3 and -1 or 1), 1, 2 do
          local la = k == 3 and (ih + GT * 0.5) * sz or -oh
          local X, Y, Z = cx + Rx * lw * sx + Ax * la, cy + Ry * lw * sx + Ay * la, cz + Rz * lw * sx + Az * la
          line3(X, Y, Z, X - ex, Y - ey, Z - ez, pc)
          if z < 25 then
            X, Y, Z = X + Rx * 0.06, Y + Ry * 0.06, Z + Rz * 0.06
            line3(X, Y, Z, X - ex, Y - ey, Z - ez, pc)
          end
        end
      end
    end
    if z > 70 then
      -- far away: a single outline is enough
      local mw, mh = (iw + ow) * 0.5, (ih + oh) * 0.5
      local wx, wy, wz, hx, hy, hz = Rx * mw, Ry * mw, Rz * mw, Ax * mh, Ay * mh, Az * mh
      line3(cx - wx + hx, cy - wy + hy, cz - wz + hz, cx + wx + hx, cy + wy + hy, cz + wz + hz, fill)
      line3(cx + wx + hx, cy + wy + hy, cz + wz + hz, cx + wx - hx, cy + wy - hy, cz + wz - hz, fill)
      line3(cx + wx - hx, cy + wy - hy, cz + wz - hz, cx - wx - hx, cy - wy - hy, cz - wz - hz, fill)
      line3(cx - wx - hx, cy - wy - hy, cz - wz - hz, cx - wx + hx, cy - wy + hy, cz - wz + hz, fill)
      return
    end
    local oRx, oRy, oRz, oAx, oAy, oAz = Rx * ow, Ry * ow, Rz * ow, Ax * oh, Ay * oh, Az * oh
    local iRx, iRy, iRz, iAx, iAy, iAz = Rx * iw, Ry * iw, Rz * iw, Ax * ih, Ay * ih, Az * ih
    local aX, aY, aZ = cx - oRx + oAx, cy - oRy + oAy, cz - oRz + oAz   -- outer top-left
    local bX, bY, bZ = cx + oRx + oAx, cy + oRy + oAy, cz + oRz + oAz   -- outer top-right
    local cX, cY, cZ = cx + oRx - oAx, cy + oRy - oAy, cz + oRz - oAz   -- outer bottom-right
    local dX, dY, dZ = cx - oRx - oAx, cy - oRy - oAy, cz - oRz - oAz   -- outer bottom-left
    local eX, eY, eZ = cx - iRx + iAx, cy - iRy + iAy, cz - iRz + iAz   -- inner top-left
    local fX, fY, fZ = cx + iRx + iAx, cy + iRy + iAy, cz + iRz + iAz   -- inner top-right
    local gX, gY, gZ = cx + iRx - iAx, cy + iRy - iAy, cz + iRz - iAz   -- inner bottom-right
    local hX, hY, hZ = cx - iRx - iAx, cy - iRy - iAy, cz - iRz - iAz   -- inner bottom-left
    bar(dX, dY, dZ, cX, cY, cZ, hX, hY, hZ, gX, gY, gZ, fill, e1, e2)
    bar(aX, aY, aZ, dX, dY, dZ, eX, eY, eZ, hX, hY, hZ, fill, e1, e2)
    bar(bX, bY, bZ, cX, cY, cZ, fX, fY, fZ, gX, gY, gZ, fill, e1, e2)
    bar(aX, aY, aZ, bX, bY, bZ, eX, eY, eZ, fX, fY, fZ, fill, e1, e2)
  end

  local function drawTree(i, z)
    local h = qh[i]
    local dx, dy, dz = qx[i] - kpx, -kpy, qz[i] - kpz
    local bX, bY, bZ = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local tX, tY, tZ = bX + kry * h, bY + kuy * h, bZ + kfy * h
    if bZ < 1 or tZ < 1 then return end
    local fi = floor((z - 18) * 0.045) + 1
    if fi < 1 then fi = 1 elseif fi > NF then fi = NF end
    local s = F / bZ
    local x0, y0 = CX + bX * s, CY - bY * s
    s = F / tZ
    local x1, y1 = CX + tX * s, CY - tY * s
    local ex, ey = x1 - x0, y1 - y0
    local l = sqrt(ex * ex + ey * ey)
    if l < 2 then return end
    local w = F * h * 0.24 / z
    local ux_, uy_ = -ey / l, ex / l
    local nx, ny = ux_ * w, uy_ * w
    local cx, cy = x0 + ex * 0.22, y0 + ey * 0.22
    -- trunk: a few 1 px lines (lines are cheap, filled triangles cost a call per row)
    local tw = floor(w * 0.16)
    if tw > 3 then tw = 3 end
    local tc = fTrunk[fi]
    for k = -tw, tw, 2 do
      local o = k * 0.5
      drawLine(x0 + ux_ * o, y0 + uy_ * o, cx + ux_ * o, cy + uy_ * o, SOLID, tc)
    end
    fillTri(x1, y1, cx + nx, cy + ny, cx - nx, cy - ny, fTree[fi])
    -- lit half only on near trees, where it reads as a cone
    if l > 28 and z < 55 then fillTri(x1, y1, cx, cy, cx - nx, cy - ny, fTreeH[fi]) end
  end

  render3D = function()
    fillRect(VX, VY, VW, VH, cSky)
    drawMountains()
    drawGround()
    drawGrid()
    drawPad()
    collectObjects(165)
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

-- ============================================================= COLOR UI
do
  local hS, hM, hL, hX, MG = 14, 20, 28, 40, 6
  local TOUCH = EV.TAP ~= nil
  local hitN, hitX, hitY, hitW, hitH, hitI = 0, {}, {}, {}, {}, {}
  local PB = { 0, 0, 0 }   -- pause button x, y, size

  local function hit(x, y, w, h, i)
    hitN = hitN + 1
    hitX[hitN], hitY[hitN], hitW[hitN], hitH[hitN], hitI[hitN] = x, y, w, h, i
  end

  local function textH(f)
    if lcd.sizeText then
      local _, h = lcd.sizeText("0", f)
      if h and h > 0 then return h end
    end
    return 0
  end

  initUI = function()
    MG = floor(W / 80)
    hS, hM, hL, hX = textH(SMLSIZE), textH(0), textH(MIDSIZE), textH(DBLSIZE)
    if hS == 0 then hS, hM, hL, hX = floor(14 * SC + 0.5), floor(20 * SC + 0.5), floor(28 * SC + 0.5), floor(40 * SC + 0.5) end
  end

  local function txt(x, y, s, f)
    drawText(x, y, s, f + SHADOWED)
  end

  local function panel(x, y, w, h)
    fillRect(x, y, w, h, C.panel, 5)
    drawLine(x, y, x + w - 1, y, SOLID, C.accent)
  end

  local function pauseButton(x, y, s)
    PB[1], PB[2], PB[3] = x, y, s
    fillRect(x, y, s, s, C.panel, 6)
    fillRect(x + s * 0.3, y + s * 0.25, s * 0.14, s * 0.5, C.white)
    fillRect(x + s * 0.56, y + s * 0.25, s * 0.14, s * 0.5, C.white)
  end

  local function nextGateMarker()
    if gmode == 3 or NG == 0 then return end
    local i = nextGate
    local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    local X, Y, Z = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local rxm, rym = VW / 2 - 16 * SC, VH / 2 - 16 * SC
    if Z > 1 then
      local sx, sy = X * F / Z, Y * F / Z
      if sx > -rxm and sx < rxm and sy > -rym and sy < rym then
        local top = (gk[i] == 3 and 0.6 or GHH[gk[i]] + GT + 0.6) * F / Z
        local m = 7 * SC
        local bx, by = CX + sx, CY - sy - top
        if by < VY + m * 2 then by = VY + m * 2 end
        fillTri(bx, by, bx - m, by - m * 1.4, bx + m, by - m * 1.4, C.accent2)
        return
      end
    end
    local ex, ey = X, -Y
    if Z < 0 and ex * ex + ey * ey < 1 then ex, ey = 0, 1 end
    local l = sqrt(ex * ex + ey * ey) + 0.0001
    ex, ey = ex / l, ey / l
    local k = rxm / ((ex < 0 and -ex or ex) + 0.0001)
    local k2 = rym / ((ey < 0 and -ey or ey) + 0.0001)
    if k2 < k then k = k2 end
    local tx, ty, s = CX + ex * k, CY + ey * k, 9 * SC
    fillTri(tx, ty, tx - ex * s * 1.6 - ey * s, ty - ey * s * 1.6 + ex * s, tx - ex * s * 1.6 + ey * s, ty - ey * s * 1.6 - ex * s, C.accent)
  end

  local function drawMinimap(x, y, w, h, alpha)
    if alpha then fillRect(x, y, w, h, C.panel, alpha) end
    local sx, sz = TR.x1 - TR.x0 + 20, TR.z1 - TR.z0 + 20
    local s = (w - 6) / sx
    if (h - 6) / sz < s then s = (h - 6) / sz end
    local ox, oz = x + w / 2 - (TR.x0 + TR.x1) * 0.5 * s, y + h / 2 + (TR.z0 + TR.z1) * 0.5 * s
    for i = 1, NG do
      local j = i % NG + 1
      drawLine(ox + gx[i] * s, oz - gz[i] * s, ox + gx[j] * s, oz - gz[j] * s, SOLID, C.dim)
    end
    local e = 3 * SC + 1
    for i = 1, NG do
      local c = (i == nextGate and gmode ~= 3) and C.accent or C.white
      local gxp, gzp = ox + gx[i] * s, oz - gz[i] * s
      drawLine(gxp - grx[i] * e, gzp + grz[i] * e, gxp + grx[i] * e, gzp - grz[i] * e, SOLID, c)
      drawLine(gxp - grx[i] * e, gzp + grz[i] * e + 1, gxp + grx[i] * e, gzp - grz[i] * e + 1, SOLID, c)
    end
    local dxp, dzp = ox + px * s, oz - pz * s
    local l = sqrt(fx * fx + fz * fz) + 0.0001
    local hx, hz = fx / l, fz / l
    e = 5 * SC + 2
    local b = e * 0.6
    fillTri(dxp + hx * e, dzp - hz * e, dxp - hx * b + hz * b, dzp + hz * b + hx * b, dxp - hx * b - hz * b, dzp + hz * b - hx * b, C.cyan)
  end

  local function stickBox(x, y, s, sx, sy)
    fillRect(x, y, s, s, C.panel, 6)
    drawLine(x + s / 2, y + 2, x + s / 2, y + s - 3, SOLID, C.dim)
    drawLine(x + 2, y + s / 2, x + s - 3, y + s / 2, SOLID, C.dim)
    local d = floor(2 * SC + 2)
    fillRect(x + s / 2 + sx * (s / 2 - d - 1) - d, y + s / 2 - sy * (s / 2 - d - 1) - d, d * 2 + 1, d * 2 + 1, C.accent)
  end

  local function drawSticks(x, y, s, gap)
    local m = getStickMode and getStickMode() or 1
    local t = sT * 2 - 1
    local lx, ly, rx_, ry_ = sR, t, sA, sE                        -- mode 2
    if m == 0 then lx, ly, rx_, ry_ = sR, sE, sA, t                 -- mode 1
    elseif m == 2 then lx, ly, rx_, ry_ = sA, sE, sR, t             -- mode 3
    elseif m == 3 then lx, ly, rx_, ry_ = sA, t, sR, sE end         -- mode 4
    stickBox(x, y, s, lx, ly)
    stickBox(x + s + gap, y, s, rx_, ry_)
  end

  local function lapText()
    local s = "LAP " .. (lap > 0 and lap or 1)
    if gmode == 1 then s = s .. "/" .. S.laps end
    return s
  end

  local function drawHUD()
    local m = MG
    local c = 5 * SC + 1
    drawLine(CX - c * 2, CY, CX - c, CY, SOLID, C.white)
    drawLine(CX + c, CY, CX + c * 2, CY, SOLID, C.white)
    drawLine(CX, CY - c, CX, CY - c * 0.5, SOLID, C.white)
    if state ~= COUNT then nextGateMarker() end
    if PORTRAIT then return end
    if gmode ~= 3 then
      txt(m, m, lapText(), SMLSIZE + C.white)
      txt(m, m + hS, lapStart and timeStr(gt - lapStart) or "0.00", DBLSIZE + C.white)
      local b = bestLap[S.track]
      local rxp = W - m
      if S.map == 1 then rxp = W - m * 2 - floor(H * 0.3) end
      txt(rxp, m, "BEST " .. (b > 0 and timeStr(b) or "--"), SMLSIZE + RIGHT + C.accent2)
      if gmode == 1 and state ~= COUNT then txt(rxp, m + hS, timeStr(gt - tStart), SMLSIZE + RIGHT + C.white) end
    else
      txt(m, m, "FREE FLY", SMLSIZE + C.white)
    end
    if S.map == 1 then
      local ms = floor(H * 0.3)
      drawMinimap(W - m - ms, m, ms, ms, 7)
    end
    local bh, bw = floor(VH * 0.28), floor(6 * SC + 1)
    local by = VY + VH - m - bh
    fillRect(m, by, bw, bh, C.panel, 6)
    local th = floor(bh * sT)
    fillRect(m, by + bh - th, bw, th, sT > 0.7 and C.bad or C.accent)
    txt(m + bw + 4, VY + VH - m - hS, floor(py) .. "m", SMLSIZE + C.white)
    if P.angle then txt(m + bw + 4, VY + VH - m - hS * 2, "ANGLE", SMLSIZE + C.cyan) end
    txt(W - m, VY + VH - m - hL, floor(speed * 3.6) .. " km/h", MIDSIZE + RIGHT + C.white)
    if S.sticks == 1 then
      local s = floor(VH * 0.16)
      drawSticks(CX - s - 2, VY + VH - m - s, s, 4)
    end
    if TOUCH then pauseButton(W / 2 - floor(11 * SC + 3), m, floor(22 * SC + 6)) end
    if S.fps == 1 then txt(W / 2, VY + VH - m - hS - (S.sticks == 1 and floor(VH * 0.16) + 2 or 0), R.fps .. " fps", SMLSIZE + CENTER + C.dim) end
  end

  -- portrait radios (320x480): 4:3 FPV view on top, instrument panel below
  local function drawPanelPortrait()
    local y0 = VH
    fillRect(0, y0, W, H - y0, C.panelBG)
    drawLine(0, y0, W, y0, SOLID, C.accent)
    local m = MG + 2
    local y = y0 + m
    local ms = floor(W * 0.46)
    local x2 = W - m - ms
    drawMinimap(x2, y, ms, ms, 7)
    local sy = y + ms + m
    local s = floor((ms - 6) / 2)
    if s > H - m - sy then s = H - m - sy end
    if s > 16 then drawSticks(x2, sy, s, 6) end
    if gmode ~= 3 then
      drawText(m, y, lapText(), C.white)
      drawText(m, y + hM, lapStart and timeStr(gt - lapStart) or "0.00", DBLSIZE + C.white)
      local b = bestLap[S.track]
      drawText(m, y + hM + hX, "BEST " .. (b > 0 and timeStr(b) or "--"), SMLSIZE + C.accent2)
      if gmode == 1 and state ~= COUNT then drawText(m, y + hM + hX + hS, "RACE " .. timeStr(gt - tStart), SMLSIZE + C.white) end
    else
      drawText(m, y, "FREE FLY", C.white)
    end
    local yb = y + hM + hX + hS * 2 + m
    drawText(m, yb, floor(speed * 3.6) .. " km/h", MIDSIZE + C.white)
    drawText(m, yb + hL, "ALT " .. floor(py) .. "m" .. (P.angle and "  ANGLE" or ""), SMLSIZE + C.dim)
    local tw = x2 - m * 3
    local ty = yb + hL + hS + 4
    fillRect(m, ty, tw, 8, C.panel)
    fillRect(m, ty, floor(tw * sT), 8, sT > 0.7 and C.bad or C.accent)
    if TOUCH then pauseButton(m, H - m - 38, 38) end
    if S.fps == 1 then drawText(m + 48, H - m - hS, R.fps .. " fps", SMLSIZE + C.dim) end
  end

  local function bigCenter(s, col, sub)
    local y = CY - hX / 2 - (sub and hS or 0)
    txt(CX, y, s, DBLSIZE + CENTER + col)
    if sub then txt(CX, y + hX, sub, SMLSIZE + CENTER + C.white) end
  end

  local function drawList(title, n, label, value, x, y, w, maxH)
    hitN = 0
    local rh = hM + floor(8 * SC + 2)
    local top = y
    if title then
      txt(x + MG, y, title, MIDSIZE + C.accent)
      top = y + hL + 4
    end
    local rows = floor((y + maxH - top) / rh)
    if rows > n then rows = n end
    if focus - scroll > rows then scroll = focus - rows end
    if focus <= scroll then scroll = focus - 1 end
    panel(x, top - 2, w, rows * rh + 4)
    for r = 1, rows do
      local i = scroll + r
      local ry = top + (r - 1) * rh
      local foc = i == focus
      if foc then fillRect(x + 2, ry, w - 4, rh, C.accent, editing and 0 or 9) end
      drawText(x + MG + 4, ry + (rh - hM) / 2, label(i), foc and C.white or C.dim)
      local v = value and value(i)
      if v then
        if foc then v = "< " .. v .. " >" end
        drawText(x + w - MG - 4, ry + (rh - hM) / 2, v, RIGHT + (foc and (editing and C.black or C.accent2) or C.white))
      end
      hit(x, ry, w, rh, i)
    end
    if scroll > 0 then drawText(x + w - MG, top - hS, "^", SMLSIZE + RIGHT + C.dim) end
    if scroll + rows < n then drawText(x + w - MG, top + rows * rh, "v", SMLSIZE + RIGHT + C.dim) end
  end

  local function menuBox()
    local w = floor(W * 0.56)
    if PORTRAIT or w < 220 then w = W - MG * 4 end
    return MG * 2, w
  end

  local function mainLabel(i)
    if i == 1 then return "Race (" .. S.laps .. " laps)" end
    return MAIN_ITEMS[i]
  end

  local function mainValue(i)
    if i == 4 then return TRACKS[S.track][1] end
    return nil
  end

  local function drawMenu()
    local x, w = menuBox()
    local y = MG
    txt(x + MG, y, "FPV SIM", DBLSIZE + C.white)
    local tw = lcd.sizeText and lcd.sizeText("FPV SIM ", DBLSIZE) or floor(120 * SC)
    txt(x + MG + tw, y + hX - hS - 4, "3D quad racer", SMLSIZE + C.accent2)
    local t = S.track
    local info = "Best lap " .. (bestLap[t] > 0 and timeStr(bestLap[t]) or "--") .. "   Race " .. (bestRace[t] > 0 and timeStr(bestRace[t]) or "--")
    if PORTRAIT then
      -- 3D view stays clear on top, the menu fills the instrument panel
      txt(x + MG, VH - MG - hS, info, SMLSIZE + C.white)
      fillRect(0, VH, W, H - VH, C.panelBG)
      drawLine(0, VH, W, VH, SOLID, C.accent)
      drawList(nil, #MAIN_ITEMS, mainLabel, mainValue, x, VH + MG * 2, w, H - VH - MG * 3)
      return
    end
    local ly = H - MG - hS
    txt(x + MG, ly, info, SMLSIZE + C.white)
    drawList(nil, #MAIN_ITEMS, mainLabel, mainValue, x, y + hX + 6, w, ly - (y + hX + 6) - 6)
  end

  local function drawDone()
    local w = floor(W * 0.62)
    if PORTRAIT or w < 240 then w = W - MG * 4 end
    local x = (W - w) / 2
    local n = R.n
    if n > 5 then n = 5 end
    local h = hL + hM * 2 + hS * n + MG * 7 + hM + 10
    local y = (PORTRAIT and VH or H) / 2 - h / 2
    if y < MG then y = MG end
    panel(x, y, w, h)
    local cy = y + MG
    drawText(x + w / 2, cy, R.newRace and "NEW RECORD!" or "FINISHED", MIDSIZE + CENTER + (R.newRace and C.accent2 or C.white))
    cy = cy + hL + MG
    drawText(x + MG * 2, cy, "Total", C.dim)
    drawText(x + w - MG * 2, cy, timeStr(R.total), RIGHT + C.white)
    cy = cy + hM
    local b = 0
    for i = 1, R.n do
      if b == 0 or R.laps[i] < b then b = R.laps[i] end
    end
    drawText(x + MG * 2, cy, "Best lap", C.dim)
    drawText(x + w - MG * 2, cy, timeStr(b), RIGHT + (R.newLap and C.accent2 or C.white))
    cy = cy + hM + 4
    for i = 1, n do
      drawText(x + MG * 2, cy, "Lap " .. i, SMLSIZE + C.dim)
      drawText(x + w - MG * 2, cy, timeStr(R.laps[i]), SMLSIZE + RIGHT + (R.laps[i] == b and C.good or C.white))
      cy = cy + hS
    end
    cy = cy + MG
    hitN = 0
    local bw = (w - MG * 6) / 2
    local bh = hM + 8
    fillRect(x + MG * 2, cy, bw, bh, C.accent)
    drawText(x + MG * 2 + bw / 2, cy + 4, "Again", CENTER + C.black)
    hit(x + MG * 2, cy, bw, bh, 1)
    fillRect(x + MG * 4 + bw, cy, bw, bh, C.panelBG)
    drawText(x + MG * 4 + bw * 1.5, cy + 4, "Menu", CENTER + C.white)
    hit(x + MG * 4 + bw, cy, bw, bh, 2)
  end

  render = function()
    if state == MENU or (state == SETUP and prevState == MENU) then orbitCamera() else fpvCamera() end
    render3D()
    if state == MENU then
      if not PORTRAIT then fillRect(0, 0, W, H, C.black, 11) end
      drawMenu()
      return
    end
    if state == SETUP then
      if PORTRAIT then drawPanelPortrait() end
      fillRect(0, 0, W, H, C.black, 7)
      local x, w = menuBox()
      drawList("Settings", #OPTS + 1, setLabel, setValue, x, MG, w, H - MG * 2)
      return
    end
    if state == CRASHED then fillRect(VX, VY, VW, VH, C.red, 11) end
    drawHUD()
    if PORTRAIT then drawPanelPortrait() end
    if state == COUNT then
      bigCenter(tostring(3 - floor((gt - tState) / 100)), C.accent2, "get ready")
    elseif state == CRASHED then
      bigCenter("CRASH", C.white, nil)
    elseif state == READY then
      bigCenter("READY", C.accent2, "move the sticks to fly")
    elseif state == PAUSED then
      local x, w = menuBox()
      local hh = PORTRAIT and VH or H
      fillRect(VX, VY, VW, hh, C.black, 6)
      local lh = hL + 4 + #PAUSE_ITEMS * (hM + floor(8 * SC + 2)) + 4
      local y = floor((hh - lh) / 2)
      if y < MG then y = MG end
      drawList("Paused", #PAUSE_ITEMS, function(i) return PAUSE_ITEMS[i] end, nil, x, y, w, hh - y - MG)
    elseif state == DONE then
      drawDone()
    end
    if R.msg and state ~= PAUSED and state ~= DONE then
      if gt - R.msgT < 220 then
        txt(CX, VY + VH * 0.22, R.msg, MIDSIZE + CENTER + (R.good and C.good or C.accent2))
      else
        R.msg = nil
      end
    end
  end

  hitTest = function(tx, ty)
    for j = 1, hitN do
      if tx >= hitX[j] and tx < hitX[j] + hitW[j] and ty >= hitY[j] and ty < hitY[j] + hitH[j] then
        return hitI[j], (tx - hitX[j]) / hitW[j]
      end
    end
    return nil
  end

  pauseHit = function(tx, ty)
    local s = PB[3] + 10
    return s > 10 and tx >= PB[1] - 5 and tx < PB[1] + s and ty >= PB[2] - 5 and ty < PB[2] + s
  end
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
