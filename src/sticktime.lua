local toolName = "TNS|@TOOLNAME@|TNE"
--[[ ======================================================================
  @TITLE@ v1.6.1  -  a real 3D FPV quad simulator that runs on your radio
  @VARIANT@

  Install : @INSTALL@
            start it from SYS > TOOLS (or SD card browser > Execute).
  Fly     : your sticks fly the quad (acro or angle mode). The radio
            handles stick mode 1-4. EXIT = pause/back, ENTER = select,
            rotary / +- / up-down = move. Touch screens: tap.
  Modes   : Race against AI pilots, Practice, Freestyle (tricks and
            combos) and Gate Rush (beat the clock), on seven tracks.
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
--#if COLOR
local fillTri = lcd.drawFilledTriangle
--#endif
--#if BW
local XM, YM = W - 1, H - 1
local BLK = FORCE          -- B&W default draw mode is XOR: FORCE sets pixels black
-- menus and HUD grow with the fonts on a color radio (StickTimeBW/color.lua sets it); 1 on B&W
local U = STICKTIME_UI or 1
--#endif

local EV = {
  ENTER = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EXIT = EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK,
  NEXT = EVT_VIRTUAL_NEXT, PREV = EVT_VIRTUAL_PREV, INC = EVT_VIRTUAL_INC, DEC = EVT_VIRTUAL_DEC,
  NEXTR = EVT_VIRTUAL_NEXT_REPT, PREVR = EVT_VIRTUAL_PREV_REPT, INCR = EVT_VIRTUAL_INC_REPT, DECR = EVT_VIRTUAL_DEC_REPT,
  TAP = EVT_TOUCH_TAP,
}

-- game states; game modes (gmode): 1 race, 2 practice, 3 freestyle, 4 gate rush
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8

-- ------------------------------------------------------------ settings
local S = { track = 1, quad = 1, twr = 5, mode = 1, rates = 2, rc = 100, rm = 600, re = 50, yc = 100, ym = 500, ye = 40,
            tilt = @TILT@, fov = @FOV@, laps = 3, ai = 2, skill = 2, wind = 0, wash = 0, snd = 2, vib = 1, map = 1, sticks = 0,
            fps = 0 }
-- rows: label, key, then either a value list (+ names, suffix) or nil, nil, suffix, min, max, step
local OPTS = {
  { "Quad", "quad", { 1, 2 }, { "Racer", "Freestyle" } },
  { "Power", "twr", { 3, 4, 5, 6, 7, 8, 10, 12 }, nil, ":1" },
  { "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
  { "Rates", "rates", { 1, 2, 3, 4 }, { "Soft", "Normal", "Fast", "Custom" } },
  { "R/P center", "rc", nil, nil, "@DPS@", 10, 500, 10 },
  { "R/P max", "rm", nil, nil, "@DPS@", 100, 2000, 10 },
  { "R/P expo", "re", nil, nil, nil, 0, 100, 1 },
  { "Yaw center", "yc", nil, nil, "@DPS@", 10, 500, 10 },
  { "Yaw max", "ym", nil, nil, "@DPS@", 100, 2000, 10 },
  { "Yaw expo", "ye", nil, nil, nil, 0, 100, 1 },
  { "Camera tilt", "tilt", nil, nil, "@DEG@", 0, 60, 5 },
  { "Field of view", "fov", nil, nil, "@DEG@", 70, 130, 10 },
  { "Race laps", "laps", { 1, 2, 3, 5, 10 } },
  { "Opponents", "ai", { 0, 1, 2, 3 } },
  { "AI skill", "skill", { 1, 2, 3 }, { "Easy", "Medium", "Hard" } },
  { "Wind", "wind", { 0, 1, 2 }, { "Off", "Light", "Strong" } },
  { "Prop wash", "wash", { 0, 1 }, { "Off", "On" } },
  { "Motor sound", "snd", { 0, 1, 2, 3 }, { "Off", "Low", "Mid", "High" } },
  { "Vibration", "vib", { 0, 1 }, { "Off", "On" } },
--#if COLOR
  { "Minimap", "map", { 0, 1 }, { "Off", "On" } },
  { "Stick view", "sticks", { 0, 1 }, { "Off", "On" } },
--#endif
  { "Show FPS", "fps", { 0, 1 }, { "Off", "On" } },
}
-- Betaflight "actual" rate presets: roll/pitch center, max (deg/s), expo %, then yaw
local RATES = { { 70, 400, 35, 70, 350, 30 }, { 100, 600, 50, 100, 500, 40 }, { 150, 850, 45, 130, 700, 40 } }
local RKEYS = { rc = 1, rm = 2, re = 3, yc = 4, ym = 5, ye = 6 }
-- quad profiles (racer, freestyle): prop pitch speed m/s, rotor drag, side and top
-- drag, motor and rate response time (s) of a well-tuned quad, prop wash strength
local QP = { vp = { 90, 68 }, kh = { 0.55, 0.48 }, ks = { 0.009, 0.0082 }, ku = { 0.028, 0.026 },
             tm = { 0.02, 0.025 }, tr = { 0.012, 0.016 }, pw = { 0.5, 1 } }

-- -------------------------------------------------------------- tracks
-- gates: x, z, type, yaw (deg), center height (0 = default). Types: 1 gate, 2 high gate,
-- 3 dive gate (flat, fly down through it), 4 hoop, 5 arch, 6 flag (pass on its right),
-- 7 flag (pass on its left), 8 gap in a structure.
-- boxes: x, z, half size x, half size z, bottom, top, kind (1 concrete, 2 red, 3 blue).
-- Boxes must not intersect: the renderer orders them with separating planes.
local TRACKS = {
  { "Meadow", 11, { 0,0,1,0,0, 6,34,1,20,0, 26,58,2,70,0, 56,52,1,120,0, 66,22,1,180,0, 52,-8,2,230,0, 24,-22,1,270,0 } },
  { "Figure 8", 23, { -14,10,1,0,0, 6,46,2,40,0, 18,68,1,0,0, 0,88,1,-90,0, -18,68,1,180,0, 18,16,1,180,0, 0,-4,1,-90,0 } },
  { "Dive Tower", 37, { 0,0,1,0,0, 10,30,1,20,0, 12,60,2,0,0, 0,84,2,-90,0, -28,84,3,-90,0, -36,52,1,180,0, -28,20,1,160,0,
                        -12,-14,1,60,0 } },
  { "Slalom", 53, { 0,0,5,0,0, -2,22,6,0,0, 6,40,7,0,0, -2,58,6,0,0, 6,76,7,0,0, 2,96,4,0,3, 22,112,2,90,0, 44,100,4,120,3,
                    48,78,6,180,0, 40,60,7,180,0, 48,42,6,180,0, 44,18,3,200,0, 28,-22,1,-90,0 } },
  { "Hoop Forest", 61, { 0,0,1,0,0, 8,24,4,20,2.4, 24,44,4,50,4.5, 48,54,4,90,6, 72,46,2,130,0, 80,22,4,180,2, 70,-2,4,220,3.5,
                         48,-14,3,247,0, 24,-24,4,300,2.2 }, nil, 2 },
  { "Grand Prix", 71, { 0,0,5,0,0, 0,40,1,0,0, 10,80,2,20,6, 36,104,4,70,3, 64,106,6,100,0, 88,96,7,120,0, 110,76,3,180,0,
                        112,44,1,180,0, 104,14,4,200,2.2, 84,-8,2,250,8, 56,-18,1,270,0, 30,-28,4,290,3 } },
  { "Bando", 83, { 0,0,1,0,0, 0,34,8,0,1.8, 0,46,8,0,1.8, 20,66,4,60,4, 40,88,3,146,0, 56,64,1,180,0, 43.95,10,8,180,1.3,
                   22,-16,4,250,2.5 },
    { -6.225,34,4.025,0.25,0,7,1, 6.225,34,4.025,0.25,0,7,1, 0,34,2.2,0.25,3.6,7,1,
      -6.225,46,4.025,0.25,0,7,1, 6.225,46,4.025,0.25,0,7,1, 0,46,2.2,0.25,3.6,7,1,
      -10,40,0.25,5.75,0,7,1, 10,36.025,0.25,1.775,0,7,1, 10,43.975,0.25,1.775,0,7,1, 10,40,0.25,2.2,3.6,7,1,
      46,64,2,2,0,24,1, 33.6,10,1.25,3,0,2.6,2, 40.5,10,1.25,3,0,2.6,3, 47.4,10,1.25,3,0,2.6,2,
      -30,20,3,1.25,0,5.2,3, -36,50,4,4,0,3,1 } },
}
local NT = #TRACKS
local GT, FLAGH = 0.28, 3.4                            -- frame thickness, flag pole height (m)
local GHW = { 1.5, 1.5, 2.0, 1.25, 2.4, 6, 6, 2.2 }     -- inner half width, ring radius, flag zone
local GHH = { 1.0, 1.0, 2.0, 1.25, 2.4, 30, 30, 1.8 }   -- inner half height
local GSH = { 1, 1, 1, 2, 2, 3, 3, 4 }                 -- shape: 1 frame, 2 ring, 3 flag, 4 gap

-- gates (struct of arrays: fast indexed access in the hot loops)
local NG, gx, gy, gz, gk, gd = 0, {}, {}, {}, {}, {}
local gnx, gny, gnz, grx, grz, gax, gay, gaz = {}, {}, {}, {}, {}, {}, {}, {}
local AX, AY, AZ = {}, {}, {}           -- aim point per gate: racing line, markers, respawn
-- pillars: trees (k=1), gate legs and hoop stands (k=2), flag poles (k=3)
local NP, qx, qz, qr, qh, qk = 0, {}, {}, {}, {}, {}
-- boxes: walls, towers, containers
local BX = { n = 0, x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {}, k = {} }
--#if COLOR
local GB = { x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {} }   -- gate bounds
--#endif
-- start pad, track bounds, wind direction
local TR = { px = 0, pz = -14, hx = 0, hz = 1, x0 = 0, x1 = 1, z0 = 0, z1 = 1, wx = 0, wz = 1 }
-- AI pilots and the racing line (Hermite curves between aim points)
local AI = { n = 0, vt = 0, ch = {}, sl = {}, sf = {}, seg = {}, k = {}, s = {}, v = {}, d = {},
             x = {}, y = {}, z = {}, f = {}, o = {}, x0 = {}, z0 = {}, l0 = {} }

AI.pos = function(i, s)
  local j = i % NG + 1
  local c = AI.ch[i]
  local s2 = s * s
  local s3 = s2 * s
  local h1, h3 = 2 * s3 - 3 * s2 + 1, 3 * s2 - 2 * s3
  local h2, h4 = (s3 - 2 * s2 + s) * c, (s3 - s2) * c
  return h1 * AX[i] + h2 * gnx[i] + h3 * AX[j] + h4 * gnx[j],
         h1 * AY[i] + h2 * gny[i] + h3 * AY[j] + h4 * gny[j],
         h1 * AZ[i] + h2 * gnz[i] + h3 * AZ[j] + h4 * gnz[j]
end

local buildTrack
do
  local GCY = { 1.35, 5.5, 7.0, 2.4, 0, 0, 0, 2.0 }       -- default center height per type
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
  local function boxDist2(x, z)
    local m = 1e9
    for b = 1, BX.n do
      local dx, dz = BX.x0[b] - x, BX.z0[b] - z
      if x - BX.x1[b] > dx then dx = x - BX.x1[b] end
      if z - BX.z1[b] > dz then dz = z - BX.z1[b] end
      if dx < 0 then dx = 0 end
      if dz < 0 then dz = 0 end
      if dx * dx + dz * dz < m then m = dx * dx + dz * dz end
    end
    return m
  end

  buildTrack = function(t)
    local T = TRACKS[t]
    local d, bd = T[3], T[4]
    NG, NP, BX.n = 0, 0, 0
    if bd then
      for i = 1, #bd, 7 do
        local n = BX.n + 1
        BX.n = n
        BX.x0[n], BX.x1[n], BX.z0[n], BX.z1[n] = bd[i] - bd[i + 2], bd[i] + bd[i + 2], bd[i + 1] - bd[i + 3], bd[i + 1] + bd[i + 3]
        BX.y0[n], BX.y1[n], BX.k[n] = bd[i + 4], bd[i + 5], bd[i + 6]
      end
    end
    for i = 1, #d, 5 do
      NG = NG + 1
      local k, yaw = d[i + 2], d[i + 3] * 0.0174533
      local hx, hz = sin(yaw), cos(yaw)
      local x, z, y = d[i], d[i + 1], d[i + 4]
      if y <= 0 then y = GCY[k] end
      local iw, ih = GHW[k], GHH[k]
      grx[NG], grz[NG] = hz, -hx
      if k == 3 then
        gnx[NG], gny[NG], gnz[NG] = 0, -1, 0
        gax[NG], gay[NG], gaz[NG] = hx, 0, hz
      else
        gnx[NG], gny[NG], gnz[NG] = hx, 0, hz
        gax[NG], gay[NG], gaz[NG] = 0, 1, 0
      end
      local ax, ay, az = x, y, z
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
      elseif k == 4 then
        addPillar(x, z, 0.08, y - iw - GT, 2)
      elseif k == 5 then
        ay = 1.4
      elseif k == 6 or k == 7 then
        -- (x, z) is the pole; the gate itself is the pass zone beside it
        local s = k == 6 and 1 or -1
        addPillar(x, z, 0.12, FLAGH, 3)
        ax, ay, az = x + hz * s * 2.5, 1.8, z - hx * s * 2.5
        x, z, y = x + hz * s * iw, z - hx * s * iw, 0
      end
      gx[NG], gy[NG], gz[NG], gk[NG] = x, y, z, k
      AX[NG], AY[NG], AZ[NG] = ax, ay, az
--#if COLOR
      -- bounds of what is drawn for this gate (legs and stands down to the ground)
      local sx, sz = hz < 0 and -hz or hz, hx < 0 and -hx or hx
      local w, d, y0, y1 = iw + GT, 0.2, y - ih - GT, y + ih + GT
      if k == 3 then d, y0, y1 = ih + GT, 0, y + GT
      elseif k == 2 then y0 = 0
      elseif k == 4 or k == 5 then y0, y1 = 0, y + iw + GT
      elseif k == 8 then w, d, y0, y1 = iw, 0, y - ih, y + ih end
      local bx, bz = x, z
      if k == 6 or k == 7 then
        local o = (k == 6 and -1 or 1) * iw
        bx, bz, w, d, y0, y1 = x + hz * o, z - hx * o, 1, 1, 0, FLAGH
      end
      GB.x0[NG], GB.x1[NG] = bx - sx * w - sz * d, bx + sx * w + sz * d
      GB.z0[NG], GB.z1[NG] = bz - sz * w - sx * d, bz + sz * w + sx * d
      GB.y0[NG], GB.y1[NG] = y0, y1
--#endif
    end
    TR.hx, TR.hz = gnx[1], gnz[1]
    TR.px, TR.pz = AX[1] - TR.hx * 14, AZ[1] - TR.hz * 14
    local x0, x1, z0, z1 = TR.px, TR.px, TR.pz, TR.pz
    for i = 1, NG do
      if gx[i] < x0 then x0 = gx[i] end
      if gx[i] > x1 then x1 = gx[i] end
      if gz[i] < z0 then z0 = gz[i] end
      if gz[i] > z1 then z1 = gz[i] end
    end
    for b = 1, BX.n do
      if BX.x0[b] < x0 then x0 = BX.x0[b] end
      if BX.x1[b] > x1 then x1 = BX.x1[b] end
      if BX.z0[b] < z0 then z0 = BX.z0[b] end
      if BX.z1[b] > z1 then z1 = BX.z1[b] end
    end
    TR.x0, TR.x1, TR.z0, TR.z1 = x0, x1, z0, z1
    seed = T[2]
    local a = rnd() * 6.2832
    TR.wx, TR.wz = sin(a), cos(a)
    -- scenery trees, kept away from the racing line and structures
    local n, tries, want = 0, 0, @TREES@ * (T[5] or 1)
    while n < want and tries < want * 16 do
      tries = tries + 1
      local x = x0 - 30 + rnd() * (x1 - x0 + 60)
      local z = z0 - 30 + rnd() * (z1 - z0 + 60)
      local ok = segDist2(x, z, TR.px, TR.pz, AX[1], AZ[1]) > 100 and boxDist2(x, z) > 16
      for i = 1, NG do
        local j = i % NG + 1
        if ok and segDist2(x, z, AX[i], AZ[i], AX[j], AZ[j]) < 100 then ok = false end
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
    -- racing line: length and speed factor of each leg
    for i = 1, NG do
      local j = i % NG + 1
      local dx, dy, dz = AX[j] - AX[i], AY[j] - AY[i], AZ[j] - AZ[i]
      local c = sqrt(dx * dx + dy * dy + dz * dz) + 0.01
      AI.ch[i] = c
      local L, lx, ly, lz = 0, AX[i], AY[i], AZ[i]
      for q = 1, 8 do
        local x, y, z = AI.pos(i, q / 8)
        L = L + sqrt((x - lx) * (x - lx) + (y - ly) * (y - ly) + (z - lz) * (z - lz))
        lx, ly, lz = x, y, z
      end
      AI.sl[i] = L
      dx, dy, dz = dx / c, dy / c, dz / c
      local k1 = dx * gnx[i] + dy * gny[i] + dz * gnz[i]
      local k2 = dx * gnx[j] + dy * gny[j] + dz * gnz[j]
      if k2 < k1 then k1 = k2 end
      AI.sf[i] = 0.55 + 0.225 * (k1 + 1)
    end
  end
end

-- --------------------------------------------------------- persistence
local BEST = { l = {}, r = {}, g = {}, f = {} }   -- per track: best lap, race, gate rush gates, freestyle combo
for t = 1, NT do BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t] = 0, 0, 0, 0 end
local loadData, saveData
do
local DATA = "/SCRIPTS/TOOLS/@DATAFILE@"
local OLD = "/SCRIPTS/TOOLS/@OLDDATA@"                 -- the save under the old name, FPV Sim

local DEF = {}
for k, v in pairs(S) do DEF[k] = v end

local function validate()
  for i = 1, #OPTS do
    local o = OPTS[i]
    local v, ok = S[o[2]], false
    if type(v) == "number" then
      if o[3] then
        for j = 1, #o[3] do
          if o[3][j] == v then ok = true end
        end
      else
        ok = v >= o[6] and v <= o[7]
      end
    end
    if not ok then S[o[2]] = DEF[o[2]] end
  end
  if type(S.track) ~= "number" or S.track < 1 or S.track > NT then S.track = 1 end
end

loadData = function()
  local f, old = io.open(DATA, "r"), false
  if not f then f, old = io.open(OLD, "r"), true end
  if not f then return end
  local s = io.read(f, 1024)
  io.close(f)
  if type(s) ~= "string" then return end
  if string.sub(s, 1, 7) == "FPVSIM2" then
    for k, n, v in string.gmatch(s, "(%a+)(%d*)=(%-?%d+)") do
      v = tonumber(v)
      if n == "" then
        if S[k] ~= nil then S[k] = v end
      else
        local t = tonumber(n)
        if BEST[k] and t >= 1 and t <= NT then BEST[k][t] = v end
      end
    end
  elseif string.sub(s, 1, 6) == "FPVSIM" then
    -- version 1 file: 10 settings, then best lap / race of the first three tracks
    local v, n = {}, 0
    for num in string.gmatch(s, "%-?%d+") do
      n = n + 1
      v[n] = tonumber(num)
    end
    local K1 = { "track", "mode", "rates", "tilt", "fov", "twr", "laps", "map", "sticks", "fps" }
    for i = 1, 10 do
      if v[i] then S[K1[i]] = v[i] end
    end
    S.twr = ({ 3, 4, 6 })[v[6] or 2] or 5
    for t = 1, 3 do
      BEST.l[t], BEST.r[t] = v[9 + t * 2] or 0, v[10 + t * 2] or 0
    end
  end
  validate()
  if old then saveData() end                       -- under the new name right away
end

saveData = function()
  local s = "FPVSIM2"
  for k, v in pairs(S) do s = s .. " " .. k .. "=" .. floor(v) end
  for k, b in pairs(BEST) do
    for t = 1, NT do
      if b[t] > 0 then s = s .. " " .. k .. t .. "=" .. floor(b[t]) end
    end
  end
  local f = io.open(DATA, "w")
  if f then
    io.write(f, s .. "\n")
    io.close(f)
  end
end
end

-- ----------------------------------------------------------- game state
local px, py, pz, vx, vy, vz = 0, 0.15, 0, 0, 0, 0                 -- quad position / velocity (m, m/s)
local rx, ry, rz, ux, uy, uz, fx, fy, fz = 1, 0, 0, 0, 1, 0, 0, 0, 1 -- quad right / up / forward axes
local sA, sE, sT, sR, speed = 0, 0, 0, 0, 0                           -- sticks, speed
local DR, NEAR = 0.15, 0.2                                            -- quad radius, camera near plane
local P = { rc = 100, rm = 600, re = 0.5, yc = 100, ym = 500, ye = 0.4, twr = 5, angle = false, tc = 0.9, ts = 0.42,
            wr = 0, wp = 0, wy = 0 }                                  -- settings in use, body rates (rad/s)
local state, prevState, pausedFrom, gmode = MENU, MENU, FLY, 1
local gt, lastT, tState, tStart = 0, 0, 0, 0                          -- game clock in 10 ms ticks
local lapStart, lap, nextGate, lastGate = nil, 0, 1, 0
local R = { laps = {}, n = 0, total = 0, newLap = false, newRace = false, newBest = false, msg = nil, msgT = 0, good = true,
            ready = 0, crashes = 0, cd = -1, fps = 0, fpsN = 0, fpsT = 0, fpsX = "", runS = 0, showS = 0,
            pk = 0, pos = 1, sc = 0, ch = 0, chn = 0, cht = 0, prox = 9, rn = 0, rt = 0, smp = 0,
            fi = 5, pt = 0 }                                  -- frame interval, sim time (10 ms ticks)

local function timeStr(cs)
  cs = floor(cs)
  local s = floor(cs / 100)
  if s >= 60 then return fmt("%d:%02d.%02d", floor(s / 60), s % 60, cs % 100) end
  return fmt("%d.%02d", s, cs % 100)
end

-- HUD clocks: lap number, lap time, race time (ticks); frozen once the race is over
local function lapClock()
  if gmode == 1 and state == DONE and R.n > 0 then return S.laps, R.laps[R.n], R.total end
  return lap > 0 and lap or 1, lapStart and gt - lapStart or 0, gt - tStart
end

local function beep(f, d, flags)
  if playTone then playTone(f, d, 0, flags or 0) end
end

local function showMsg(s, good)
  R.msg, R.msgT, R.good = s, gt, good
end

-- -------------------------------------------------------------- physics
local readSticks, rotate, placeDrone, respawn, physics, rnd, trick, tricks, rushNext, motorSound
;(function()
  local G = 9.81
  local SRC = { "ail", "ele", "thr", "rud" }
  local grounded = true
  local nearG, nearP, nearB = {}, {}, {}
  local Tm = 0                                   -- motor thrust (lags the throttle)
  local wob1, wob2 = 0, 0                        -- prop wash wobble (rad/s)
  local seed = 7

  rnd = function()
    seed = seed * 171 % 30269
    return seed / 30269
  end

  -- motor sound: a tone on the radio's background channel (the vario's), its pitch following
  -- the motors' speed, which goes with the square root of their thrust: about 190 Hz at idle,
  -- 320 Hz at a 5:1 hover and 540 Hz flat out, up to 7% higher while the quad rotates fast.
  -- Each call restarts the tone's 200 ms, so it plays on as long as frames keep coming.
  local SNDV, sndOn = { 1, 3, 5 }, false          -- tone volume (1-5) for Low, Mid, High
  motorSound = function(on)
    if not (playTone and PLAY_BACKGROUND) then return end
    if on and S.snd > 0 then
      local w = sqrt(P.wr * P.wr + P.wp * P.wp + P.wy * P.wy)
      local f = (140 + 400 * sqrt(Tm / (P.twr * G))) * (1 + (w < 12 and w or 12) * 0.006)
      playTone(floor(f), 200, 0, PLAY_BACKGROUND + PLAY_NOW, 0, SNDV[S.snd])
      sndOn = true
    elseif sndOn then
      playTone(200, 0, 0, PLAY_BACKGROUND + PLAY_NOW)   -- silence at once
      sndOn = false
    end
  end

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

  -- Betaflight "actual" rates: center sensitivity c, max rate m (deg/s), expo e
  local function rate(x, c, m, e)
    local a = x < 0 and -x or x
    local x2 = x * x
    return (x * c + (m - c) * a * x * (x2 * x2 * e + 1 - e)) * 0.0174533
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
    if l < 0.01 then hx, hz, l = TR.hx, TR.hz, 1 end
    hx, hz = hx / l, hz / l
    fx, fy, fz, rx, ry, rz, ux, uy, uz = hx, 0, hz, hz, 0, -hx, 0, 1, 0
    grounded = y <= DR + 0.01
    speed, Tm, P.wr, P.wp, P.wy = 0, 0, 0, 0, 0
    for i = 1, NG do
      gd[i] = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i]
    end
  end

  respawn = function()
    if gmode == 3 then
      if R.ax then placeDrone(R.ax, R.ay + 0.5, R.az, R.ahx, R.ahz) else placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz) end
    elseif lastGate > 0 then
      local i, j = lastGate, nextGate
      local y = AY[i]
      if gk[i] == 3 then y = y - 1.5 end
      placeDrone(AX[i] + gnx[i] * 1.5, y, AZ[i] + gnz[i] * 1.5, AX[j] - AX[i], AZ[j] - AZ[i])
    else
      placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
    end
  end

  local function crash()
    if state == DONE then respawn() return end
    state, tState, R.crashes = CRASHED, gt, R.crashes + 1
    if gmode == 3 then
      R.ch, R.chn = 0, 0
      tricks(-1)
    end
    beep(260, 400, PLAY_NOW)
    if playHaptic and S.vib == 1 then playHaptic(60, 0) end
  end

  local function finishRace()
    R.total = gt - tStart
    local t = S.track
    if BEST.r[t] == 0 or R.total < BEST.r[t] then
      BEST.r[t], R.newRace = R.total, true
    end
    local p = 1
    for a = 1, AI.n do
      if AI.d[a] > 0 then p = p + 1 end
    end
    R.pos = p
    state, tState = DONE, gt
    saveData()
    beep(1800, 120)
    beep(2400, 300)
  end

  local function gatePassed(i, fwd)
    if state == DONE then return end
    if gmode == 3 then
      if GSH[gk[i]] ~= 3 then trick("GAP", 150) end
      return
    end
    if i ~= nextGate then return end
    if gmode == 4 then
      R.rn = R.rn + 1
      local b = 6 - R.rn * 0.15
      if b < 2.5 then b = 2.5 end
      R.rt = R.rt + b
      lastGate = i
      rushNext()
      showMsg("GATE " .. R.rn .. "  +" .. fmt("%.1f", b) .. "s", true)
      beep(1300 + R.rn * 30, 60)
      return
    end
    if not fwd then return end
    lastGate, nextGate = i, i % NG + 1
    R.pk = R.pk + 1
    if i == 1 then
      if lapStart then
        local lt = gt - lapStart
        R.n = R.n + 1
        R.laps[R.n] = lt
        local b = BEST.l[S.track]
        if b == 0 or lt < b then
          BEST.l[S.track], R.newLap = lt, true
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  BEST!", true)
          saveData()
        else
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  +" .. timeStr(lt - b), false)
        end
        lap = lap + 1
        beep(2200, 160)
        if playHaptic and S.vib == 1 then playHaptic(25, 0) end
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
    local Tmax = P.twr * G
    local wr, wp
    if P.angle then
      -- self level: steer the up vector towards the stick-commanded tilt (45 deg at full stick)
      local hx, hz = -rz, rx
      local l = sqrt(hx * hx + hz * hz) + 0.0001
      hx, hz = hx / l, hz / l
      local dx, dz = hx * sE + hz * sA, hz * sE - hx * sA
      wr, wp = 8 * (dx * rx + ry + dz * rz), -8 * (dx * fx + fy + dz * fz)
      if wr > 8 then wr = 8 elseif wr < -8 then wr = -8 end
      if wp > 8 then wp = 8 elseif wp < -8 then wp = -8 end
    else
      wr, wp = rate(sA, P.rc, P.rm, P.re), -rate(sE, P.rc, P.rm, P.re)
    end
    local wy = rate(sR, P.yc, P.ym, P.ye)
    local T = Tmax * (0.015 + 0.985 * sT ^ 1.6)        -- 1.5% at idle, like DShot idle on a tuned quad
    -- prop wash (setting, off by default): descending into your own downwash
    -- makes the quad wobble. Smoothed noise, so it reads as a wobble, not jitter.
    if S.wash == 1 then
      local vu0 = vx * ux + vy * uy + vz * uz
      if vu0 < -2 and sT > 0.2 then
        local a = (-vu0 - 2) * 0.2
        if a > 1 then a = 1 end
        a = a * sT * P.pw * 2.5
        wob1, wob2 = wob1 * 0.6 + (rnd() - 0.5) * a, wob2 * 0.6 + (rnd() - 0.5) * a
        wr, wp = wr + wob1, wp + wob2
      else
        wob1, wob2 = 0, 0
      end
    end
    if grounded and T < G * 1.02 then
      -- resting on the ground: stays level, can only yaw
      wr, wp, P.wr, P.wp = 0, 0, 0, 0
      if uy < 0.999 then placeDrone(px, DR, pz, fx, fz) end
    end
    -- wind with gusts, weaker near the ground
    local wx, wz = 0, 0
    if S.wind > 0 and py > 0.3 then
      local g = (S.wind == 1 and 3 or 7) * (1 + 0.3 * sin(gt * 0.009) + 0.2 * sin(gt * 0.031))
      if py < 4 then g = g * py * 0.25 end
      wx, wz = TR.wx * g, TR.wz * g
    end
    local n = floor(dt * 80) + 1
    local h = dt / n
    local km, kr = h / (P.tm + h), h / (P.tr + h)
    local KH, VP, KS, KU, sTx = P.kh, P.vp, P.ks, P.ku, sqrt(Tmax)
    local x0, x1, z0, z1 = TR.x0 - 160, TR.x1 + 160, TR.z0 - 160, TR.z1 + 160
    local bx0, bx1, by0, by1, bz0, bz1 = BX.x0, BX.x1, BX.y0, BX.y1, BX.z0, BX.z1
    -- broad phase once per frame: only objects within reach get tested per substep
    local reach = speed * dt + 7
    local ng, np, nb = 0, 0, 0
    for i = 1, NG do
      local dx, dy, dz = px - gx[i], py - gy[i], pz - gz[i]
      local r = GSH[gk[i]] == 3 and reach + 6 or reach
      if dx < r and dx > -r and dy < r and dy > -r and dz < r and dz > -r then
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
    for i = 1, BX.n do
      if px > bx0[i] - reach and px < bx1[i] + reach and pz > bz0[i] - reach and pz < bz1[i] + reach and py < by1[i] + reach then
        nb = nb + 1
        nearB[nb] = i
      end
    end
    -- the surface under the quad, for ground effect: the ground, or the top of a structure
    local fl = 0
    for j = 1, nb do
      local i = nearB[j]
      if px > bx0[i] and px < bx1[i] and pz > bz0[i] and pz < bz1[i] and py > by1[i] and by1[i] > fl then fl = by1[i] end
    end
    local pwr, pwp, pwy = P.wr, P.wp, P.wy
    for _ = 1, n do
      Tm = Tm + (T - Tm) * km
      pwr, pwp, pwy = pwr + (wr - pwr) * kr, pwp + (wp - pwp) * kr, pwy + (wy - pwy) * kr
      rotate(pwr * h, pwp * h, pwy * h)
      -- air-relative velocity in body axes
      local ax_, az_ = vx - wx, vz - wz
      local vu = ax_ * ux + vy * uy + az_ * uz
      local vr = ax_ * rx + vy * ry + az_ * rz
      local vf = ax_ * fx + vy * fy + az_ * fz
      -- props lose thrust with inflow speed; rotor drag in the prop plane (grows with the air
      -- the props move, so with thrust: the same at hover for any power); quadratic body drag
      local Ta = Tm - vu * sqrt(Tm) * sTx / VP
      if Ta > Tm * 1.25 then Ta = Tm * 1.25 elseif Ta < 0 then Ta = 0 end
      -- ground effect: near the ground or a roof the props push their air against it and get
      -- more thrust: +12% skimming it, +3% at 30 cm, nothing to speak of from 1 m up. Less when
      -- tilted, and it fades with speed as the quad leaves its downwash behind.
      local hg = py - fl
      if hg < 1.2 and uy > 0.3 then
        if hg < 0.15 then hg = 0.15 end
        local k = 0.049 * uy / hg
        Ta = Ta / (1 - k * k / (1 + (vx * vx + vz * vz) * 0.018))
      end
      local kh = KH * sqrt(Tm * 0.0204 + 0.02)   -- 0.0204 = 1 / (5 G)
      local au = Ta - KU * (vu < 0 and -vu or vu) * vu
      local ar = -(kh + KS * (vr < 0 and -vr or vr)) * vr
      local af = -(kh + KS * (vf < 0 and -vf or vf)) * vf
      vx = vx + (ux * au + rx * ar + fx * af) * h
      vy = vy + (uy * au + ry * ar + fy * af - G) * h
      vz = vz + (uz * au + rz * ar + fz * af) * h
      local ox, oy, oz = px, py, pz
      px, py, pz = px + vx * h, py + vy * h, pz + vz * h
      grounded = false
      if py < DR then
        if vy < -6 or vx * vx + vz * vz > 196 or uy < 0.35 then crash() return end
        py, grounded = DR, true
        if vy < 0 then vy = 0 end
        local fr = 1 - 7 * h
        vx, vz = vx * fr, vz * fr
      end
      if py > 250 or px < x0 or px > x1 or pz < z0 or pz > z1 then crash() return end
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
          local k = gk[i]
          local iw, ih, sh = GHW[k], GHH[k], GSH[k]
          if sh == 2 then
            local r2, a, b = lx * lx + ly * ly, iw - DR * 0.5, iw + GT + DR
            if r2 < a * a then gatePassed(i, d1 >= 0)
            elseif r2 < b * b then crash() return end
          else
            if lx < 0 then lx = -lx end
            if ly < 0 then ly = -ly end
            if lx < iw - DR * 0.5 and ly < ih - DR * 0.5 then gatePassed(i, d1 >= 0)
            elseif sh == 1 and lx < iw + GT + DR and ly < ih + GT + DR then crash() return end
          end
          if state ~= FLY and state ~= DONE then return end
        end
      end
      -- trees, legs, poles and structures
      for j = 1, np do
        local i = nearP[j]
        local dx, dz, r = px - qx[i], pz - qz[i], qr[i] + DR
        if dx < r and dx > -r and dz < r and dz > -r and py < qh[i] and dx * dx + dz * dz < r * r then crash() return end
      end
      for j = 1, nb do
        local i = nearB[j]
        if px > bx0[i] - DR and px < bx1[i] + DR and pz > bz0[i] - DR and pz < bz1[i] + DR and py < by1[i] + DR and py > by0[i] - DR then
          crash() return
        end
      end
    end
    P.wr, P.wp, P.wy = pwr, pwp, pwy
    orthonormalize()
    speed = sqrt(vx * vx + vy * vy + vz * vz)
    if gmode == 3 then
      -- distance to the nearest surface, for proximity tricks
      local m = py + 0.7
      for j = 1, np do
        local i = nearP[j]
        if py < qh[i] then
          local dx, dz = px - qx[i], pz - qz[i]
          local d = sqrt(dx * dx + dz * dz) - qr[i]
          if d < m then m = d end
        end
      end
      for j = 1, nb do
        local i = nearB[j]
        local dx, dy, dz = bx0[i] - px, by0[i] - py, bz0[i] - pz
        if px - bx1[i] > dx then dx = px - bx1[i] end
        if py - by1[i] > dy then dy = py - by1[i] end
        if pz - bz1[i] > dz then dz = pz - bz1[i] end
        if dx < 0 then dx = 0 end
        if dy < 0 then dy = 0 end
        if dz < 0 then dz = 0 end
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < m then m = d end
      end
      R.prox = m
    end
  end
end)()

-- ----------------------------------------------------- freestyle tricks
;(function()
  local acc, t0, idle, thr, nrot = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
  local hiY, hiT, inv, prox = 0, 0, 0, 0
  local NAME = { "ROLL", "ROLL", "BACKFLIP", "FRONTFLIP", "360", "360" }
  local PTS = { 100, 100, 50 }

  local function mult()
    local m = 1 + (R.chn - 1) * 0.5
    if m > 4 then m = 4 end
    return m
  end

  trick = function(name, pts)
    pts = floor(pts)
    R.ch, R.chn, R.cht = R.ch + pts, R.chn + 1, gt
    showMsg(name .. " +" .. pts, true)
    beep(1400 + R.chn * 120, 50)
  end

  local function bank()
    local v = floor(R.ch * mult())
    R.sc = R.sc + v
    if v > BEST.f[S.track] then
      BEST.f[S.track], R.newBest = v, true
      showMsg("COMBO " .. v .. "  BEST!", true)
      beep(2400, 200)
      saveData()
    elseif R.chn > 1 then
      showMsg("COMBO " .. v, true)
    end
    R.ch, R.chn = 0, 0
  end

  -- continuous rotation about one body axis: 330 deg counts as a full turn
  local function axis(a, w, dt)
    local s = acc[a]
    if (w > 1.5 and s >= 0) or (w < -1.5 and s <= 0) then
      if nrot[a] < 1 and s > -0.01 and s < 0.01 then t0[a], thr[a] = gt, 0 end
      s = s + w * dt
      thr[a] = thr[a] + sT * dt
      idle[a] = 0
      local need = 5.76 + nrot[a] * 6.2832
      if s > need or s < -need then
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

  tricks = function(dt)
    if dt < 0 then
      for a = 1, 3 do acc[a], nrot[a], idle[a] = 0, 0, 0 end
      hiY, inv, prox = 0, 0, 0
      return
    end
    axis(1, P.wr, dt)
    axis(2, P.wp, dt)
    axis(3, P.wy, dt)
    -- dive: a fast drop of 10 m or more that ends under control
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
    if R.prox < 1.5 and speed > 8 then prox = prox + dt
    else
      if prox > 0.3 then trick("PROXY", prox * 150) end
      prox = 0
    end
    if R.chn > 0 and gt - R.cht > 250 then bank() end
  end
end)()

-- ------------------------------------------------- gate rush, AI pilots
rushNext = function()
  local j = nextGate
  for _ = 1, 30 do
    j = floor(rnd() * NG) + 1
    if j > NG then j = NG end
    if j ~= nextGate and j ~= lastGate and GSH[gk[j]] ~= 3 then break end
  end
  nextGate = j
end

AI.start = function()
  local n = gmode == 1 and S.ai or 0
  AI.n = n
  AI.vt = ({ 9, 13, 17.5 })[S.skill] * (0.75 + 0.05 * S.twr)
  for a = 1, n do
    local L = a == 1 and 2.2 or (a == 2 and -2.2 or 0)
    local B = a == 3 and 3 or 0
    local x, z = TR.px + TR.hz * L - TR.hx * B, TR.pz - TR.hx * L - TR.hz * B
    local dx, dz = AX[1] - x, AZ[1] - z
    AI.x0[a], AI.z0[a], AI.l0[a] = x, z, sqrt(dx * dx + dz * dz) + 0.01
    AI.x[a], AI.y[a], AI.z[a] = x, DR, z
    AI.seg[a], AI.k[a], AI.s[a], AI.v[a], AI.d[a] = 0, 0, 0, 0, 0
    AI.f[a] = 1.02 - 0.04 * a + rnd() * 0.04
    AI.o[a] = L * 0.25
  end
end

AI.update = function(dt)
  local last = S.laps * NG + 1
  for a = 1, AI.n do
    local seg = AI.seg[a]
    local vt, L = AI.vt * AI.f[a], AI.l0[a]
    if seg > 0 then L, vt = AI.sl[seg], vt * AI.sf[seg] end
    if AI.d[a] > 0 then vt = vt * 0.6 end
    local v = AI.v[a]
    if v < vt then
      v = v + 10 * dt
      if v > vt then v = vt end
    else
      v = v - 14 * dt
      if v < vt then v = vt end
    end
    AI.v[a] = v
    local s = AI.s[a] + v * dt / L
    if s >= 1 then
      s = s - 1
      if s > 0.9 then s = 0.9 end
      seg = seg % NG + 1
      AI.seg[a], AI.k[a] = seg, AI.k[a] + 1
      if AI.k[a] == last and AI.d[a] <= 0 then AI.d[a] = gt - tStart end
    end
    AI.s[a] = s
    local x, y, z
    if seg == 0 then
      x, y, z = AI.x0[a] + (AX[1] - AI.x0[a]) * s, DR + (AY[1] - DR) * s, AI.z0[a] + (AZ[1] - AI.z0[a]) * s
    else
      x, y, z = AI.pos(seg, s)
      local j, o = seg % NG + 1, AI.o[a]
      x = x + (grx[seg] + (grx[j] - grx[seg]) * s) * o
      z = z + (grz[seg] + (grz[j] - grz[seg]) * s) * o
      if y < 0.4 then y = 0.4 end
    end
    AI.x[a], AI.y[a], AI.z[a] = x, y, z
  end
end

-- race position: 1 + AI pilots ahead of the player
AI.place = function()
  local pk, pf = R.pk, 0
  local i = nextGate
  local dx, dy, dz = AX[i] - px, AY[i] - py, AZ[i] - pz
  local d = sqrt(dx * dx + dy * dy + dz * dz)
  local L = pk > 0 and AI.sl[lastGate] or 14
  pf = 1 - d / L
  local p = 1
  for a = 1, AI.n do
    local k = AI.k[a]
    if AI.d[a] > 0 or k > pk or (k == pk and AI.s[a] > pf) then p = p + 1 end
  end
  return p
end

-- --------------------------------------------------------------- camera
local kpx, kpy, kpz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1
local PORTRAIT = H > W
local VX, VY, VW, VH = 0, 0, W, H
if PORTRAIT then VH = floor(W * 3 / 4) end
local CX, CY = VX + VW / 2, VY + VH / 2
local SC = VW / @REFW@
local F, tanH = 160, 1.4

-- FPV camera, rendered where the quad will be when the frame reaches the screen. Color
-- screens show a frame one script cycle after it is drawn (50 ms on stock EdgeTX), so the
-- prediction follows the measured frame interval and stays right on faster firmware too.
-- STICKTIME_LAT (seconds) overrides it, e.g. in the emulator when frames show at once
-- (FPVSIM_LAT: its name before the rename to StickTime). StickTime BW on a color radio has
-- the color screen's delay too: its color.lua sets STICKTIME_LATK to the color factor.
-- The turn is predicted over a third of that time only: the stick can center at any moment,
-- and a fast roll drawn the whole delay ahead overshoots for a frame and swings back when it
-- stops (about 35 deg at 850 deg/s). A third is about as long as the quad keeps turning after
-- the stick centers, so the picture no longer swings back, and still gains 20 ms.
local function fpvCamera()
  local c, s = P.tc, P.ts
  local d = (state == FLY or state == DONE) and (STICKTIME_LAT or FPVSIM_LAT or R.fi * (STICKTIME_LATK or @LATK@)) or 0
  local a1, a2, a3, b1, b2, b3, e1, e2, e3 = rx, ry, rz, ux, uy, uz, fx, fy, fz
  local dr = d * 0.35
  if d > 0 then rotate(P.wr * dr, P.wp * dr, P.wy * dr) end
  kpx, kpy, kpz = px + vx * d, py + vy * d, pz + vz * d
  if kpy < 0.05 then kpy = 0.05 end
  krx, kry, krz = rx, ry, rz
  kfx, kfy, kfz = fx * c + ux * s, fy * c + uy * s, fz * c + uz * s
  kux, kuy, kuz = ux * c - fx * s, uy * c - fy * s, uz * c - fz * s
  rx, ry, rz, ux, uy, uz, fx, fy, fz = a1, a2, a3, b1, b2, b3, e1, e2, e3
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
  local r = RATES[S.rates]
  if r then
    P.rc, P.rm, P.re, P.yc, P.ym, P.ye = r[1], r[2], r[3] * 0.01, r[4], r[5], r[6] * 0.01
  else
    P.rc, P.rm, P.re, P.yc, P.ym, P.ye = S.rc, S.rm, S.re * 0.01, S.yc, S.ym, S.ye * 0.01
  end
  for k, v in pairs(QP) do P[k] = v[S.quad] or v[1] end
  P.twr = S.twr
  P.angle = S.mode == 2
  local t = S.tilt * 0.0174533
  P.tc, P.ts = cos(t), sin(t)
  tanH = sin(S.fov * 0.00872665) / cos(S.fov * 0.00872665)
  F = (VW / 2) / tanH
end

-- visible objects, drawn far -> near (painter's algorithm). ids: gates 1..NG, trees -i,
-- boxes 1000+b, AI pilots 2000+a. ordP holds the draw order (indices into the ord* arrays).
local ordZ, ordI, ordP, nOrd = {}, {}, {}, 0
local collectObjects
do
--#if COLOR
  -- With structures in view, depth order is not enough (a long wall's center can be far
  -- while its near end hides things). Pairs that overlap on screen and involve a structure
  -- get an exact rule from a separating plane: if the two bounds are apart along x, y or z
  -- and the camera is on one side of the gap, the object on that side is in front. Then a
  -- topological sort (Kahn) draws everything far to near while keeping those rules.
  local OB = { x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {}, b = {} }
  local sx0, sx1, sy0, sy1 = {}, {}, {}, {}            -- screen rectangle of each object
  local EA, EB, SU, cnt, st, indeg, done, DO = {}, {}, {}, {}, {}, {}, {}, {}

  -- Rules only for pairs with a structure in them that overlap on screen. A plane between
  -- their boxes (along x, then z, then y) with the camera on one side puts the other object
  -- behind: rule 1 draws i before j, -1 after, 0 none (they cannot overlap on screen).
  -- Touching faces count as separated (2 cm tolerance: radio Lua uses 32-bit floats).
  -- Boxes that intersect (a tree's box touching a wall): the farther one first.
  local function sortWithStructures(n)
    local ne = 0
    local isB, X0, X1, Y0, Y1, Z0, Z1 = OB.b, OB.x0, OB.x1, OB.y0, OB.y1, OB.z0, OB.z1
    local cx, cy, cz = kpx, kpy, kpz
    for i = 1, n do
      if isB[i] then
        local p0, p1, q0, q1 = sx0[i], sx1[i], sy0[i], sy1[i]
        local a0, a1, c0, c1, e0, e1 = X0[i], X1[i], Z0[i], Z1[i], Y0[i], Y1[i]
        for j = 1, n do
          if j ~= i and (j > i or not isB[j]) then
            if p0 < sx1[j] and sx0[j] < p1 and q0 < sy1[j] and sy0[j] < q1 then
              local v, b0, b1 = 0, X0[j], X1[j]
              if a1 <= b0 + 0.02 then v = cx >= b0 and 1 or cx <= a1 and -1 or 0
              elseif b1 <= a0 + 0.02 then v = cx >= a0 and -1 or cx <= b1 and 1 or 0
              else
                b0, b1 = Z0[j], Z1[j]
                if c1 <= b0 + 0.02 then v = cz >= b0 and 1 or cz <= c1 and -1 or 0
                elseif b1 <= c0 + 0.02 then v = cz >= c0 and -1 or cz <= b1 and 1 or 0
                else
                  b0, b1 = Y0[j], Y1[j]
                  if e1 <= b0 + 0.02 then v = cy >= b0 and 1 or cy <= e1 and -1 or 0
                  elseif b1 <= e0 + 0.02 then v = cy >= e0 and -1 or cy <= b1 and 1 or 0
                  else v = ordZ[i] > ordZ[j] and 1 or -1 end
                end
              end
              if v > 0 then
                ne = ne + 1
                EA[ne], EB[ne] = i, j
              elseif v < 0 then
                ne = ne + 1
                EA[ne], EB[ne] = j, i
              end
            end
          end
        end
      end
    end
    -- depth order first (insertion sort, far to near)
    for o = 1, n do
      local z, j = ordZ[o], o - 1
      while j > 0 and ordZ[DO[j]] < z do
        DO[j + 1] = DO[j]
        j = j - 1
      end
      DO[j + 1] = o
    end
    if ne == 0 then
      for k = 1, n do ordP[k] = DO[k] end
      return
    end
    -- successor lists (compressed), in-degrees
    for o = 1, n do cnt[o], indeg[o], done[o] = 0, 0, false end
    for e = 1, ne do
      local a, b = EA[e], EB[e]
      cnt[a], indeg[b] = cnt[a] + 1, indeg[b] + 1
    end
    local q = 1
    for o = 1, n do
      st[o] = q
      q = q + cnt[o]
      cnt[o] = st[o]
    end
    for e = 1, ne do
      local a = EA[e]
      SU[cnt[a]] = EB[e]
      cnt[a] = cnt[a] + 1
    end
    -- Kahn: always the farthest object whose rules allow it
    local first = 1
    for k = 1, n do
      while done[DO[first]] do first = first + 1 end
      local p = first
      while p <= n and (done[DO[p]] or indeg[DO[p]] > 0) do p = p + 1 end
      -- p > n: a cycle (rare), broken at the farthest object left
      local best = DO[p > n and first or p]
      done[best] = true
      ordP[k] = best
      for e = st[best], cnt[best] - 1 do
        local v = SU[e]
        indeg[v] = indeg[v] - 1
      end
    end
  end
--#endif

  collectObjects = function(maxZ)
    nOrd = 0
    local n1 = NG + NP
    local n2 = n1 + BX.n
    local boxes = false
    for n = 1, n2 + (gmode == 1 and AI.n or 0) do
      local id, X, Y, Z, rad = n, 0, 0, 0, 4
      if n <= NG then
        X, Y, Z = gx[n] - kpx, gy[n] - kpy, gz[n] - kpz
        local k = gk[n]
        if GSH[k] == 3 then rad = 9 elseif k == 2 or k == 3 then rad = 7 end
      elseif n <= n1 then
        local i = n - NG
        if qk[i] == 1 then
          X, Y, Z = qx[i] - kpx, qh[i] * 0.4 - kpy, qz[i] - kpz
          rad = qh[i]
        else
          Z = -1e9
        end
        id = -i
      elseif n <= n2 then
        local b = n - n1
        local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
        X, Y, Z = (x0 + x1) * 0.5 - kpx, (y0 + y1) * 0.5 - kpy, (z0 + z1) * 0.5 - kpz
        rad = (x1 - x0 + y1 - y0 + z1 - z0) * 0.5
        id = 1000 + b
      else
        local a = n - n2
        X, Y, Z = AI.x[a] - kpx, AI.y[a] - kpy, AI.z[a] - kpz
        rad = 1
        id = 2000 + a
      end
      local z = X * kfx + Y * kfy + Z * kfz
      if z > -rad and z < maxZ then
        local x = X * krx + Y * kry + Z * krz
        if (x < 0 and -x or x) < z * tanH + rad or z < 4 then
          local o = nOrd + 1
          nOrd = o
          ordZ[o], ordI[o] = z, id
--#if COLOR
          -- screen rectangle (in pixels from the center) for the draw-order rules, made
          -- conservative; the whole screen when the object reaches the camera.
          local y = X * kux + Y * kuy + Z * kuz
          local isBox = id >= 1000 and id < 2000
          OB.b[o] = isBox
          sx0[o], sx1[o], sy0[o], sy1[o] = -1e6, 1e6, -1e6, 1e6
          if isBox then
            -- a box: its extent across, up and along the view, then the nearest and farthest
            -- depth for the outer edges (a wall seen edge-on is a narrow strip, not a circle)
            local b = id - 1000
            local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
            OB.x0[o], OB.x1[o], OB.y0[o], OB.y1[o], OB.z0[o], OB.z1[o] = x0, x1, y0, y1, z0, z1
            boxes = true
            local hx, hy, hz = (x1 - x0) * 0.5, (y1 - y0) * 0.5, (z1 - z0) * 0.5
            local a, c, e = krx * hx, kry * hy, krz * hz
            local ex = (a < 0 and -a or a) + (c < 0 and -c or c) + (e < 0 and -e or e)
            a, c, e = kux * hx, kuy * hy, kuz * hz
            local ey = (a < 0 and -a or a) + (c < 0 and -c or c) + (e < 0 and -e or e)
            a, c, e = kfx * hx, kfy * hy, kfz * hz
            local ez = (a < 0 and -a or a) + (c < 0 and -c or c) + (e < 0 and -e or e)
            if z - ez > NEAR then
              local f0, f1 = F / (z - ez), F / (z + ez)
              a, c = x - ex, x + ex
              sx0[o], sx1[o] = a * (a < 0 and f0 or f1), c * (c > 0 and f0 or f1)
              a, c = y - ey, y + ey
              sy0[o], sy1[o] = a * (a < 0 and f0 or f1), c * (c > 0 and f0 or f1)
            end
          else
            -- other objects: around their bounding sphere, at its nearest depth and stretched
            -- towards the edges (perspective grows off-axis objects by 1/cos^2 of their angle)
            if z > rad * 2 then
              local s = F / z
              local r = rad * F / (z - rad) * (1 + (x * x + y * y) / (z * z))
              x, y = x * s, y * s
              sx0[o], sx1[o], sy0[o], sy1[o] = x - r, x + r, y - r, y + r
            end
            if id > 0 and id < 1000 then
              OB.x0[o], OB.x1[o], OB.y0[o], OB.y1[o], OB.z0[o], OB.z1[o] = GB.x0[id], GB.x1[id], GB.y0[id], GB.y1[id], GB.z0[id], GB.z1[id]
            elseif id < 0 then
              local i = -id
              local r = qh[i] * 0.25
              OB.x0[o], OB.x1[o], OB.y0[o], OB.y1[o], OB.z0[o], OB.z1[o] = qx[i] - r, qx[i] + r, 0, qh[i], qz[i] - r, qz[i] + r
            else
              local a, r = id - 2000, 0.3
              OB.x0[o], OB.x1[o], OB.y0[o], OB.y1[o], OB.z0[o], OB.z1[o] = AI.x[a] - r, AI.x[a] + r, AI.y[a] - r, AI.y[a] + r, AI.z[a] - r, AI.z[a] + r
            end
          end
--#endif
        end
      end
    end
--#if COLOR
    if boxes then
      sortWithStructures(nOrd)
      return
    end
--#endif
    -- no structures in view: plain depth order (insertion sort)
    for o = 1, nOrd do
      local z, j = ordZ[o], o - 1
      while j > 0 and ordZ[ordP[j]] < z do
        ordP[j + 1] = ordP[j]
        j = j - 1
      end
      ordP[j + 1] = o
    end
  end
--#if COLOR
  if STICKTIME_TEST then STICKTIME_TEST.bounds = OB end
--#endif
end

local C = {}            -- colors (color radios) / grey levels (B&W)
local render3D, initGfx

--#if COLOR
-- ============================================================ COLOR GFX
;(function()
  local RGB = lcd.RGB
  local NF = 6
  local RCOS, RSIN = {}, {}                             -- ring segments (12 per turn)
  for j = 1, 12 do RCOS[j], RSIN[j] = cos(j * 0.5235988), sin(j * 0.5235988) end
  local XL, YL = W - 1, H - 1
  local MT, NMT = {}, 0
  local HAZE = { 214, 230, 242 }
  local HZN = floor(10 * SC + 0.5)        -- haze band height (px)
  local cSky, cGround, cGridN, cGridF, cMtn, cSnow, cPad, cPad2
  local hazeS, hazeG = {}, {}
  local fGate, fGateE, fNext, fNextE, fNextG, fTree, fTreeH, fTrunk, fPole, fFlag, fBoxE = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
  local fBox = {}
  local fxs, fys, gxs, gys, P3x, P3y, P3z = {}, {}, {}, {}, {}, {}, {}

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
    C.ai = { RGB(255, 72, 72), RGB(64, 150, 255), RGB(200, 96, 255) }
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
    ramp(fFlag, { 226, 40, 48 }, 0.7)
    ramp(fBoxE, { 52, 52, 58 }, 0.85)
    -- structures: concrete, red and blue containers; top, x and z faces shaded
    local KC, SH = { { 168, 164, 156 }, { 172, 60, 44 }, { 50, 92, 156 } }, { 1.2, 0.92, 0.72 }
    for k = 1, 3 do
      for s = 1, 3 do
        local c, m, t = KC[k], SH[s], {}
        ramp(t, { c[1] * m < 255 and c[1] * m or 255, c[2] * m < 255 and c[2] * m or 255, c[3] * m < 255 and c[3] * m or 255 }, 0.85)
        fBox[k * 3 + s - 3] = t
      end
    end
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

  -- lcd.drawLine on color radios drops the whole line when an end is beyond the
  -- right or bottom edge (x > LCD_W or y > LCD_H). The firmware clips the left
  -- and top edges itself, so only the right and bottom edges are clipped here.
  local function ln(x1, y1, x2, y2, col)
    if x1 > XL then
      if x2 > XL then return end
      y1, x1 = y1 + (y2 - y1) * (XL - x1) / (x2 - x1), XL
    elseif x2 > XL then
      y2, x2 = y2 + (y1 - y2) * (XL - x2) / (x1 - x2), XL
    end
    if y1 > YL then
      if y2 > YL then return end
      x1, y1 = x1 + (x2 - x1) * (YL - y1) / (y2 - y1), YL
    elseif y2 > YL then
      x2, y2 = x2 + (x1 - x2) * (YL - y2) / (y1 - y2), YL
    end
    drawLine(x1, y1, x2, y2, SOLID, col)
  end

  -- 3D line in camera space: near-plane clip + project
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
    local x1, y1, x2, y2 = CX + X1 * s1, CY - Y1 * s1, CX + X2 * s2, CY - Y2 * s2
    if x1 <= XL and x2 <= XL and y1 <= YL and y2 <= YL then drawLine(x1, y1, x2, y2, SOLID, col) else ln(x1, y1, x2, y2, col) end
  end

  -- polygon in fxs/fys: clip to the 3D view (Sutherland-Hodgman), fill as a triangle fan
  local function clip2(n, ax, ay, bx, by, useX, lim, sg)
    if n < 3 then return 0 end
    local m = 0
    local qx_, qy_ = ax[n], ay[n]
    local qd = sg * ((useX and qx_ or qy_) - lim)
    for i = 1, n do
      local cx, cy = ax[i], ay[i]
      local cd = sg * ((useX and cx or cy) - lim)
      if (cd <= 0) ~= (qd <= 0) then
        local t = qd / (qd - cd)
        m = m + 1
        bx[m], by[m] = qx_ + (cx - qx_) * t, qy_ + (cy - qy_) * t
      end
      if cd <= 0 then
        m = m + 1
        bx[m], by[m] = cx, cy
      end
      qx_, qy_, qd = cx, cy, cd
    end
    return m
  end

  local function fillPoly(n, col)
    n = clip2(n, fxs, fys, gxs, gys, true, VX - 1, -1)
    n = clip2(n, gxs, gys, fxs, fys, true, VX + VW, 1)
    n = clip2(n, fxs, fys, gxs, gys, false, VY - 1, -1)
    n = clip2(n, gxs, gys, fxs, fys, false, VY + VH, 1)
    for i = 2, n - 1 do fillTri(fxs[1], fys[1], fxs[i], fys[i], fxs[i + 1], fys[i + 1], col) end
  end

  -- filled triangle; far off-screen corners go through the clipper (the firmware
  -- walks every row between the top and bottom corner, even off-screen ones)
  local function tri(x1, y1, x2, y2, x3, y3, col)
    local lo, hi = VY - 2000, VY + VH + 2000
    if y1 > lo and y1 < hi and y2 > lo and y2 < hi and y3 > lo and y3 < hi then
      fillTri(x1, y1, x2, y2, x3, y3, col)
    else
      fxs[1], fys[1], fxs[2], fys[2], fxs[3], fys[3] = x1, y1, x2, y2, x3, y3
      fillPoly(3, col)
    end
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
      ln(hx0 + nx * k, hy0 + ny * k, hx1 + nx * k, hy1 + ny * k, hazeS[floor(k * 8 / n) + 1])
    end
    for k = 1, floor(n / 2) do
      ln(hx0 - nx * k, hy0 - ny * k, hx1 - nx * k, hy1 - ny * k, hazeG[floor((k - 1) * 8 / n) + 1])
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
      local AX_, AY_, AZ_ = ax * krx + y * kry + az * krz, ax * kux + y * kuy + az * kuz, ax * kfx + y * kfy + az * kfz
      local BX_, BY_, BZ_ = bx * krx + y * kry + bz * krz, bx * kux + y * kuy + bz * kuz, bx * kfx + y * kfy + bz * kfz
      local CX_, CY_, CZ_ = cx * krx + y * kry + cz * krz, cx * kux + y * kuy + cz * kuz, cx * kfx + y * kfy + cz * kfz
      local DX_, DY_, DZ_ = dx * krx + y * kry + dz * krz, dx * kux + y * kuy + dz * kuz, dx * kfx + y * kfy + dz * kfz
      line3(AX_, AY_, AZ_, BX_, BY_, BZ_, col)
      line3(BX_, BY_, BZ_, CX_, CY_, CZ_, col)
      line3(CX_, CY_, CZ_, DX_, DY_, DZ_, col)
      line3(DX_, DY_, DZ_, AX_, AY_, AZ_, col)
    end
  end

  -- one frame bar = quad between its outer edge a-b and inner edge c-d,
  -- filled with 1 px "ruled" lines (native Bresenham) or a clipped fan when big
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
    -- a bar only a few pixels thick reads as its outline: keep it the fill colour
    if n < 4 then e1, e2 = fill, fill end
    local safe = ax <= XL and bx <= XL and cx <= XL and dx <= XL and ay <= YL and by <= YL and cy <= YL and dy <= YL
    -- thick bars as triangles when they run more across than up (few rows to fill), or when
    -- very thick; upright bars keep their ruled lines (as many as the bar is thick)
    p, q = bx - ax, by - ay
    if n > 140 or (n >= 3 and (p < 0 and -p or p) >= (q < 0 and -q or q)) then
      if safe and ax >= VX and bx >= VX and cx >= VX and dx >= VX and ay >= VY and by >= VY and cy >= VY and dy >= VY then
        fillTri(ax, ay, bx, by, dx, dy, fill)
        fillTri(ax, ay, dx, dy, cx, cy, fill)
      else
        fxs[1], fys[1], fxs[2], fys[2], fxs[3], fys[3], fxs[4], fys[4] = ax, ay, bx, by, dx, dy, cx, cy
        fillPoly(4, fill)
      end
    elseif n >= 2 then
      n = floor(n)
      local sx1, sy1, sx2, sy2 = (cx - ax) / n, (cy - ay) / n, (dx - bx) / n, (dy - by) / n
      local x1, y1, x2, y2 = ax, ay, bx, by
      for _ = 2, n do
        x1, y1, x2, y2 = x1 + sx1, y1 + sy1, x2 + sx2, y2 + sy2
        if safe then drawLine(x1, y1, x2, y2, SOLID, fill) else ln(x1, y1, x2, y2, fill) end
      end
    end
    if safe then
      drawLine(ax, ay, bx, by, SOLID, e1)
      drawLine(cx, cy, dx, dy, SOLID, e2)
    else
      ln(ax, ay, bx, by, e1)
      ln(cx, cy, dx, dy, e2)
    end
  end

  -- flat face given as corner a plus edges u, v (camera space), filled and outlined
  local function face(ax, ay, az, ux_, uy_, uz_, vx_, vy_, vz_, col, ecol)
    -- all corners in front of the near plane (nearly always): project in locals
    local bz, cz, dz = az + uz_, az + uz_ + vz_, az + vz_
    if az >= NEAR and bz >= NEAR and cz >= NEAR and dz >= NEAR then
      local s = F / az
      local a1, b1 = CX + ax * s, CY - ay * s
      s = F / bz
      local a2, b2 = CX + (ax + ux_) * s, CY - (ay + uy_) * s
      s = F / cz
      local a3, b3 = CX + (ax + ux_ + vx_) * s, CY - (ay + uy_ + vy_) * s
      s = F / dz
      local a4, b4 = CX + (ax + vx_) * s, CY - (ay + vy_) * s
      local x0, x1, y0, y1 = a1, a1, b1, b1
      if a2 < x0 then x0 = a2 elseif a2 > x1 then x1 = a2 end
      if a3 < x0 then x0 = a3 elseif a3 > x1 then x1 = a3 end
      if a4 < x0 then x0 = a4 elseif a4 > x1 then x1 = a4 end
      if b2 < y0 then y0 = b2 elseif b2 > y1 then y1 = b2 end
      if b3 < y0 then y0 = b3 elseif b3 > y1 then y1 = b3 end
      if b4 < y0 then y0 = b4 elseif b4 > y1 then y1 = b4 end
      if x1 < VX or x0 > VX + VW or y1 < VY or y0 > VY + VH then return end
      -- two triangles, which the firmware fills row by row in C. Ruled lines (one call
      -- each, drawn pixel by pixel) cost more on walls and leave holes between slanted
      -- lines that show as dots.
      if x0 < VX or x1 > VX + VW or y0 < VY or y1 > VY + VH then
        fxs[1], fys[1], fxs[2], fys[2], fxs[3], fys[3], fxs[4], fys[4] = a1, b1, a2, b2, a3, b3, a4, b4
        fillPoly(4, col)
      else
        fillTri(a1, b1, a2, b2, a3, b3, col)
        fillTri(a1, b1, a3, b3, a4, b4, col)
      end
      -- outlines only where they show: each line call costs as much as a short line
      if x1 - x0 + y1 - y0 > 16 then
        ln(a1, b1, a2, b2, ecol)
        ln(a2, b2, a3, b3, ecol)
        ln(a3, b3, a4, b4, ecol)
        ln(a4, b4, a1, b1, ecol)
      end
      return
    end
    -- cut by the near plane: clip the polygon, then fill it
    P3x[1], P3y[1], P3z[1] = ax, ay, az
    P3x[2], P3y[2], P3z[2] = ax + ux_, ay + uy_, az + uz_
    P3x[3], P3y[3], P3z[3] = ax + ux_ + vx_, ay + uy_ + vy_, az + uz_ + vz_
    P3x[4], P3y[4], P3z[4] = ax + vx_, ay + vy_, az + vz_
    local m = 0
    local jx, jy, jz = P3x[4], P3y[4], P3z[4]
    for i = 1, 4 do
      local ix, iy, iz = P3x[i], P3y[i], P3z[i]
      if (iz >= NEAR) ~= (jz >= NEAR) then
        local t, s = (NEAR - jz) / (iz - jz), F / NEAR
        m = m + 1
        fxs[m], fys[m] = CX + (jx + (ix - jx) * t) * s, CY - (jy + (iy - jy) * t) * s
      end
      if iz >= NEAR then
        local s = F / iz
        m = m + 1
        fxs[m], fys[m] = CX + ix * s, CY - iy * s
      end
      jx, jy, jz = ix, iy, iz
    end
    if m < 3 then return end
    local x0, x1, y0, y1 = fxs[1], fxs[1], fys[1], fys[1]
    for i = 2, m do
      local x, y = fxs[i], fys[i]
      if x < x0 then x0 = x elseif x > x1 then x1 = x end
      if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    if x1 < VX or x0 > VX + VW or y1 < VY or y0 > VY + VH then return end
    fillPoly(m, col)
  end

  local function drawGate(i, z)
    local fi = floor((z - 18) * 0.045) + 1
    if fi < 1 then fi = 1 elseif fi > NF then fi = NF end
    local nxt = i == nextGate and gmode ~= 3
    local fill, e1, e2 = fGate[fi], fGateE[fi], fGateE[fi]
    if nxt then fill, e1, e2 = fNext[fi], fNextE[fi], fNextG[fi] end
    local k = gk[i]
    local sh = GSH[k]
    local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    local cx, cy, cz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local r1, r3 = grx[i], grz[i]
    local Rx, Ry, Rz = r1 * krx + r3 * krz, r1 * kux + r3 * kuz, r1 * kfx + r3 * kfz
    local a1, a2, a3 = gax[i], gay[i], gaz[i]
    local Ax, Ay, Az = a1 * krx + a2 * kry + a3 * krz, a1 * kux + a2 * kuy + a3 * kuz, a1 * kfx + a2 * kfy + a3 * kfz
    local iw, ih = GHW[k], GHH[k]
    if sh == 3 then
      -- flag: pole plus a cloth on the outer side; pass on the zone side
      local sd = k == 6 and 1 or -1
      local o = -iw * sd
      local bX, bY, bZ = cx + Rx * o, cy + Ry * o, cz + Rz * o
      local ex, ey, ez = kry * FLAGH, kuy * FLAGH, kfy * FLAGH
      local tX, tY, tZ = bX + ex, bY + ey, bZ + ez
      line3(bX, bY, bZ, tX, tY, tZ, fPole[fi])
      local w = -0.9 * sd
      local wX, wY, wZ = Rx * w, Ry * w, Rz * w
      local mX, mY, mZ = bX + ex * 0.45, bY + ey * 0.45, bZ + ez * 0.45
      local p3x, p3y, p3z = tX + wX - ex * 0.06, tY + wY - ey * 0.06, tZ + wZ - ez * 0.06
      local p4x, p4y, p4z = mX + wX + ex * 0.08, mY + wY + ey * 0.08, mZ + wZ + ez * 0.08
      if tZ > 1 and mZ > 1 and p3z > 1 and p4z > 1 then
        local s1, s2, s3, s4 = F / tZ, F / mZ, F / p3z, F / p4z
        local col = nxt and fNext[fi] or fFlag[fi]
        local X1, Y1, X2, Y2 = CX + tX * s1, CY - tY * s1, CX + mX * s2, CY - mY * s2
        local X3, Y3, X4, Y4 = CX + p3x * s3, CY - p3y * s3, CX + p4x * s4, CY - p4y * s4
        tri(X1, Y1, X2, Y2, X4, Y4, col)
        tri(X1, Y1, X4, Y4, X3, Y3, col)
      end
      return
    elseif sh == 4 then
      -- gap in a structure: only the next one is marked, with a thin frame
      if nxt then
        local wx, wy, wz, hx, hy, hz = Rx * iw, Ry * iw, Rz * iw, Ax * ih, Ay * ih, Az * ih
        line3(cx - wx + hx, cy - wy + hy, cz - wz + hz, cx + wx + hx, cy + wy + hy, cz + wz + hz, fill)
        line3(cx + wx + hx, cy + wy + hy, cz + wz + hz, cx + wx - hx, cy + wy - hy, cz + wz - hz, fill)
        line3(cx + wx - hx, cy + wy - hy, cz + wz - hz, cx - wx - hx, cy - wy - hy, cz - wz - hz, fill)
        line3(cx - wx - hx, cy - wy - hy, cz - wz - hz, cx - wx + hx, cy - wy + hy, cz - wz + hz, fill)
      end
      return
    elseif sh == 2 then
      -- hoop (on a stand) or arch: a ring of bar segments
      local ro = iw + GT
      local ns, st = k == 4 and 12 or 6, 1
      if z > 35 then ns, st = ns / 2, 2 end
      if k == 4 then
        local h = gy[i] - ro
        local X, Y, Z = cx - Ax * ro, cy - Ay * ro, cz - Az * ro
        line3(X, Y, Z, X - kry * h, Y - kuy * h, Z - kfy * h, fPole[fi])
      end
      if z > 70 then
        local rm = iw + GT * 0.5
        local oX, oY, oZ = cx + Rx * rm, cy + Ry * rm, cz + Rz * rm
        for j = st, ns * st, st do
          local c_, s_ = RCOS[j], RSIN[j]
          local X, Y, Z = cx + (Rx * c_ + Ax * s_) * rm, cy + (Ry * c_ + Ay * s_) * rm, cz + (Rz * c_ + Az * s_) * rm
          line3(oX, oY, oZ, X, Y, Z, fill)
          oX, oY, oZ = X, Y, Z
        end
        return
      end
      local oX, oY, oZ, iX, iY, iZ = cx + Rx * ro, cy + Ry * ro, cz + Rz * ro, cx + Rx * iw, cy + Ry * iw, cz + Rz * iw
      for j = st, ns * st, st do
        local c_, s_ = RCOS[j], RSIN[j]
        local wx, wy, wz = Rx * c_ + Ax * s_, Ry * c_ + Ay * s_, Rz * c_ + Az * s_
        local oX2, oY2, oZ2 = cx + wx * ro, cy + wy * ro, cz + wz * ro
        local iX2, iY2, iZ2 = cx + wx * iw, cy + wy * iw, cz + wz * iw
        bar(oX, oY, oZ, oX2, oY2, oZ2, iX, iY, iZ, iX2, iY2, iZ2, fill, e1, e2)
        oX, oY, oZ, iX, iY, iZ = oX2, oY2, oZ2, iX2, iY2, iZ2
      end
      return
    end
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
    local safe = x0 < XL - 4 and cx < XL - 4 and y0 < YL - 4 and cy < YL - 4
    for k = -tw, tw, 2 do
      local o = k * 0.5
      if safe then drawLine(x0 + ux_ * o, y0 + uy_ * o, cx + ux_ * o, cy + uy_ * o, SOLID, tc)
      else ln(x0 + ux_ * o, y0 + uy_ * o, cx + ux_ * o, cy + uy_ * o, tc) end
    end
    tri(x1, y1, cx + nx, cy + ny, cx - nx, cy - ny, fTree[fi])
    -- lit half only on near trees, where it reads as a cone
    if l > 28 and z < 55 then tri(x1, y1, cx, cy, cx - nx, cy - ny, fTreeH[fi]) end
  end

  local function drawBox(b, z)
    local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
    local fi = floor((z - 18) * 0.045) + 1
    if fi < 1 then fi = 1 elseif fi > NF then fi = NF end
    local k3, ec = BX.k[b] * 3 - 3, fBoxE[fi]
    local dx, dy, dz = x0 - kpx, y0 - kpy, z0 - kpz
    local ox, oy, oz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
    local Xx, Xy, Xz = krx * sx, kux * sx, kfx * sx      -- box edges in camera space
    local Yx, Yy, Yz = kry * sy, kuy * sy, kfy * sy
    local Zx, Zy, Zz = krz * sz, kuz * sz, kfz * sz
    if kpx < x0 then face(ox, oy, oz, Zx, Zy, Zz, Yx, Yy, Yz, fBox[k3 + 2][fi], ec)
    elseif kpx > x1 then face(ox + Xx, oy + Xy, oz + Xz, Zx, Zy, Zz, Yx, Yy, Yz, fBox[k3 + 2][fi], ec) end
    if kpz < z0 then face(ox, oy, oz, Xx, Xy, Xz, Yx, Yy, Yz, fBox[k3 + 3][fi], ec)
    elseif kpz > z1 then face(ox + Zx, oy + Zy, oz + Zz, Xx, Xy, Xz, Yx, Yy, Yz, fBox[k3 + 3][fi], ec) end
    if kpy > y1 then face(ox + Yx, oy + Yy, oz + Yz, Xx, Xy, Xz, Zx, Zy, Zz, fBox[k3 + 1][fi], ec)
    elseif kpy < y0 then face(ox, oy, oz, Xx, Xy, Xz, Zx, Zy, Zz, fBox[k3 + 3][fi], ec) end
  end

  -- AI pilot: a small quad with a colored tag above it (visible from afar)
  local function drawAI(a, z)
    if z < 1 then return end
    local dx, dy, dz = AI.x[a] - kpx, AI.y[a] - kpy, AI.z[a] - kpz
    local s = F / z
    local sx, sy = CX + (dx * krx + dy * kry + dz * krz) * s, CY - (dx * kux + dy * kuy + dz * kuz) * s
    local col, r = C.ai[a], 0.24 * s
    if r > 60 then r = 60 end
    if r >= 2 then
      local q = r * 0.4
      ln(sx - r, sy - q, sx + r, sy + q, C.black)
      ln(sx - r, sy + q, sx + r, sy - q, C.black)
      fillRect(sx - r * 0.4, sy - r * 0.18, r * 0.8 + 1, r * 0.36 + 1, col)
    else
      fillRect(sx - 1, sy - 1, 3, 2, col)
    end
    local m = 3 * SC + 2
    local ty = sy - r - m
    tri(sx, ty, sx - m, ty - m * 1.4, sx + m, ty - m * 1.4, col)
  end

  render3D = function()
    fillRect(VX, VY, VW, VH, cSky)
    drawMountains()
    drawGround()
    drawGrid()
    drawPad()
    collectObjects(165)
    for j = 1, nOrd do
      local o = ordP[j]
      local id, z = ordI[o], ordZ[o]
      if id < 0 then drawTree(-id, z)
      elseif id < 1000 then drawGate(id, z)
      elseif id < 2000 then drawBox(id - 1000, z)
      else drawAI(id - 2000, z) end
    end
  end
end)()
--#endif

--#if BW
-- =============================================================== B&W GFX
local line2
;(function()
  local GRAYS = type(GREY) == "function"
  local GRD, GRD2 = 0, 0
  local RCOS, RSIN = {}, {}                             -- ring segments (12 per turn)
  for j = 1, 12 do RCOS[j], RSIN[j] = cos(j * 0.5235988), sin(j * 0.5235988) end

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

  -- parallelogram a, a+u, a+u+v, a+v (camera space)
  local function quad3(ax, ay, az, ux_, uy_, uz_, vx_, vy_, vz_, pat)
    local bx, by, bz = ax + ux_, ay + uy_, az + uz_
    local cx, cy, cz = bx + vx_, by + vy_, bz + vz_
    local dx, dy, dz = ax + vx_, ay + vy_, az + vz_
    line3(ax, ay, az, bx, by, bz, pat, BLK)
    line3(bx, by, bz, cx, cy, cz, pat, BLK)
    line3(cx, cy, cz, dx, dy, dz, pat, BLK)
    line3(dx, dy, dz, ax, ay, az, pat, BLK)
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
    local sh = GSH[k]
    local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    local cx, cy, cz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local r1, r3 = grx[i], grz[i]
    local Rx, Ry, Rz = r1 * krx + r3 * krz, r1 * kux + r3 * kuz, r1 * kfx + r3 * kfz
    local a1, a2, a3 = gax[i], gay[i], gaz[i]
    local Ax, Ay, Az = a1 * krx + a2 * kry + a3 * krz, a1 * kux + a2 * kuy + a3 * kuz, a1 * kfx + a2 * kfy + a3 * kfz
    local iw, ih = GHW[k], GHH[k]
    if sh == 3 then
      local sd = k == 6 and 1 or -1
      local o = -iw * sd
      local bX, bY, bZ = cx + Rx * o, cy + Ry * o, cz + Rz * o
      local ex, ey, ez = kry * FLAGH, kuy * FLAGH, kfy * FLAGH
      local tX, tY, tZ = bX + ex, bY + ey, bZ + ez
      line3(bX, bY, bZ, tX, tY, tZ, SOLID, BLK)
      local w = -0.9 * sd
      local mX, mY, mZ = bX + ex * 0.5, bY + ey * 0.5, bZ + ez * 0.5
      local qX, qY, qZ = tX + Rx * w - ex * 0.15, tY + Ry * w - ey * 0.15, tZ + Rz * w - ez * 0.15
      line3(tX, tY, tZ, qX, qY, qZ, SOLID, BLK)
      line3(qX, qY, qZ, mX, mY, mZ, SOLID, BLK)
      if nxt then
        line3(tX - ex * 0.15, tY - ey * 0.15, tZ - ez * 0.15, qX, qY, qZ, SOLID, BLK)
      end
      return
    elseif sh == 4 then
      if nxt then quad3(cx - Rx * iw - Ax * ih, cy - Ry * iw - Ay * ih, cz - Rz * iw - Az * ih, Rx * iw * 2, Ry * iw * 2, Rz * iw * 2,
                        Ax * ih * 2, Ay * ih * 2, Az * ih * 2, SOLID) end
      return
    elseif sh == 2 then
      local ns = k == 4 and 12 or 6
      if k == 4 then
        local h = gy[i] - iw - GT
        local X, Y, Z = cx - Ax * (iw + GT), cy - Ay * (iw + GT), cz - Az * (iw + GT)
        line3(X, Y, Z, X - kry * h, Y - kuy * h, Z - kfy * h, SOLID, BLK)
      end
      local r = iw + GT
      while r > 0 do
        local oX, oY, oZ = cx + Rx * r, cy + Ry * r, cz + Rz * r
        for j = 1, ns do
          local c_, s_ = RCOS[j], RSIN[j]
          local X, Y, Z = cx + (Rx * c_ + Ax * s_) * r, cy + (Ry * c_ + Ay * s_) * r, cz + (Rz * c_ + Az * s_) * r
          line3(oX, oY, oZ, X, Y, Z, pat, BLK)
          oX, oY, oZ = X, Y, Z
        end
        r = (r > iw and (z < 30 or nxt)) and iw or 0
      end
      return
    end
    local s = 1
    while s <= 2 do
      local w, h = iw, ih
      if s == 1 then w, h = iw + GT, ih + GT end
      local wx, wy, wz, hx, hy, hz = Rx * w, Ry * w, Rz * w, Ax * h, Ay * h, Az * h
      quad3(cx - wx - hx, cy - wy - hy, cz - wz - hz, wx * 2, wy * 2, wz * 2, hx * 2, hy * 2, hz * 2, pat)
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

  -- structures: the edges of the faces turned to the camera
  local function drawBox(b, z)
    local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
    local dx, dy, dz = x0 - kpx, y0 - kpy, z0 - kpz
    local ox, oy, oz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
    local Xx, Xy, Xz = krx * sx, kux * sx, kfx * sx
    local Yx, Yy, Yz = kry * sy, kuy * sy, kfy * sy
    local Zx, Zy, Zz = krz * sz, kuz * sz, kfz * sz
    local pat = z < 60 and SOLID or DOTTED
    if kpx < x0 then quad3(ox, oy, oz, Zx, Zy, Zz, Yx, Yy, Yz, pat)
    elseif kpx > x1 then quad3(ox + Xx, oy + Xy, oz + Xz, Zx, Zy, Zz, Yx, Yy, Yz, pat) end
    if kpz < z0 then quad3(ox, oy, oz, Xx, Xy, Xz, Yx, Yy, Yz, pat)
    elseif kpz > z1 then quad3(ox + Zx, oy + Zy, oz + Zz, Xx, Xy, Xz, Yx, Yy, Yz, pat) end
    if kpy > y1 then quad3(ox + Yx, oy + Yy, oz + Yz, Xx, Xy, Xz, Zx, Zy, Zz, pat)
    elseif kpy < y0 then quad3(ox, oy, oz, Xx, Xy, Xz, Zx, Zy, Zz, pat) end
  end

  local function drawAI(a, z)
    if z < 1 then return end
    local dx, dy, dz = AI.x[a] - kpx, AI.y[a] - kpy, AI.z[a] - kpz
    local s = F / z
    local sx, sy = floor(CX + (dx * krx + dy * kry + dz * krz) * s), floor(CY - (dx * kux + dy * kuy + dz * kuz) * s)
    if sx >= U and sx <= XM - 2 * U and sy >= 4 * U and sy <= YM - 2 * U then
      fillRect(sx - U, sy, 3 * U, 2 * U, BLK)
      drawLine(sx, sy - 3 * U, sx, sy - 2 * U, SOLID, BLK)
    end
  end

  render3D = function()
    lcd.clear()
    drawGround()
    drawGrid()
    collectObjects(90)
    for j = 1, nOrd do
      local o = ordP[j]
      local id, z = ordI[o], ordZ[o]
      if id < 0 then drawTree(-id, z)
      elseif id < 1000 then drawGate(id, z)
      elseif id < 2000 then drawBox(id - 1000, z)
      else drawAI(id - 2000, z) end
    end
  end
end)()
--#endif

-- ---------------------------------------------------------- game flow
local function startRace(m)
  gmode = m
  lap, nextGate, lastGate, lapStart = 0, 1, 0, nil
  R.n, R.total, R.newLap, R.newRace, R.newBest, R.crashes, R.msg, R.cd = 0, 0, false, false, false, 0, nil, -1
  R.pk, R.pos, R.sc, R.ch, R.chn, R.rn, R.rt, R.ax, R.bx, R.smp = 0, 1, 0, 0, 0, 0, 30, nil, nil, gt
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  AI.start()
  tricks(-1)
  if m == 3 then state, R.ready = READY, gt else state, tState = COUNT, gt end
end

local function selectTrack(t)
  S.track = t
  buildTrack(t)
  AI.n = 0
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
end

local function update(dt)
  if state == COUNT then
    local n = floor((gt - tState) / 100)
    if n ~= R.cd then
      R.cd = n
      if n < 3 then beep(1000, 120) end
    end
    if n >= 3 then
      state, tStart = FLY, gt
      beep(2000, 400)
      showMsg("GO!", true)
    end
  elseif state == FLY or state == DONE then
    physics(dt)
    if gmode == 3 and state == FLY then
      tricks(dt)
      -- freestyle respawn point: where the quad was 1-2 s before a crash
      if gt - R.smp >= 100 then
        R.smp = gt
        R.ax, R.ay, R.az, R.ahx, R.ahz = R.bx, R.by, R.bz, R.bhx, R.bhz
        R.bx, R.by, R.bz, R.bhx, R.bhz = px, py, pz, fx, fz
      end
    end
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
  if gmode == 1 and AI.n > 0 and state ~= COUNT and dt > 0 then
    AI.update(dt)
    if state ~= DONE then R.pos = AI.place() end
  end
  motorSound((state == FLY or state == DONE) and dt > 0)
  if gmode == 4 and (state == FLY or state == CRASHED or state == READY) then
    R.rt = R.rt - dt
    if R.rt <= 0 then
      R.rt = 0
      local t = S.track
      if R.rn > BEST.g[t] then BEST.g[t], R.newBest = R.rn, true end
      saveData()
      state, tState = DONE, gt
      beep(900, 300)
    end
  end
end

-- menus
local focus, scroll, editing = 1, 0, false
local MAIN_ITEMS = { "Race", "Practice", "Freestyle", "Gate Rush", "Track", "Settings", "Exit" }
local PAUSE_ITEMS = { "Resume", "Restart", "Settings", "Main menu" }

local optStep, optText
do
local function optIndex(o)
  local v = S[o[2]]
  for j = 1, #o[3] do
    if o[3][j] == v then return j end
  end
  return 1
end

local stepT, stepN, stepO = 0, 0, nil
optStep = function(o, d)
  local key = o[2]
  if RKEYS[key] and S.rates < 4 then
    -- editing a rate switches to custom rates, starting from the preset in use
    local r = RATES[S.rates]
    for k, j in pairs(RKEYS) do S[k] = r[j] end
    S.rates = 4
  end
  local vals = o[3]
  if vals then
    local j = optIndex(o) + d
    if j < 1 then j = #vals elseif j > #vals then j = 1 end
    S[key] = vals[j]
  else
    -- fine steps, five times bigger after eight quick ones in a row (held key, fast wheel)
    local t = getTime()
    stepN = (o == stepO and t - stepT < 20) and stepN + 1 or 0
    stepT, stepO = t, o
    local v = S[key] + d * o[8] * (stepN >= 8 and 5 or 1)
    if v < o[6] then v = o[6] elseif v > o[7] then v = o[7] end
    S[key] = v
  end
  applySettings()
end

optText = function(o)
  if o[4] then return o[4][optIndex(o)] end
  local key = o[2]
  local v, j = S[key], RKEYS[key]
  if j and S.rates < 4 then v = RATES[S.rates][j] end
  if key == "re" or key == "ye" then return fmt("%.2f", v / 100) end
  return v .. (o[5] or "")
end
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

--#if COLOR
-- ============================================================= COLOR UI
;(function()
  local hS, hM, hL, hX, MG = 14, 20, 28, 40, 6
  local TOUCH = EV.TAP ~= nil
  local hitN, hitX, hitY, hitW, hitH, hitI = 0, {}, {}, {}, {}, {}
  local PB = { 0, 0, 0 }   -- pause button x, y, size
  local GMO = { 1.9, 1.9, 0.6, 2.1, 1.6, 2.2, 2.2, 2.4 }  -- next-gate marker height above the aim point

  local function bestInfo()
    local t = S.track
    if focus == 3 then return "Best combo " .. BEST.f[t] end
    if focus == 4 then return "Best Gate Rush " .. BEST.g[t] end
    return "Lap " .. (BEST.l[t] > 0 and timeStr(BEST.l[t]) or "--") .. "  Race " .. (BEST.r[t] > 0 and timeStr(BEST.r[t]) or "--")
  end

  local function place(p)
    return p .. (p == 1 and "st" or p == 2 and "nd" or p == 3 and "rd" or "th")
  end

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
    local dx, dy, dz = AX[i] - kpx, AY[i] - kpy, AZ[i] - kpz
    local X, Y, Z = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local rxm, rym = VW / 2 - 16 * SC, VH / 2 - 16 * SC
    if Z > 1 then
      local sx, sy = X * F / Z, Y * F / Z
      if sx > -rxm and sx < rxm and sy > -rym and sy < rym then
        local top = GMO[gk[i]] * F / Z
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
    for b = 1, BX.n do
      fillRect(ox + BX.x0[b] * s, oz - BX.z1[b] * s, (BX.x1[b] - BX.x0[b]) * s + 1, (BX.z1[b] - BX.z0[b]) * s + 1, C.dim, 7)
    end
    for i = 1, NG do
      local j = i % NG + 1
      drawLine(ox + AX[i] * s, oz - AZ[i] * s, ox + AX[j] * s, oz - AZ[j] * s, SOLID, C.dim)
    end
    local e = 3 * SC + 1
    for i = 1, NG do
      local c = (i == nextGate and gmode ~= 3) and C.accent or C.white
      local k = gk[i]
      if GSH[k] == 3 then
        local o = -GHW[k] * (k == 6 and 1 or -1)
        fillRect(ox + (gx[i] + grx[i] * o) * s - 1, oz - (gz[i] + grz[i] * o) * s - 1, 3, 3, c)
      else
        local gxp, gzp = ox + gx[i] * s, oz - gz[i] * s
        drawLine(gxp - grx[i] * e, gzp + grz[i] * e, gxp + grx[i] * e, gzp - grz[i] * e, SOLID, c)
        drawLine(gxp - grx[i] * e, gzp + grz[i] * e + 1, gxp + grx[i] * e, gzp - grz[i] * e + 1, SOLID, c)
      end
    end
    if gmode == 1 then
      for a = 1, AI.n do fillRect(ox + AI.x[a] * s - 1, oz - AI.z[a] * s - 1, 3, 3, C.ai[a]) end
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

  local function lapText(l)
    local s = "LAP " .. l
    if gmode == 1 then s = s .. "/" .. S.laps end
    return s
  end

  local function comboText()
    local m = 1 + (R.chn - 1) * 0.5
    if m > 4 then m = 4 end
    return fmt("COMBO x%.1f  %d", m, floor(R.ch * m))
  end

  -- mode readout: title, big number, extra line, best (top-right)
  local function modeInfo()
    local t = S.track
    if gmode == 3 then
      return "SCORE", tostring(R.sc), R.chn > 0 and comboText() or nil, "BEST COMBO " .. BEST.f[t], C.white
    elseif gmode == 4 then
      return "GATES " .. R.rn, fmt("%.1f", R.rt), nil, "BEST " .. BEST.g[t], R.rt < 5 and C.bad or C.white
    end
    local b = BEST.l[t]
    local l, lt = lapClock()
    return lapText(l), timeStr(lt), (gmode == 1 and AI.n > 0) and ("P" .. R.pos .. "/" .. (AI.n + 1)) or nil,
           "BEST " .. (b > 0 and timeStr(b) or "--"), C.white
  end

  local function drawHUD()
    local m = MG
    local c = 5 * SC + 1
    drawLine(CX - c * 2, CY, CX - c, CY, SOLID, C.white)
    drawLine(CX + c, CY, CX + c * 2, CY, SOLID, C.white)
    drawLine(CX, CY - c, CX, CY - c * 0.5, SOLID, C.white)
    if state ~= COUNT then nextGateMarker() end
    if PORTRAIT then return end
    local t1, big, extra, best, bc = modeInfo()
    txt(m, m, t1, SMLSIZE + C.white)
    txt(m, m + hS, big, DBLSIZE + bc)
    if extra then txt(m, m + hS + hX, extra, (gmode == 1 and MIDSIZE or SMLSIZE) + C.accent2) end
    local rxp = W - m
    if S.map == 1 then rxp = W - m * 2 - floor(H * 0.3) end
    txt(rxp, m, best, SMLSIZE + RIGHT + C.accent2)
    if gmode == 1 and state ~= COUNT then
      local _, _, rt = lapClock()
      txt(rxp, m + hS, "RACE " .. timeStr(rt), SMLSIZE + RIGHT + C.white)
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
    if S.fps == 1 then txt(W / 2, VY + VH - m - hS - (S.sticks == 1 and floor(VH * 0.16) + 2 or 0), R.fps .. " fps" .. R.fpsX, SMLSIZE + CENTER + C.dim) end
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
    local t1, big, extra, best, bc = modeInfo()
    drawText(m, y, t1, C.white)
    drawText(m, y + hM, big, DBLSIZE + bc)
    drawText(m, y + hM + hX, best, SMLSIZE + C.accent2)
    if extra then drawText(m, y + hM + hX + hS, extra, SMLSIZE + C.white)
    elseif gmode == 1 and state ~= COUNT then
      local _, _, rt = lapClock()
      drawText(m, y + hM + hX + hS, "RACE " .. timeStr(rt), SMLSIZE + C.white)
    end
    local yb = y + hM + hX + hS * 2 + m
    drawText(m, yb, floor(speed * 3.6) .. " km/h", MIDSIZE + C.white)
    drawText(m, yb + hL, "ALT " .. floor(py) .. "m" .. (P.angle and "  ANGLE" or ""), SMLSIZE + C.dim)
    local tw = x2 - m * 3
    local ty = yb + hL + hS + 4
    fillRect(m, ty, tw, 8, C.panel)
    fillRect(m, ty, floor(tw * sT), 8, sT > 0.7 and C.bad or C.accent)
    if TOUCH then pauseButton(m, H - m - 38, 38) end
    if S.fps == 1 then drawText(m + 48, H - m - hS, R.fps .. " fps" .. R.fpsX, SMLSIZE + C.dim) end
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
    if i == 1 then return "Race (" .. S.laps .. " laps" .. (S.ai > 0 and ", " .. S.ai .. " AI" or "") .. ")" end
    return MAIN_ITEMS[i]
  end

  local function mainValue(i)
    if i == 5 then return TRACKS[S.track][1] end
    return nil
  end

  local function drawMenu()
    local x, w = menuBox()
    local y = MG
    txt(x + MG, y, "StickTime", DBLSIZE + C.white)
    local tw = lcd.sizeText and lcd.sizeText("StickTime ", DBLSIZE) or floor(150 * SC)
    txt(x + MG + tw, y + hX - hS - 4, "FPV simulator", SMLSIZE + C.accent2)
    local info = bestInfo()
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
    local rush = gmode == 4
    local n = rush and 0 or R.n
    if n > 5 then n = 5 end
    local extra = (not rush and AI.n > 0) and hM or 0
    local h = hL + hM * 2 + hS * n + MG * 7 + hM + 10 + extra
    local y = (PORTRAIT and VH or H) / 2 - h / 2
    if y < MG then y = MG end
    panel(x, y, w, h)
    local cy = y + MG
    local rec = rush and R.newBest or (not rush and R.newRace)
    drawText(x + w / 2, cy, rec and "NEW RECORD!" or (rush and "TIME UP" or "FINISHED"), MIDSIZE + CENTER + (rec and C.accent2 or C.white))
    cy = cy + hL + MG
    local function row(a, b, col)
      drawText(x + MG * 2, cy, a, C.dim)
      drawText(x + w - MG * 2, cy, b, RIGHT + col)
      cy = cy + hM
    end
    if rush then
      row("Gates", tostring(R.rn), C.white)
      row("Best", tostring(BEST.g[S.track]), R.newBest and C.accent2 or C.white)
    else
      if AI.n > 0 then row("Position", place(R.pos) .. " of " .. (AI.n + 1), R.pos == 1 and C.accent2 or C.white) end
      row("Total", timeStr(R.total), C.white)
      local b = 0
      for i = 1, R.n do
        if b == 0 or R.laps[i] < b then b = R.laps[i] end
      end
      row("Best lap", timeStr(b), R.newLap and C.accent2 or C.white)
      cy = cy + 4
      for i = 1, n do
        drawText(x + MG * 2, cy, "Lap " .. i, SMLSIZE + C.dim)
        drawText(x + w - MG * 2, cy, timeStr(R.laps[i]), SMLSIZE + RIGHT + (R.laps[i] == b and C.good or C.white))
        cy = cy + hS
      end
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
end)()
--#endif

--#if BW
-- ================================================================ B&W UI
;(function()
  initUI = function() end

  local function place(p)
    return p .. (p == 1 and "st" or p == 2 and "nd" or p == 3 and "rd" or "th")
  end

  local function drawHUD()
    if gmode <= 2 then
      local l, lt = lapClock()
      drawNumber(U, U, floor(lt / 10), PREC1 + SMLSIZE + LEFT)
      local s = l .. ""
      if gmode == 1 then s = s .. "/" .. S.laps end
      if gmode == 1 and AI.n > 0 then s = "P" .. R.pos .. " L" .. s end
      drawText(XM, U, s, SMLSIZE + RIGHT)
    elseif gmode == 3 then
      drawNumber(U, U, R.sc, SMLSIZE + LEFT)
      if R.chn > 0 then drawText(XM, U, "x" .. R.chn .. " " .. R.ch, SMLSIZE + RIGHT) end
    else
      drawNumber(U, U, floor(R.rt * 10), PREC1 + SMLSIZE + LEFT)
      drawText(XM, U, R.rn .. "", SMLSIZE + RIGHT)
    end
    if gmode ~= 3 then
      local i = nextGate
      local dx, dy, dz = AX[i] - kpx, AY[i] - kpy, AZ[i] - kpz
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
        local k = (CX - 6 * U) / ((ex < 0 and -ex or ex) + 0.0001)
        local k2 = (CY - 6 * U) / ((ey < 0 and -ey or ey) + 0.0001)
        if k2 < k then k = k2 end
        local tx, ty = CX + ex * k, CY + ey * k
        local a, b, c, d = ex * 5 * U, ey * 5 * U, ey * 3 * U, ex * 3 * U
        line2(tx, ty, tx - a - c, ty - b + d, SOLID, BLK)
        line2(tx, ty, tx - a + c, ty - b - d, SOLID, BLK)
      end
    end
    local th = floor(sT * 30 * U)
    if th > 0 then fillRect(0, YM - th, 2 * U, th, BLK) end
    drawLine(CX - 4 * U, CY, CX - 2 * U, CY, SOLID, BLK)
    drawLine(CX + 2 * U, CY, CX + 4 * U, CY, SOLID, BLK)
    if S.fps == 1 then drawNumber(XM, YM + 2 - 8 * U, R.fps, SMLSIZE + RIGHT) end
  end

  local function drawList(title, n, label, value, y, rh)
    if title then
      drawText(U, 0, title, SMLSIZE + INVERS)
      y = 9 * U
    end
    local rows = floor((H - y) / rh)
    if rows > n then rows = n end
    if focus - scroll > rows then scroll = focus - rows end
    if focus <= scroll then scroll = focus - 1 end
    for r = 1, rows do
      local i = scroll + r
      local ry = y + (r - 1) * rh
      local v = value and value(i)
      drawText(2 * U, ry + U, label(i), SMLSIZE + ((i == focus and not (editing and v)) and INVERS or 0))
      if v then drawText(XM - U, ry + U, v, SMLSIZE + RIGHT + ((i == focus and editing) and INVERS or 0)) end
    end
  end

  local function mainLabel(i)
    local t = TRACKS[S.track][1]
    if i == 1 then return "Race " .. S.laps .. " laps" end
    if i == 5 then return (focus == 5 and editing) and ("< " .. t .. " >") or ("Track: " .. t) end
    return MAIN_ITEMS[i]
  end

  -- the track's bests next to the modes: race, lap, combo, gates
  local function mainValue(i)
    local t = S.track
    local b = i == 1 and BEST.r[t] or i == 2 and BEST.l[t] or i == 3 and BEST.f[t] or i == 4 and BEST.g[t]
    if b then return b < 1 and "--" or i < 3 and timeStr(b) or floor(b) .. "" end
  end

  render = function()
    if state == MENU or (state == SETUP and prevState == MENU) then
      lcd.clear()
      if state == MENU then
        drawText(U, 0, "StickTime", MIDSIZE)
        drawList(nil, #MAIN_ITEMS, mainLabel, mainValue, 13 * U, 8 * U)
      else
        drawList("SETTINGS", #OPTS + 1, setLabel, setValue, 0, 9 * U)
      end
      return
    end
    fpvCamera()
    render3D()
    if state == SETUP then
      fillRect(0, 0, W, H, ERASE)
      drawList("SETTINGS", #OPTS + 1, setLabel, setValue, 0, 9 * U)
      return
    end
    drawHUD()
    if state == COUNT then
      drawText(CX, CY - 16 * U, tostring(3 - floor((gt - tState) / 100)), DBLSIZE + CENTER)
    elseif state == CRASHED then
      drawText(CX, CY - 8 * U, "CRASH", DBLSIZE + INVERS + CENTER)
    elseif state == READY then
      drawText(CX, CY - 14 * U, "READY", SMLSIZE + INVERS + CENTER)
    elseif state == PAUSED then
      fillRect(14 * U, 6 * U, W - 28 * U, H - 12 * U, ERASE)
      lcd.drawRectangle(14 * U, 6 * U, W - 28 * U, H - 12 * U, BLK)
      for i = 1, #PAUSE_ITEMS do
        drawText(22 * U, (10 + (i - 1) * 11) * U, PAUSE_ITEMS[i], i == focus and INVERS or 0)
      end
    elseif state == DONE then
      fillRect(8 * U, 4 * U, W - 16 * U, H - 8 * U, ERASE)
      lcd.drawRectangle(8 * U, 4 * U, W - 16 * U, H - 8 * U, BLK)
      local x = 12 * U
      if gmode == 4 then
        drawText(x, 7 * U, R.newBest and "NEW RECORD!" or "TIME UP", SMLSIZE + INVERS)
        drawText(x, 17 * U, "Gates " .. R.rn, SMLSIZE)
        drawText(x, 26 * U, "Best " .. BEST.g[S.track], SMLSIZE)
      else
        drawText(x, 7 * U, R.newRace and "NEW RECORD!" or "FINISHED", SMLSIZE + INVERS)
        drawText(x, 17 * U, "Total " .. timeStr(R.total), SMLSIZE)
        local b = 0
        for i = 1, R.n do
          if b == 0 or R.laps[i] < b then b = R.laps[i] end
        end
        drawText(x, 26 * U, "Best lap " .. timeStr(b), SMLSIZE)
        if AI.n > 0 then drawText(x, 35 * U, place(R.pos) .. " of " .. (AI.n + 1), SMLSIZE) end
      end
      drawText(x, H - 16 * U, "ENTER again  EXIT menu", SMLSIZE)
    end
    if R.msg and state == FLY then
      if gt - R.msgT < 200 then
        drawText(CX, 10 * U, R.msg, SMLSIZE + CENTER)
      else
        R.msg = nil
      end
    end
  end

  hitTest = function() return nil end
  pauseHit = function() return false end
end)()
--#endif

-- ------------------------------------------------------------ input
local handleEvent
;(function()
  local function listNav(event, n)
    if event == EV.NEXT or event == EV.NEXTR then
      focus = focus % n + 1
    elseif event == EV.PREV or event == EV.PREVR then
      focus = (focus - 2) % n + 1
    end
  end

  local function toMenu()
    state, focus, scroll, editing = MENU, 1, 0, false
    AI.n = 0
    placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  end

  local function stepTrack(d)
    local t = S.track + d
    if t < 1 then t = NT elseif t > NT then t = 1 end
    selectTrack(t)
    saveData()
  end

  local function mainSelect(i, frac)
    if i <= 4 then startRace(i)
    elseif i == 5 then stepTrack((frac and frac < 0.4) and -1 or 1)
    elseif i == 6 then prevState, state, focus, scroll, editing = MENU, SETUP, 1, 0, false
    elseif i == 7 then return 1
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
        -- INC / DEC only: on radios with +/- keys NEXT is the minus key
        if event == EV.INC or event == EV.INCR then stepTrack(1)
        elseif event == EV.DEC or event == EV.DECR then stepTrack(-1)
        elseif event == EV.ENTER or event == EV.EXIT then editing = false end
        return 0
      end
      listNav(event, #MAIN_ITEMS)
      if event == EV.ENTER then
        if focus == 5 then
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
        if event == EV.INC or event == EV.INCR then optStep(OPTS[focus], 1)
        elseif event == EV.DEC or event == EV.DECR then optStep(OPTS[focus], -1)
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
          state, focus, scroll = MENU, 6, 0
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
end)()

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
  local TEST = STICKTIME_TEST
  if TEST then
    TEST.get = function() return px, py, pz, vx, vy, vz, fx, fy, fz, ux, uy, uz, rx, ry, rz, state, lap, nextGate, NG, gt end
    TEST.gate = function(i) return gx[i], gy[i], gz[i], gnx[i], gny[i], gnz[i], gk[i], AX[i], AY[i], AZ[i] end
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
      -- first lap running for t ticks, and no "GO!" banner (for screenshots)
      lapStart, tStart, R.msgT = gt - t, gt - t, gt - 1000
      if lap < 1 then lap = 1 end
    end
    TEST.next = function(i) nextGate, lastGate = i, (i - 2) % NG + 1 end
    TEST.race = function() return lastGate, lapStart, R.n, R.laps, R.total, R.crashes, tStart end
    TEST.info = function() return NT, P.twr, gmode, R.pos, AI.n, R.sc, R.rn, R.rt, R.chn, BX.n, TRACKS[S.track][1] end
    TEST.ai = function(a) return AI.x[a], AI.y[a], AI.z[a], AI.k[a], AI.d[a], AI.v[a], AI.seg[a] end
    TEST.best = function(t) return BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t] end
    TEST.box = function(b) return BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b] end
    TEST.S = S
    TEST.order = function() return nOrd, ordP, ordI, TEST.bounds, kpx, kpy, kpz end
    TEST.cam = function() return krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz end
  end
end

local function run(event, touch)
  local now = getTime()
  local dtk = now - lastT
  lastT = now
  if dtk > 10 then dtk = 10 elseif dtk < 0 then dtk = 0 end
  -- frame interval in 10 ms ticks, smoothed: getTime() only ticks every 10 ms, so when the
  -- firmware runs the script faster than 20 fps the raw steps jitter (0, 1, 2, 3 ticks...)
  R.fi = R.fi + (dtk - R.fi) * 0.2
  local paused = state == PAUSED or state == SETUP
  if paused then dtk = 0 end
  gt = gt + dtk
  -- simulation time advances by the smoothed interval, kept within a tick of the clock
  local pt = R.pt + (paused and 0 or R.fi)
  if pt > gt + 1 then pt = gt + 1 elseif pt < gt - 1 then pt = gt - 1 end
  local dts = (pt - R.pt) * 0.01
  if dts < 0 then dts = 0 end
  R.pt = pt
  readSticks()
  if handleEvent(event or 0, touch) ~= 0 then return 1 end
  update(dts)
  render()
  R.fpsN = R.fpsN + 1
--#if COLOR
  -- the StickTime firmware (firmware/) reports how long run() and putting the frame on the
  -- screen took: shown next to the fps, averaged over the same second
  local ru, su = TOOL_RUN_US, TOOL_SHOW_US
  if ru and su then R.runS, R.showS = R.runS + ru, R.showS + su end
--#endif
  if now - R.fpsT >= 100 then
--#if COLOR
    if ru and su then
      local k = 0.001 / R.fpsN
      R.fpsX = fmt("  game %d ms  lcd %d ms", floor(R.runS * k + 0.5), floor(R.showS * k + 0.5))
      R.runS, R.showS = 0, 0
    end
--#endif
    R.fps, R.fpsN, R.fpsT = R.fpsN, 0, now
  end
  return 0
end

return { init = init, run = run }
