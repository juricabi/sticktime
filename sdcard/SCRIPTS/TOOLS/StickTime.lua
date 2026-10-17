local toolName = "TNS|StickTime|TNE"
--[[ ======================================================================
  StickTime v1.8.0  -  a real 3D FPV quad simulator that runs on your radio
  Color version - every EdgeTX color radio (480x272, 480x320, 320x480, 320x240, 800x480)

  Install : copy this file to /SCRIPTS/TOOLS/ on the radio SD card and
            start it from SYS > TOOLS (or SD card browser > Execute).
  Fly     : your sticks fly the quad (acro or angle mode). The radio
            handles stick mode 1-4. EXIT = pause/back, ENTER = select,
            rotary / +- / up-down = move. Touch screens: tap.
  Modes   : Race against AI pilots, Practice, Freestyle (tricks and
            combos) and Gate Rush (beat the clock), on eight tracks and
            eight of your own (StickTimeTracks/c1.txt .. c8.txt).
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
local fillTri = lcd.drawFilledTriangle

local EV = {
  ENTER = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EXIT = EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK,
  NEXT = EVT_VIRTUAL_NEXT, PREV = EVT_VIRTUAL_PREV, INC = EVT_VIRTUAL_INC, DEC = EVT_VIRTUAL_DEC,
  NEXTR = EVT_VIRTUAL_NEXT_REPT, PREVR = EVT_VIRTUAL_PREV_REPT, INCR = EVT_VIRTUAL_INC_REPT, DECR = EVT_VIRTUAL_DEC_REPT,
  PGN = EVT_VIRTUAL_NEXT_PAGE, PGP = EVT_VIRTUAL_PREV_PAGE, TAP = EVT_TOUCH_TAP,
}

-- game states; game modes (gmode): 1 race, 2 practice, 3 freestyle, 4 gate rush
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8
local focus, scroll, editing = 1, 0, false     -- menus: focused row, list scroll, editing a value

-- ------------------------------------------------------------ settings
local S = { track = 1, quad = 1, twr = 0, mode = 1, rates = 2, rc = 100, rm = 600, re = 50, yc = 100, ym = 500, ye = 40,
            tilt = 25, fov = 110, laps = 3, ai = 2, skill = 2, ghost = 1, wind = 0, wash = 0, grip = 1, batt = 0, vib = 1,
            map = 1, sticks = 0, fps = 0 }
-- rows: label, key, then either a value list (+ names, suffix) or nil, nil, suffix, min, max, step
local OPTS = {
  { "Quad", "quad", { 1, 2, 3, 4, 5 }, { 'Racer 5"', 'Freestyle 5"', '3" toothpick', 'Whoop 65mm', 'Whoop 75mm' } },
  { "Power", "twr", { 0, 3, 4, 5, 6, 7, 8, 10, 12 }, { "Stock", "3:1", "4:1", "5:1", "6:1", "7:1", "8:1", "10:1", "12:1" } },
  { "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
  { "Rates", "rates", { 1, 2, 3, 4 }, { "Soft", "Normal", "Fast", "Custom" } },
  { "R/P center", "rc", nil, nil, "°/s", 10, 500, 10 },
  { "R/P max", "rm", nil, nil, "°/s", 100, 2000, 10 },
  { "R/P expo", "re", nil, nil, nil, 0, 100, 1 },
  { "Yaw center", "yc", nil, nil, "°/s", 10, 500, 10 },
  { "Yaw max", "ym", nil, nil, "°/s", 100, 2000, 10 },
  { "Yaw expo", "ye", nil, nil, nil, 0, 100, 1 },
  { "Camera tilt", "tilt", nil, nil, "°", 0, 60, 5 },
  { "Field of view", "fov", nil, nil, "°", 70, 130, 10 },
  { "Race laps", "laps", { 1, 2, 3, 5, 10 } },
  { "Opponents", "ai", { 0, 1, 2, 3 } },
  { "AI skill", "skill", { 1, 2, 3 }, { "Easy", "Medium", "Hard" } },
  { "Ghost", "ghost", { 0, 1 }, { "Off", "On" } },
  { "Wind", "wind", { 0, 1, 2 }, { "Off", "Light", "Strong" } },
  { "Prop wash", "wash", { 0, 1, 2 }, { "Off", "Stock", "Max" } },
  { "Grip", "grip", { 0, 1, 2 }, { "Low", "Medium", "High" } },
  { "Battery", "batt", { 0, 1, 3, 2 }, { "Off", "Real", "1.5x", "2x" } },   -- (3: 1.5x, added after 2x)
  { "Vibration", "vib", { 0, 1 }, { "Off", "On" } },
  { "Minimap", "map", { 0, 1 }, { "Off", "On" } },
  { "Stick view", "sticks", { 0, 1 }, { "Off", "On" } },
  { "Show FPS", "fps", { 0, 1 }, { "Off", "On" } },
}
-- Betaflight "actual" rate presets: roll/pitch center, max (deg/s), expo %, then yaw
local RATES = { { 70, 400, 35, 70, 350, 30 }, { 100, 600, 50, 100, 500, 40 }, { 150, 850, 45, 130, 700, 40 } }
local RKEYS = { rc = 1, rm = 2, re = 3, yc = 4, ym = 5, ye = 6 }
-- quad profiles (Racer 5", Freestyle 5", 3" toothpick, Whoop 65mm, Whoop 75mm), each fitted to a detailed model
-- of that class (blade-element props on rpm-governed motors, a Betaflight-style PID loop; see
-- docs/flight-model.md). twr stock thrust/weight; thrust curve: i0 idle, tn exponent, dz bottom dead
-- zone, tk the share of a steep top end (x^8); vp, vc, vk climbing: prop pitch speed (m/s), throttle
-- exponent and bend of the inflow loss; tl, vt translational lift gain and speed (m/s), tb its growth
-- with throttle, te, ta its fades near full stick and with axial inflow (m/s); ks, kf, ku side, front,
-- top drag per kg; er, vd extra drag at low speed and the speed it fades by (m/s); lr
-- frame lift / drag; gg, gl, gw ground effect gain, ray length and fade (m); tm thrust, tr roll/pitch,
-- ty yaw response time (s); pw/wl/wv prop wash Max: shake rms at full wash (deg), thrust loss, the sink
-- speed where the loss has faded out (m/s); wls/wvs/pws the same at the class's Stock setting; sq, cq,
-- ce, se, rf descending: the cushion peaks at cq (less by ce near full stick) at a sink of sq*tf^se m/s,
-- then stalls down to rf + rq*tf (at most 1: at idle the blades stall, with power they hold); pf the prop wash shake's frequency (Hz); tlo, thi the Power settings that
-- suit the class (thrust/weight of real quads of its kind; Stock is always there); kh rotor drag at
-- Grip High (1/s, times sqrt(Tm/5g + 0.02); Medium, the default, 0.4 of it; Low none, as in the reference);
-- am how fast the motors spin the quad up in a flip (rad/s^2 at hover throttle; the airmode mixer in physics()).
-- One string per class (parsed for the class in use only: tables of numbers cost radio memory):
local QK = { "twr", "i0", "tn", "dz", "vp", "vk", "tl", "vt", "te", "ks", "kf", "ku", "er", "vd", "lr", "gg", "gl", "gw", "tm", "tr", "ty", "pw", "wl", "wv", "sq", "cq", "wls", "wvs", "pws", "vc", "ta", "ce", "se", "rf", "pf", "tlo", "thi", "kh", "tk", "tb", "rq", "am" }
local QP = {
  -- twr i0 tn dz vp vk tl vt te ks kf ku er vd lr gg gl gw tm tr ty pw wl wv sq cq wls wvs pws vc ta ce se rf pf tlo thi kh tk tb rq am
  "7.67 .0315 1.43 .123 87.5 -.362 .517 7.88 .566 .0152 .00819 .0287 .357 15 .229 .24 .25 .113 .006 .009 .02 .347 .326 6.01 13.2 1.42 .119 3.8 .19 .61 65.3 .655 .496 .72 26 5 12 .363 .184 .874 .334 430",  -- Racer 5": 0.49 kg, 2500KV, 5045 tri-blade
  "6.88 .026 1.5 .075 75.6 -.278 .502 7.61 .712 .011 .00635 .0184 .357 15 .257 .26 .25 .113 .006 .008 .02 .347 .348 7 11.4 1.42 .132 4.56 .19 .539 453 .75 .317 .661 24 4 10 .263 .015 .367 .272 550",       -- Freestyle 5": HD, 0.66 kg, 2400KV, 5045
  "5.35 .0221 1.76 0 69.6 -.786 .891 9.7 .204 .0176 .0167 .0417 .5 15 .1 .44 .15 .135 .006 .009 .02 .42 .291 7.04 14.7 1.57 .103 5.17 .23 .713 14.3 .121 .537 .577 35 3 10 .433 .032 .297 6.34 410",         -- 3" toothpick: 0.11 kg, 3S, 5000KV, 76 mm
  "2.58 .0059 .987 .094 117 -4.79 .824 9.1 .287 .0741 .07 .0875 .286 7 0 .17 .0625 .0344 .006 .02 .02 .854 .237 5.61 8.42 1.34 .0243 2.5 .27 .919 25.6 .0789 .517 0 45 3 8 1.59 -.041 .536 11.9 200",        -- Whoop 65mm: ducted 1S, 24 g, 28000KV, 31 mm
  "3.54 .0198 .916 .09 116 -2.78 .864 9.01 .042 .0962 .0822 .0288 .556 15 .4 .19 .08 .036 .006 .016 .02 .456 .285 5.61 8.68 1.32 .0949 3.63 .25 .952 24.6 .0829 .526 .203 40 3 8 2.38 -.031 .212 5.67 350",  -- Whoop 75mm: ducted 2S, 47 g, 12000KV, 4-blade 40 mm
}

-- -------------------------------------------------------------- tracks
-- gates: x, z, type, yaw (deg), center height (0 = default). Types: 1 gate, 2 high gate,
-- 3 dive gate (flat, fly down through it), 4 hoop, 5 arch, 6 flag (pass on its right),
-- 7 flag (pass on its left), 8 gap in a structure.
-- boxes: x, z, half size x, half size z, bottom, top, kind (1 concrete, 2 red, 3 blue).
-- Boxes must not intersect: the renderer orders them with separating planes.
local TRACKS = {
  { "Meadow", 11, { 0,0,1,0,0, 0,30,1,15,0, 14,52,2,55,0, 38,56,1,110,0, 50,40,1,180,0, 36,24,1,190,0, 42,6,2,185,0,
                    32,-14,1,230,0, 12,-20,1,290,0 } },
  { "Figure 8", 23, { -14,10,1,0,0, 6,46,2,40,0, 18,68,1,0,0, 0,88,1,-90,0, -18,68,1,180,0, 18,16,1,180,0, 0,-4,1,-90,0 } },
  { "Dive Tower", 37, { 0,0,1,0,0, 0,26,2,5,0, 6,50,2,25,10, 22,70,1,75,0, 40,62,4,150,6, 36,40,3,200,0, 30,20,1,210,0,
                        18,6,1,190,0, 24,-14,2,205,0, 6,-22,1,295,0 } },
  { "Slalom", 53, { 0,0,5,0,0, -2,22,7,0,0, 6,40,6,0,0, -2,58,7,0,0, 6,76,6,0,0, 2,96,4,0,3, 22,112,2,90,0, 44,100,4,120,3,
                    48,78,7,180,0, 40,60,6,180,0, 48,42,7,180,0, 44,18,3,200,0, 28,-22,1,-90,0 } },
  { "Hoop Forest", 61, { 0,0,1,0,0, 6,22,4,35,2.4, 22,32,4,35,5, 28,52,4,45,3, 48,58,4,115,6, 56,38,2,140,0,
                         72,28,4,155,2, 70,6,4,220,4, 48,0,3,245,0, 30,-14,4,245,2.2, 12,-18,4,290,3 }, nil, 2 },
  { "Grand Prix", 71, { 0,0,5,0,0, 0,46,1,5,0, 6,84,2,30,6, 26,100,7,90,0, 36,74,4,150,3, 50,58,1,90,0, 68,78,4,50,3,
                        92,92,7,120,0, 100,62,3,200,0, 88,30,1,175,0, 104,6,2,190,8, 80,-14,1,255,0, 50,-10,4,260,2.2,
                        26,-24,1,275,0 } },
  { "Bando", 83, { 0,0,1,0,0, 0,34,8,0,1.8, 0,46,8,0,1.8, 20,66,4,60,4, 40,88,3,146,0, 56,64,1,180,0, 43.95,10,8,180,1.3,
                   22,-16,4,250,2.5 },
    { -6.225,34,4.025,0.25,0,7,1, 6.225,34,4.025,0.25,0,7,1, 0,34,2.2,0.25,3.6,7,1,
      -6.225,46,4.025,0.25,0,7,1, 6.225,46,4.025,0.25,0,7,1, 0,46,2.2,0.25,3.6,7,1,
      -10,40,0.25,5.75,0,7,1, 10,36.025,0.25,1.775,0,7,1, 10,43.975,0.25,1.775,0,7,1, 10,40,0.25,2.2,3.6,7,1,
      46,64,2,2,0,36,1, 33.6,10,1.25,3,0,2.6,2, 40.5,10,1.25,3,0,2.6,3, 47.4,10,1.25,3,0,2.6,2,
      -30,20,3,1.25,0,5.2,3, -36,50,4,4,0,3,1 } },
  -- laid out like a real race: lanes up and down the field joined by flag hairpins, a high
  -- gate and a dive gate on the start straight, a split-S (through the high gate, back
  -- through the one under it) and a corner flag before the finish
  { "Pro Track", 97, { 0,0,1,0,0, 0,22,2,0,0, 0,44,3,0,0, 8,62,7,90,0, 16,44,4,180,0, 16,22,1,180,0, 24,4,6,90,0,
                       32,22,1,0,0, 32,46,2,0,0, 32,46,1,180,0, 46,26,4,160,3, 48,4,1,180,0, 46,-14,7,225,0,
                       24,-22,1,270,0 } },
}
-- custom tracks: StickTimeTracks/c1.txt .. c8.txt on the SD card (the browser emulator's track
-- editor makes them; StickTime and StickTime BW read the same files, the Lite doesn't). A name line,
-- then the numbers: the format, an id (bests start over when it changes), tree seed, trees (9: as
-- many as most tracks), the gates (x z type yaw height), "/", the structures (x z half-x half-z
-- bottom top kind). Format 1: up to 24 gates, 16 structures and 1000 bytes, read by StickTime and
-- StickTime BW. Format 2, a bigger track: up to 48 gates, 64 structures and 6000 bytes, for this
-- edition only (StickTime BW has no memory for it and lists format 1 only, as earlier versions do;
-- this edition reads either to format 2's limits, the editor writes format 1 only within its). They are
-- tracks 9-16 whether or not the slots before them are filled; only the name and id are read here
local NB0, NT = #TRACKS, #TRACKS + 8
local CUSTOM = "/SCRIPTS/TOOLS/StickTimeTracks/c"
for i = 1, 8 do
  local f = io.open(CUSTOM .. i .. ".txt", "r")
  if f then
    local s = io.read(f, 60)
    io.close(f)
    local name, ver, id = string.match(s or "", "^%s*([^\r\n]+)[\r\n]+%s*(%d+)%s+(%d+)")
    if name and (ver == "1" or ver == "2") then TRACKS[NB0 + i] = { string.sub(name, 1, 16), file = i, id = tonumber(id) } end
  end
end
collectgarbage()                                       -- (the files and strings: a B&W heap is tight)
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
local GB = { x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {} }   -- gate bounds
-- start pad, track bounds, wind direction
local TR = { px = 0, pz = -14, hx = 0, hz = 1, x0 = 0, x1 = 1, z0 = 0, z1 = 1, wx = 0, wz = 1 }
-- AI pilots and the racing line (Hermite curves between aim points)
local AI = { n = 0, vt = 0, ch = {}, sl = {}, sf = {}, seg = {}, k = {}, s = {}, v = {}, d = {},
             x = {}, y = {}, z = {}, f = {}, o = {}, x0 = {}, z0 = {}, l0 = {}, vs = { 9, 13, 17.5 } }

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
local nBuilt = 0                                       -- how many tracks were built
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
    nBuilt = nBuilt + 1
    local T = TRACKS[t]
    if T.file then
      -- a custom track: read its numbers now (and let them go once it is built)
      local f = io.open(CUSTOM .. T.file .. ".txt", "r")
      local s = f and io.read(f, 6000) or ""           -- (format 2's most)
      if f then io.close(f) end
      local g, b = string.match(string.match(s, "^%s*[^\r\n]*[\r\n]+(.*)") or "", "([^/]*)/?(.*)")
      local n, d = 0, {}
      for v in string.gmatch(g or "", "%S+") do
        n = n + 1
        if n == 3 then T[2] = tonumber(v) or 1
        elseif n == 4 then T[5] = (tonumber(v) or 9) / 9
        elseif n > 4 and n <= 244 then d[n - 4] = tonumber(v) or 0 end   -- at most 48 gates
      end
      local tr = T[5] or 1                             -- 0-30 trees
      if tr < 0 then tr = 0 elseif tr > 30 / 9 then tr = 30 / 9 end
      T[5] = tr
      T[3], T[4] = d, {}
      for v in string.gmatch(b or "", "%S+") do
        if #T[4] < 448 then T[4][#T[4] + 1] = tonumber(v) or 0 end   -- at most 64 structures
      end
      -- gates in fives with a known type, structures in sevens with a known kind (a file made by hand)
      local ok, bd = #d >= 10 and #d % 5 == 0, T[4]
      for i = 3, #d, 5 do
        if d[i] < 1 or d[i] > 8 or d[i] - floor(d[i]) > 0.01 then ok = false end
      end
      if not ok then T[3] = { 0, 0, 1, 0, 0, 0, 30, 1, 0, 0 } end   -- unreadable: two gates in a line
      ok = #bd % 7 == 0
      for i = 7, #bd, 7 do
        if bd[i] < 1 or bd[i] > 3 or bd[i] - floor(bd[i]) > 0.01 then ok = false end
      end
      if not ok then T[4] = {} end
    end
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
        ay = y > 1.4 and y or 1.4                               -- a raised ring: its middle
      elseif k == 6 or k == 7 then
        -- (x, z) is the pole; the gate itself is the pass zone beside it
        local s = k == 6 and 1 or -1
        addPillar(x, z, 0.12, FLAGH, 3)
        ax, ay, az = x + hz * s * 2.5, 1.8, z - hx * s * 2.5
        x, z, y = x + hz * s * iw, z - hx * s * iw, 0
      end
      gx[NG], gy[NG], gz[NG], gk[NG] = x, y, z, k
      AX[NG], AY[NG], AZ[NG] = ax, ay, az
      -- bounds of what is drawn for this gate (legs and stands down to the ground)
      local sx, sz = hz < 0 and -hz or hz, hx < 0 and -hx or hx
      local w, d, y0, y1 = iw + GT, 0.2, y - ih - GT, y + ih + GT
      if k == 3 then d, y0, y1 = ih + GT, 0, y + GT
      elseif k == 2 then y0 = 0
      elseif k == 4 then y0, y1 = 0, y + iw + GT
      elseif k == 5 then y0, y1 = y, y + iw + GT    -- an arch: the upper half of a ring, no stand (raised, it floats)
      elseif k == 8 then w, d, y0, y1 = iw, 0, y - ih, y + ih end
      local bx, bz = x, z
      if k == 6 or k == 7 then
        local o = (k == 6 and -1 or 1) * iw
        bx, bz, w, d, y0, y1 = x + hz * o, z - hx * o, 1, 1, 0, FLAGH
      end
      GB.x0[NG], GB.x1[NG] = bx - sx * w - sz * d, bx + sx * w + sz * d
      GB.z0[NG], GB.z1[NG] = bz - sz * w - sx * d, bz + sz * w + sx * d
      GB.y0[NG], GB.y1[NG] = y0, y1
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
    local n, tries, want = 0, 0, 18 * (T[5] or 1)
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
    if T.file then T[3], T[4] = nil, nil end
  end
end

-- --------------------------------------------------------- persistence
local BEST = { l = {}, r = {}, g = {}, f = {}, i = {} }   -- per track: best lap, race, gate rush gates,
for t = 1, NT do BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t], BEST.i[t] = 0, 0, 0, 0, 0 end   -- combo, track id
local loadData, saveData
do
local DATA = "/SCRIPTS/TOOLS/StickTime.dat"
local OLD = "/SCRIPTS/TOOLS/FPVSim.dat"                 -- the save under the old name, FPV Sim

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
  if type(S.track) ~= "number" or not TRACKS[S.track] then S.track = 1 end
  -- a custom track that is not the one these bests were flown on: they start over
  for t = NB0 + 1, NT do
    local T = TRACKS[t]
    if T and BEST.i[t] ~= T.id then BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t], BEST.i[t] = 0, 0, 0, 0, T.id end
  end
end

loadData = function()
  local f, old = io.open(DATA, "r"), false
  if not f then f, old = io.open(OLD, "r"), true end
  if not f then validate() return end
  local s = io.read(f, 2048)
  io.close(f)
  if type(s) ~= "string" then return end
  if string.sub(s, 1, 7) == "FPVSIM2" then
    local lay = 0
    for k, n, v in string.gmatch(s, "(%a+)(%d*)=(%-?%d+)") do
      v = tonumber(v)
      if k == "lay" then lay = v
      elseif n == "" then
        if S[k] ~= nil then S[k] = v end
      else
        local t = tonumber(n)
        if BEST[k] and t >= 1 and t <= NT then BEST[k][t] = v end
      end
    end
    -- layout 2 (1.6.2) swapped the flag sides on the Slalom and the Grand Prix: a straight line
    -- passed them. Lap and race bests flown before cannot be beaten fairly, so they start over.
    if lay < 2 then BEST.l[4], BEST.r[4], BEST.l[6], BEST.r[6] = 0, 0, 0, 0 end
    -- layout 3 (1.7.0): Meadow, Dive Tower, Hoop Forest and the Grand Prix are new layouts, not ovals
    if lay < 3 then
      for _, t in ipairs({ 1, 3, 5, 6 }) do BEST.l[t], BEST.r[t], BEST.g[t] = 0, 0, 0 end
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
    S.twr = ({ 3, 4, 6 })[v[6] or 2] or 6
    for t = 2, 2 do                -- (Meadow and Dive Tower have new layouts since 1.7.0)
      BEST.l[t], BEST.r[t] = v[9 + t * 2] or 0, v[10 + t * 2] or 0
    end
  end
  validate()
  if old then saveData() end                       -- under the new name right away
end

saveData = function()
  -- piece by piece: a line grown by concatenation leaves 14-39 KB of strings behind
  local f = io.open(DATA, "w")
  if not f then return end
  io.write(f, "FPVSIM2 lay=3")
  for k, v in pairs(S) do io.write(f, " " .. k .. "=" .. floor(v)) end
  for k, b in pairs(BEST) do
    for t = 1, NT do
      if b[t] > 0 then io.write(f, " " .. k .. t .. "=" .. floor(b[t])) end
    end
  end
  io.write(f, "\n")
  io.close(f)
end
end

-- ----------------------------------------------------------- game state
local px, py, pz, vx, vy, vz = 0, 0.15, 0, 0, 0, 0                 -- quad position / velocity (m, m/s)
local rx, ry, rz, ux, uy, uz, fx, fy, fz = 1, 0, 0, 0, 1, 0, 0, 0, 1 -- quad right / up / forward axes
local sA, sE, sT, sR, speed = 0, 0, 0, 0, 0                           -- sticks, speed
local aTf, aVu, aE2, aW, aS, aF = 0, 0, 0, 0, 0, 0  -- sound state (thrust frac, sink, edge speed, wash, shake)
local DR, NEAR = 0.15, 0.2                                            -- quad radius, camera near plane
local P = { rc = 100, rm = 600, re = 0.5, yc = 100, ym = 500, ye = 0.4, twr = 6, angle = false, tc = 0.9, ts = 0.42,
            wr = 0, wp = 0, wy = 0 }                                  -- settings in use, body rates (rad/s)
local state, prevState, pausedFrom, gmode = MENU, MENU, FLY, 1
local gt, lastT, tState, tStart = 0, 0, 0, 0                          -- game clock in 10 ms ticks
local lapStart, lap, nextGate, lastGate = nil, 0, 1, 0
local R = { laps = {}, n = 0, total = 0, newLap = false, newRace = false, newBest = false, msg = nil, msgT = 0, good = true,
            ready = 0, crashes = 0, cd = -1, fps = 0, fpsN = 0, fpsT = 0, fpsX = "", runS = 0, showS = 0,
            pk = 0, pos = 1, sc = 0, ch = 0, chn = 0, cht = 0, prox = 9, rn = 0, rt = 0, smp = 0,
            fi = 5, pt = 0, st = 0 }          -- frame interval, sim time (10 ms ticks), prop strike left (s)
-- the battery (setting). One pack per class (Racer 5", Freestyle 5", 3" toothpick, Whoop 65mm, Whoop
-- 75mm): cells, capacity (mAh), resistance (milliohm a cell), current at full throttle (A), and the
-- volts a cell has over 4.2 when full (LiHV). In use (applySettings): cells n, capacity mah (1.5 or 2
-- times for 1.5x, 2x), resistance r (ohm), current f (more with more Power), h. The pack's state: charge s (1 full .. 0 empty), cell
-- voltage under load v (filtered over about 1 s), current i (A), flight time t and time since it ran
-- empty e (s), warning w (1 below 3.5 V a cell, 2 below 3.3 V)
local BAT = { "4 1300 6 95 0", "4 1500 6 120 0", "3 550 20 28 .15", "1 300 45 11 .15", "2 300 35 14 .15",
              s = 1, v = 4.2, i = 0, t = 0, e = 0, w = 0 }
BAT.new = function()                                   -- a fresh pack
  BAT.s, BAT.v, BAT.i, BAT.t, BAT.e, BAT.w = 1, 4.2 + BAT.h, 0, 0, 0, 0
end
BAT.text = function()                                  -- flight time (m:ss) and mAh used
  return fmt("%d:%02d", floor(BAT.t / 60), floor(BAT.t) % 60), floor((1 - BAT.s) * BAT.mah + 0.5) .. "mAh"
end

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

-- medals: Bronze, Silver and Gold are the lap times of the Easy, Medium and Hard AI pilot with
-- the pilot's class and power, a flying lap along the racing line as AI.update flies it (ticks)
local MED = { 0, 0, 0, n = { "BRONZE", "SILVER", "GOLD" } }
MED.calc = function()
  for m = 1, 3 do
    local vb, v, t = AI.vs[m] * (0.75 + 0.05 * P.twr), 0, 0
    for k = 1, 2 * NG do                     -- the second lap counts: it starts at racing speed
      local i = (k - 1) % NG + 1
      local vt, L = vb * AI.sf[i], AI.sl[i]
      local a = v < vt and 10 or -14
      local d = (vt * vt - v * v) / (2 * a)   -- to the leg's speed
      local dt
      if d > L then
        local v2 = sqrt(v * v + 2 * a * L)
        dt, v = (v2 - v) / a, v2
      else
        dt, v = (vt - v) / a + (L - d) / vt, vt
      end
      if k > NG then t = t + dt end
    end
    MED[m] = floor(t * 100 + 0.5)
  end
end
MED.of = function(t)                         -- 0 none, 1 bronze, 2 silver, 3 gold
  local m = 0
  for i = 1, 3 do
    if t > 0 and t <= MED[i] then m = i end
  end
  return m
end
-- the next medal to fly for on this track ("SILVER 16.48"), or the gold the pilot has; and which
MED.goal = function()
  local m = MED.of(BEST.l[S.track])
  if m == 3 then return MED.n[3], 3 end
  return MED.n[m + 1] .. " " .. timeStr(MED[m + 1]), m + 1
end

local function beep(f, d, flags, p)                   -- p: a pause after the tone (ms)
  if playTone then playTone(f, d, p or 0, flags or 0) end
end

local function showMsg(s, good)
  R.msg, R.msgT, R.good = s, gt, good
end

-- ghost (Practice, setting Ghost): the fastest practice lap on the track flies along with each lap,
-- drawn like an AI pilot. It is the quad's position every iv ticks from the lap's start, at most
-- GMAX samples (a longer lap doubles iv and keeps every other one). Kept as text, as on the SD card
-- (StickTimeGhosts/c1.txt...: a header line, then the samples): 3 values (0.1 m) of 3 characters
-- (6 bits each, from "0"), 16 samples to a chunk string. Color only: StickTime BW keeps its memory for
-- the B&W radios
local GH = { n = 0, iv = 10, lap = 0, c = {}, t = 0 }  -- the ghost: samples, interval and lap (ticks), track
local RC = { n = 0, iv = 10, c = {}, q = "" }          -- the lap being recorded (t0: its start, q: its last chunk)
local ghost = {}                                       -- load, lap, start, step
do
  local GMAX, GFILE = 600, "/SCRIPTS/TOOLS/StickTimeGhosts/c"

  local function gsample(k)                    -- the ghost's position k (1..n)
    local i = floor((k - 1) / 16)
    local o = (k - 1 - i * 16) * 9
    local a, b, c, d, e, f, g, h, j = string.byte(GH.c[i + 1], o + 1, o + 9)
    return (a * 4096 + b * 64 + c - 330800) * 0.1, (d * 4096 + e * 64 + f - 330800) * 0.1,
           (g * 4096 + h * 64 + j - 330800) * 0.1
  end

  local function genc(v)
    local u = floor(v * 10 + 0.5) + 131072
    if u < 0 then u = 0 elseif u > 262143 then u = 262143 end
    return floor(u / 4096) + 48, floor(u / 64) % 64 + 48, u % 64 + 48
  end

  local function gadd(q)                       -- one more recorded sample (its 9 characters)
    q = RC.q .. q
    RC.n = RC.n + 1
    if #q == 144 then RC.c[#RC.c + 1], q = q, "" end
    RC.q = q
  end

  ghost.load = function()
    GH, RC = { n = 0, iv = 10, lap = 0, c = {}, t = S.track }, { n = 0, iv = 10, c = {}, q = "" }
    local f = io.open(GFILE .. S.track .. ".txt", "r")
    if not f then return end
    local ng, x, z, iv, n, lt, id = string.match(io.read(f, 49) or "", "^STG2 +(%d+) +(%-?%d+) +(%-?%d+) +(%d+) +(%d+) +(%d+) +(%d+)")
    n = tonumber(n)
    -- the same track (gate count, first gate, a custom track's id) and a size this game can keep
    if n and tonumber(ng) == NG and tonumber(x) == floor(AX[1] * 10 + 0.5) and tonumber(z) == floor(AZ[1] * 10 + 0.5)
       and tonumber(id) == (TRACKS[S.track].id or 3) and n > 1 and n <= GMAX and tonumber(iv) > 0 and tonumber(lt) > 0 then
      local c = {}
      for i = 1, floor((n + 15) / 16) do c[i] = io.read(f, 144) or "" end
      if #c[#c] == (n - 1) % 16 * 9 + 9 then GH = { n = n, iv = tonumber(iv), lap = tonumber(lt), c = c, t = S.track } end
    end
    io.close(f)
  end

  ghost.lap = function(lt)                     -- a practice lap ends: is it the new ghost?
    if RC.t0 ~= lapStart or RC.n < 2 or (GH.n > 0 and lt >= GH.lap) then return end
    if #RC.q > 0 then RC.c[#RC.c + 1] = RC.q end
    GH = { n = RC.n, iv = RC.iv, lap = lt, c = RC.c, t = S.track, dirty = true }   -- (saved by R.flush)
  end

  -- its file. The id: a custom track's, else the layout of the built-in tracks (3)
  ghost.save = function()
    local f = io.open(GFILE .. GH.t .. ".txt", "w")
    if not f then return end
    io.write(f, string.format("STG2 %3d %6d %6d %5d %4d %7d %6d\n", NG, floor(AX[1] * 10 + 0.5), floor(AZ[1] * 10 + 0.5), GH.iv,
      GH.n, GH.lap, TRACKS[GH.t].id or 3))
    for i = 1, #GH.c do io.write(f, GH.c[i]) end
    io.close(f)
  end

  ghost.start = function()                     -- a practice lap starts: record it
    local iv = GH.n > 0 and floor(GH.lap / GMAX) + 1 or 10   -- (a lap that can beat the ghost fits)
    RC = { n = 0, iv = iv < 10 and 10 or iv, c = {}, q = "", t0 = lapStart }
  end

  -- every frame of a practice lap: record it, and put the ghost where it was at this time of its lap
  -- (as AI pilot 4; GH.on while it flies)
  ghost.step = function()
    local t0 = RC.t0
    if t0 then
      local t = gt - t0
      if GH.n > 0 and t > GH.lap then RC.t0 = nil          -- this lap can't beat the ghost any more
      elseif t >= RC.n * RC.iv then
        local k = (RC.n * RC.iv - t) * 0.01           -- (back to the sample's own time)
        local a, b, c = genc(px + vx * k)
        local d, e, f = genc(py + vy * k)
        local g, h, i = genc(pz + vz * k)
        gadd(string.char(a, b, c, d, e, f, g, h, i))
        if RC.n >= GMAX then
          local o = RC
          RC = { n = 0, iv = o.iv * 2, c = {}, q = "", t0 = t0 }
          for k = 1, o.n, 2 do
            local j = floor((k - 1) / 16)
            local p = (k - 1 - j * 16) * 9
            gadd(string.sub(o.c[j + 1] or o.q, p + 1, p + 9))
          end
        end
      end
    end
    GH.on = false
    if GH.n > 1 and lapStart then
      local t = (gt - lapStart) / GH.iv
      local k = floor(t)
      if k + 2 <= GH.n then
        local x0, y0, z0 = gsample(k + 1)
        local x1, y1, z1 = gsample(k + 2)
        t = t - k
        AI.x[4], AI.y[4], AI.z[4], GH.on = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, z0 + (z1 - z0) * t, true
      end
    end
  end
  ghost.max, ghost.file = GMAX, GFILE
end

-- the saves: a new best and a new ghost are written at once (the radio may be switched off any
-- time); the breaks (pause, restart, the menu, a crash, the end of a run) write anything left
R.flush = function()
  if R.dirty then
    R.dirty = false
    saveData()
  end
  if GH.dirty then
    GH.dirty = false
    ghost.save()
  end
end

-- -------------------------------------------------------------- physics
local readSticks, rotate, placeDrone, respawn, physics, rnd, trick, tricks, rushNext
;(function()
  local G = 10.78                               -- 1.1 g: a heavier, more planted feel
  local SRC = { "ail", "ele", "thr", "rud" }
  local grounded = true
  local nearG, nearP, nearB = {}, {}, {}
  local Tm = 0                                   -- motor thrust (lags the throttle)
  -- prop wash: shake (rad) and its turning part, wash build-up (0..1), shake size and severity,
  -- thrust loss
  local wob1, wob2, wob3, wq1, wq2, wq3, sW, sH, sV, wl = 0, 0, 0, 0, 0, 0, 0, 0, 1, 0
  local mr, mp = 0, 0                            -- the motors' own roll and pitch rate (flips)
  local kwr, kwp, kwy                            -- body rates a hit adds (rad/s)
  local turtle, hitT = false, 0                  -- on its back on the ground; when a hit last buzzed
  local seed = 7

  rnd = function()
    seed = seed * 171 % 30269
    return seed / 30269
  end
  if STICKTIME_TEST then STICKTIME_TEST.seed = function(s) seed = s end end

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
    speed, Tm, P.wr, P.wp, P.wy, sW, sH, wob1, wob2, wob3, wq1, wq2, wq3 = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    mr, mp, R.st, kwr, turtle = 0, 0, 0, nil, false
    for i = 1, NG do
      gd[i] = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i]
    end
  end

  respawn = function()
    if BAT.s <= 0 then BAT.new() end                   -- the pack ran empty: a fresh one
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

  -- why: nil for a crash, "EMPTY" when the battery ran out (shown instead of CRASH, not counted)
  local function crash(why)
    if state == DONE then respawn() return end
    state, tState, R.why = CRASHED, gt, why
    R.flush()
    if not why then R.crashes = R.crashes + 1 end
    if gmode == 3 then
      R.ch, R.chn = 0, 0
      tricks(-1)
    end
    beep(260, 400, PLAY_NOW)
    if playHaptic and S.vib == 1 then playHaptic(60, 0) end
  end

  -- a contact (n: the surface's outward normal): no bounce, the quad stops into the surface and slides
  -- on with friction mu. From 1.5 m/s into it, the hit is a prop strike: for up to half a second the
  -- props lose most of their thrust and the flight controller its hold, and the quad tumbles about
  -- the point that touched (the rim of a disk the size of the quad, nearest the surface; most at 45
  -- deg to it, none flat on), so the pilot has to fly it out. Nothing breaks: no respawn
  local function hit(nx, ny, nz, mu)
    local vn = -(vx * nx + vy * ny + vz * nz)
    if vn <= 0 then return end
    vx, vy, vz = vx + vn * nx, vy + vn * ny, vz + vn * nz
    local vt = sqrt(vx * vx + vy * vy + vz * vz)
    local f = vt > 0.01 and mu * vn / vt or 1
    if f > 1 then f = 1 end
    local jx, jy, jz = vn * nx - vx * f, vn * ny - vy * f, vn * nz - vz * f   -- the impulse (per kg)
    vx, vy, vz = vx * (1 - f), vy * (1 - f), vz * (1 - f)
    if vn < 1.5 then return end
    if gt - hitT > 30 then
      hitT = gt
      beep(160 + vn * 8, 90, PLAY_NOW)
      if playHaptic and S.vib == 1 and vn > 3 then playHaptic(vn > 8 and 60 or 30, 0) end
    end
    -- the props and arms strike only edge-on: flat on (a level landing) the skids take it. Toward the
    -- rim point (length sqrt(1 - d^2)); the turn 3 * c x j is 1.5 rad/s per m/s into a surface at 45
    -- deg, at most 20 rad/s
    local d = nx * ux + ny * uy + nz * uz
    local q = 1 - d * d
    if q < 0 then q = 0 end
    local vs = vn * sqrt(q)
    if vs < 1.5 then return end
    local cx, cy, cz = d * ux - nx, d * uy - ny, d * uz - nz
    local ax, ay, az = (cy * jz - cz * jy) * 3, (cz * jx - cx * jz) * 3, (cx * jy - cy * jx) * 3
    local w = sqrt(ax * ax + ay * ay + az * az)
    if w > 20 then ax, ay, az = ax * 20 / w, ay * 20 / w, az * 20 / w end
    kwr, kwp, kwy = -(ax * fx + ay * fy + az * fz), -(ax * rx + ay * ry + az * rz), ax * ux + ay * uy + az * uz
    local t = vs * 0.04
    if t > 0.5 then t = 0.5 end
    if t > R.st then R.st = t end
    R.crashes, R.hv = R.crashes + 1, vs
    if gmode == 3 then
      R.ch, R.chn = 0, 0
      tricks(-1)
    end
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
    state, tState, focus, R.dirty = DONE, gt, 1, true
    R.flush()
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
          local m = MED.of(lt)
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  " .. (m > MED.of(b) and MED.n[m] or "BEST") .. "!", true)
          R.dirty = true
        else
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  +" .. timeStr(lt - b), false)
        end
        if gmode == 2 and S.ghost == 1 then ghost.lap(lt) end
        R.flush()                                    -- (now: the radio may be switched off any time)
        lap = lap + 1
        beep(2200, 160)
        if playHaptic and S.vib == 1 then playHaptic(25, 0) end
        if gmode == 1 and lap > S.laps then finishRace() return end
      else
        lap = 1
        beep(1600, 80)
      end
      lapStart = gt
      if gmode == 2 and S.ghost == 1 then ghost.start() end
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
    local cwr, cwp = wr, wp                       -- the stick's rates, before the prop wash shake (the mixer's)
    -- stick -> thrust: idle (min_throttle), the bottom dead zone, then the class curve (rpm ~ stick, thrust ~ rpm^2)
    local tx = (sT - P.dz) / (1 - P.dz)
    if tx < 0 then tx = 0 end
    local T = Tmax * (P.i0 + (1 - P.i0) * ((1 - P.tk) * tx ^ P.tn + P.tk * tx ^ 8))
    -- the battery (setting, off by default): the current grows with thrust^1.5 (momentum theory; 5%
    -- of full at idle for the motors and electronics) and the cells sag by current x resistance from
    -- their rest voltage. Down to 3.5 V a cell under load the quad flies as without it (Betaflight's
    -- sag compensation: a fresh pack flies as before, a lap never gets faster), below that the thrust
    -- falls with the voltage squared. Near empty the cells give no more current than takes them to
    -- 3.0 V: the quad limps (thrust ~ current^(2/3)). Empty when full throttle would lift no more than
    -- 1.25 times the weight: the motors stop
    if S.batt > 0 then
      local s, c, r, f = BAT.s, T / Tmax, BAT.r, BAT.f
      local I = f * (0.05 + 0.95 * c * sqrt(c))
      local v = (s >= 0.8 and 3.98 + 1.1 * (s - 0.8) or s >= 0.12 and 3.66 + 0.47 * (s - 0.12) or 3 + 5.5 * s) + BAT.h * s
      local im, k, t = (v - 3) / r, 1, BAT.t + dt
      if I <= im then
        v = v - I * r
        if v < 3.5 then k = v * v / 12.25 end
      else
        k, I, v = 0.735 * (im / I) ^ 0.67, im, 3
      end
      s = s - I * dt / (3.6 * BAT.mah)
      -- empty once full throttle would lift no more than 1.25 times the weight: limping on, it could
      -- hardly fly any more
      local km = im <= 0 and 0 or im < f and 0.735 * (im / f) ^ 0.67 or 1
      if km * P.twr < 1.25 then
        s, k, I = 0, 0, 0
        BAT.e = BAT.e + dt                             -- empty: the quad drops, a second later EMPTY
        if BAT.e > 1 then crash("EMPTY") return end
      end
      v = BAT.v + (v - BAT.v) * (dt < 1 and dt or 1)
      -- warnings: below 3.5 V a cell a beep every 2 s of flight, below 3.3 V a double beep (and LAND)
      local w = v < 3.3 and 2 or v < 3.5 and 1 or 0
      if w > 0 and floor(t * 0.5) > floor(BAT.t * 0.5) then
        beep(660, 150, 0, 100)
        if w > 1 then
          beep(660, 150)
        end
      end
      BAT.s, BAT.i, BAT.v, BAT.t, BAT.w = s, I, v, t, w
      T = T * k
    end
    -- prop wash (setting, off by default): sinking into your own downwash. The props build up a
    -- wash over ~0.2 s while they move down their own axis, less the faster they also move edgewise.
    -- It costs thrust (up to wl, from a 0.6 m/s sink until it fades out at wv m/s: the quad sinks
    -- and feels mushy) and shakes it.
    wl = 0
    if S.wash > 0 then
      local vu0 = vx * ux + vy * uy + vz * uz
      if vu0 < 0 then
        local vr0, vf0 = vx * rx + vy * ry + vz * rz, vx * fx + vy * fy + vz * fz
        local k = dt * 5
        if k > 1 then k = 1 end
        sW = sW + (1 / (1 + sqrt(vr0 * vr0 + vf0 * vf0)) - sW) * k
        if vu0 < -0.6 then
          local f = (P.wv + vu0) / (P.wv - 2)
          if f > 1 then f = 1 elseif f < 0 then f = 0 end
          wl = P.wl * sW * f
        end
      end
      -- the shake: the props chop through their own turbulent wake and the quad rings at its wash
      -- frequency. Sized from real Betaflight blackbox logs: pw is the jitter's rms in degrees at full
      -- wash with the throttle chopped (tenths of a degree; about half with throttle on, when the
      -- motors have the authority to fight it), each wash its own severity. From a 0.5 m/s sink, gone
      -- in forward flight, no drift (the rates are its steps); the wake keeps buffeting it for ~0.2 s
      -- after the sink stops
      local a = 0
      if vu0 < -0.5 and dt > 0 then
        a = (-vu0 - 0.5) * 0.5
        if a > 1 then a = 1 end
        local th = sT * 2 - 0.2
        if th < 0 then th = 0 elseif th > 1 then th = 1 end
        if sH < 1e-4 then sV = 0.4 + 1.8 * rnd() ^ 2 end   -- a new wash: how bad this one is
        a = a * sW * (1 - 0.45 * th) * sV * P.pw * 0.0504  -- rad: its rms is 0.346 a
      end
      local k = dt * 5
      if k > 1 then k = 1 end
      if a < sH then a = sH + (a - sH) * k end
      sH = a
      local rh = dt * 9                                -- the same jitter at any frame rate:
      if rh > 1 then rh = 1 end                        -- 0.55 of it kept per 50 ms frame
      local g = a * sqrt(rh * (2 - rh)) * 1.2
      -- each axis is a fading phasor turning at the class's wash frequency (real quads: 20-45 Hz);
      -- past what the frame rate can show, as fast as the screen can (2.5 rad a frame)
      local w = dt * P.pf * 6.283
      if w > 2.5 then w = 2.5 end
      local c, s = cos(w) * (1 - rh), sin(w) * (1 - rh)
      local j1, j2, j3 = wob1 * c - wq1 * s + (rnd() - 0.5) * g, wob2 * c - wq2 * s + (rnd() - 0.5) * g,
        wob3 * c - wq3 * s + (rnd() - 0.5) * g * 0.35
      if dt > 0 then
        wr, wp, wy = wr + (j1 - wob1) / dt, wp + (j2 - wob2) / dt, wy + (j3 - wob3) / dt
        wq1, wq2, wq3 = wob1 * s + wq1 * c + (rnd() - 0.5) * g, wob2 * s + wq2 * c + (rnd() - 0.5) * g,
          wob3 * s + wq3 * c + (rnd() - 0.5) * g * 0.35
        wob1, wob2, wob3 = j1, j2, j3
      end
    end
    if grounded and uy < 0.4 then
      -- on its back or side on the ground (or a roof): the props can't lift it. Turtle mode: a roll
      -- or pitch stick spins two motors backwards and flips it back over
      wr = sA > 0.25 and 3.5 or sA < -0.25 and -3.5 or 0
      wp = sE > 0.25 and -3.5 or sE < -0.25 and 3.5 or 0
      wy, T, R.st, kwr = 0, 0, 0, nil
      P.wr, P.wp, P.wy, mr, mp, cwr, cwp = wr, wp, 0, 0, 0, 0, 0
      if not turtle then
        turtle = true
        showMsg("roll to flip", false)
      end
    else
      turtle = false
      if grounded and T < G * 1.02 and speed < 2 then
        -- resting on the ground (once a skid has slowed down): stays level, can only yaw
        wr, wp, P.wr, P.wp, mr, mp, cwr, cwp = 0, 0, 0, 0, 0, 0, 0, 0
        if uy < 0.999 then placeDrone(px, py, pz, fx, fz) end
      end
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
    local km, kr, ky = h / (P.tm + h), h / (P.tr + h), h / (P.ty + h)
    local VP, VK, VC, KS, KF, KU = P.vp, P.vk, P.vc, P.ks, P.kf, P.ku
    local TL, VT2, TE, TA, ER, VD, LR, GG, GL, GW = P.tl, P.vt * P.vt, P.te, P.ta, P.er, P.vd, P.lr, P.gg, P.gl, P.gw
    local SQ, CQ, CE, SE, RF, RQ, TB = P.sq, P.cq, P.ce, P.se, P.rf, P.rq, P.tb
    local KH = (P.kh or 0) * (S.grip == 2 and 1 or S.grip == 1 and 0.4 or 0)
    -- flips (an airmode mixer): the motors' own rate follows the stick's rate no faster than am (more
    -- toward full throttle; both fitted to the reference's thrust while a flip starts); while it catches
    -- up they need a differential on top of the collective: at full throttle the collective drops (the
    -- high side can't go higher), near hover it rises (the low side can't go below idle). Levels in
    -- motor command (thrust ~ c^2)
    local I0 = P.i0
    local ch, c0 = (1 / P.twr - I0) / (1 - I0), (T / Tmax - I0) / (1 - I0)
    ch, c0 = ch > 0 and sqrt(ch) or 0, c0 > 0 and sqrt(c0) or 0
    local AM = 1 - ch + c0
    if AM < 0.3 then AM = 0.3 end
    AM = P.am * AM * h
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
      if kwr then pwr, pwp, pwy, kwr = pwr + kwr, pwp + kwp, pwy + kwy, nil end
      local st = R.st
      if st > 0 then
        -- a prop strike: the flight controller has lost its hold, the quad tumbles on
        R.st = st - h
        local k = 1 - 1.5 * h
        pwr, pwp, pwy = pwr * k, pwp * k, pwy * k
      else
        pwr, pwp, pwy = pwr + (wr - pwr) * kr, pwp + (wp - pwp) * kr, pwy + (wy - pwy) * ky
      end
      rotate(pwr * h, pwp * h, pwy * h)
      -- the flip's differential d (half of it, as a share of the motors' range; roll and pitch add up
      -- on a motor) and the collective Te it leaves
      local Te = Tm
      if AM > 0 then
        local dr, dp = cwr - mr, cwp - mp
        if dr > AM then dr = AM elseif dr < -AM then dr = -AM end
        if dp > AM then dp = AM elseif dp < -AM then dp = -AM end
        mr, mp = mr + dr, mp + dp
        local d = ((dr < 0 and -dr or dr) + (dp < 0 and -dp or dp)) / AM * 0.5
        if d > 1e-4 then
          if d > 0.5 then d = 0.5 end
          local c = (Tm / Tmax - I0) / (1 - I0)
          c = c > 0 and sqrt(c) or 0
          if c + d > 1 then c = 1 - d end
          if c < d then c = d end
          Te = Tmax * (I0 + (1 - I0) * (c * c + d * d))
        end
      end
      if st > 0 then Te = Te * 0.3 end              -- struck props: most of the thrust gone
      -- air-relative velocity in body axes
      local ax_, az_ = vx - wx, vz - wz
      local vu = ax_ * ux + vy * uy + az_ * uz
      local vr = ax_ * rx + vy * ry + az_ * rz
      local vf = ax_ * fx + vy * fy + az_ * fz
      -- props lose thrust as the air through them speeds up (climbing) and gain thrust sinking,
      -- until the blades stall in a fast drop
      local tf = Te / Tmax                              -- thrust fraction
      local Ta
      if vu < 0 then
        -- descending: a cushion that rises to cq at a sink of sq*tf^se, then stalls away (to rf + rq*tf:
        -- with power the blades hold their thrust, at idle they stall)
        local x = 9
        if tf > 0.001 then x = -vu / (SQ * tf ^ SE) end
        local r = 1 + (CQ - 1) * (1 - CE * tf) * (2 * x - x * x)
        local fl = RF + RQ * tf
        if fl > 1 then fl = 1 end
        if r < fl then r = fl end
        Ta = Te * r
      else
        if Te > 0.001 then                            -- the loss grows with thrust as T*(Tmax/T)^VC
          local den = VP + vu * VK                    -- and bends with VK as the inflow grows
          if den < VP * 0.3 then den = VP * 0.3 end
          Ta = Te - vu * Te * (Tmax / Te) ^ VC / den
        else
          Ta = 0
        end
        if Ta < 0 then Ta = 0 end
      end
      Ta = Ta * (1 - wl)
      -- translational lift: flying edgewise the props reach fresh air, the induced inflow drops
      -- and the same rpm gives more thrust (a 5" at hover throttle: about +20% at 6 m/s, levelling off near +50%)
      local e2 = vr * vr + vf * vf
      -- the gain grows with throttle (tb), fades near full stick (te) and as air comes through the
      -- props axially (ta, m/s)
      local t2 = tf * tf
      local fa = 1 - TE * t2 * t2
      if fa < 0 then fa = 0 end
      fa = fa * (1 + TB * tf)
      if vu > 0 then fa = fa / (1 + vu / TA) end
      Ta = Ta * (1 + TL * fa * e2 / (e2 + VT2))
      -- ground effect: within a twentieth of the prop diameter of the ground or a roof the props
      -- push their inflow against it (measured along body-down): up to
      -- +25% on a 5", +45% on a 3". Less when tilted (the ray is longer), fades with speed.
      if uy > 0.3 then
        local d = (py - fl - DR) / uy + 0.03
        if d < GL then
          local k = (GL - d) / GW
          if k > 1 then k = 1 end
          Ta = Ta * (1 + GG * k / (1 + e2 * 0.0125))
        end
      end
      -- body drag along the flow: each face's area weighted by the flow through it
      -- (a = -S v), somewhat more at low speed. No rotor drag: the quad keeps its momentum.
      local au, ar, af = Ta, 0, 0
      local v2 = vu * vu + e2
      if v2 > 1e-4 then
        local v = sqrt(v2)
        local S_ = KS * (vr < 0 and -vr or vr) + KU * (vu < 0 and -vu or vu) + KF * (vf < 0 and -vf or vf)
        local xd = v / VD
        if xd > 1 then xd = 1 end
        S_ = S_ * (1 + ER * (1 - xd * xd * (3 - 2 * xd)))
        au, ar, af = Ta - S_ * vu, -S_ * vr, -S_ * vf
        -- frame lift: air on the top of the frame (nose down at speed) pushes it down, air under
        -- the belly lifts it; strongest with the flow 45 deg to the frame, across the flow
        local sn = vu / v
        local c2 = 1 - sn * sn
        if c2 > 1e-4 then
          local c = sqrt(c2)
          local q = LR * sn * 0.813 * (2 * (sn < 0 and -sn or sn) * c) ^ 0.6 * S_ * v / c
          au = au - q * c2
          q = q * sn / v
          ar, af = ar + q * vr, af + q * vf
        end
      end
      -- rotor drag (the Grip setting; the reference model has none: Low): props moving edgewise are
      -- pushed back, harder the faster they spin (~ sqrt of the thrust)
      if KH > 0 then
        local k = KH * sqrt(Te * 0.0186 + 0.02)            -- 0.0186 = 1 / (5 G)
        ar, af = ar - k * vr, af - k * vf
      end
      vx = vx + (ux * au + rx * ar + fx * af) * h
      vy = vy + (uy * au + ry * ar + fy * af - G) * h
      vz = vz + (uz * au + rz * ar + fz * af) * h
      local ox, oy, oz = px, py, pz
      px, py, pz = px + vx * h, py + vy * h, pz + vz * h
      grounded = false
      if py < DR then
        py, grounded = DR, true
        if vy < 0 then hit(0, 1, 0, 0.6) end
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
          local bump = false
          if sh == 2 then
            local r2, a, b = lx * lx + ly * ly, iw - DR * 0.5, iw + GT + DR
            if r2 < a * a then gatePassed(i, d1 >= 0)
            elseif r2 < b * b then bump = true end
          else
            if lx < 0 then lx = -lx end
            if ly < 0 then ly = -ly end
            if lx < iw - DR * 0.5 and ly < ih - DR * 0.5 then gatePassed(i, d1 >= 0)
            elseif sh == 1 and lx < iw + GT + DR and ly < ih + GT + DR then bump = true end
          end
          if bump then
            -- the frame or rim: back on the side it came from, against it
            local sg = d0 < 0 and -1 or 1
            local m = sg * (GT * 0.5 + DR)
            local e = m - d1
            px, py, pz = px + gnx[i] * e, py + gny[i] * e, pz + gnz[i] * e
            gd[i] = m
            hit(gnx[i] * sg, gny[i] * sg, gnz[i] * sg, 0.3)
          end
          if state ~= FLY and state ~= DONE then return end
        end
      end
      -- trees, legs, poles and structures
      for j = 1, np do
        local i = nearP[j]
        local dx, dz, r = px - qx[i], pz - qz[i], qr[i] + DR
        if dx < r and dx > -r and dz < r and dz > -r and py < qh[i] and dx * dx + dz * dz < r * r then
          -- out from the middle of the trunk or pole
          if dx * dx + dz * dz < 1e-4 then dx, dz = ox - qx[i], oz - qz[i] + 0.01 end
          local l = sqrt(dx * dx + dz * dz)
          dx, dz = dx / l, dz / l
          px, pz = qx[i] + dx * r, qz[i] + dz * r
          hit(dx, 0, dz, 0.3)
        end
      end
      for j = 1, nb do
        local i = nearB[j]
        local a0, a1, b0, b1, c0, c1 = bx0[i] - DR, bx1[i] + DR, by0[i] - DR, by1[i] + DR, bz0[i] - DR, bz1[i] + DR
        if px > a0 and px < a1 and pz > c0 and pz < c1 and py < b1 and py > b0 then
          -- out through the face it came in by: the one it crossed last on the way, else the nearest
          local t, k = -1, 0
          local mx, my, mz = px - ox, py - oy, pz - oz
          if ox <= a0 and mx > 0 and (a0 - ox) / mx > t then t, k = (a0 - ox) / mx, 1 end
          if ox >= a1 and mx < 0 and (a1 - ox) / mx > t then t, k = (a1 - ox) / mx, 2 end
          if oz <= c0 and mz > 0 and (c0 - oz) / mz > t then t, k = (c0 - oz) / mz, 3 end
          if oz >= c1 and mz < 0 and (c1 - oz) / mz > t then t, k = (c1 - oz) / mz, 4 end
          if oy >= b1 and my < 0 and (b1 - oy) / my > t then t, k = (b1 - oy) / my, 5 end
          if oy <= b0 and my > 0 and (b0 - oy) / my > t then k = 6 end
          if k == 0 then
            t, k = px - a0, 1
            if a1 - px < t then t, k = a1 - px, 2 end
            if pz - c0 < t then t, k = pz - c0, 3 end
            if c1 - pz < t then t, k = c1 - pz, 4 end
            if b1 - py < t then k = 5 end
          end
          if k == 1 then px = a0 hit(-1, 0, 0, 0.3)
          elseif k == 2 then px = a1 hit(1, 0, 0, 0.3)
          elseif k == 3 then pz = c0 hit(0, 0, -1, 0.3)
          elseif k == 4 then pz = c1 hit(0, 0, 1, 0.3)
          elseif k == 5 then
            -- the roof: like the ground
            py, grounded = b1, true
            hit(0, 1, 0, 0.6)
            local fr = 1 - 7 * h
            vx, vz = vx * fr, vz * fr
          else py = b0 hit(0, -1, 0, 0.3) end
        end
      end
    end
    P.wr, P.wp, P.wy = pwr, pwp, pwy
    orthonormalize()
    speed = sqrt(vx * vx + vy * vy + vz * vz)
    if STICKTIME_TEST then
      -- motor sound state for the web emulator: what the synth needs (rpm from the thrust
      -- fraction, axial and edgewise flow, wash build-up, the shake's rms (deg) and frequency)
      aTf, aS, aF = Tm / Tmax, sH * 19.8, P.pf
      aVu = vx * ux + vy * uy + vz * uz
      aE2 = sqrt((vx * rx + vy * ry + vz * rz) ^ 2 + (vx * fx + vy * fy + vz * fz) ^ 2)
      aW = sW
    end
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
      BEST.f[S.track], R.newBest, R.dirty = v, true, true
      showMsg("COMBO " .. v .. "  BEST!", true)
      beep(2400, 200)
      R.flush()
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
    if dt < 0 or R.st > 0 then                 -- (a tumble after a hit is no trick)
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
  AI.vt = AI.vs[S.skill] * (0.75 + 0.05 * P.twr)
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
local SC = VW / 480
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
  local d = (state == FLY or state == DONE) and (STICKTIME_LAT or FPVSIM_LAT or R.fi * (STICKTIME_LATK or 0.011)) or 0
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
  local i = 0
  for v in string.gmatch(QP[S.quad] or QP[1], "%S+") do
    i = i + 1
    P[QK[i]] = tonumber(v)
  end
  local n, c, o, f, h = string.match(BAT[S.quad] or BAT[1], "(%S+) (%S+) (%S+) (%S+) (%S+)")   -- the class's pack
  BAT.n, BAT.mah, BAT.r, BAT.f, BAT.h = tonumber(n), tonumber(c) * (S.batt == 2 and 2 or S.batt == 3 and 1.5 or 1), tonumber(o) * 0.001, tonumber(f), tonumber(h)
  if S.twr > 0 and (S.twr < P.tlo or S.twr > P.thi) then S.twr = 0 end   -- not for this class: Stock
  if S.twr > 0 then
    -- the class's motors and props for this Power draw more at full throttle (hover current the same)
    BAT.f = BAT.f * (S.twr / P.twr) ^ 1.5
    P.twr = S.twr                           -- 0: the class's stock power
  end
  if S.wash == 1 then P.wl, P.wv, P.pw = P.wls, P.wvs, P.pws end  -- Stock: the class's own wash
  P.angle = S.mode == 2
  local t = S.tilt * 0.0174533
  P.tc, P.ts = cos(t), sin(t)
  tanH = sin(S.fov * 0.00872665) / cos(S.fov * 0.00872665)
  F = (VW / 2) / tanH
  MED.calc()
end

-- visible objects, drawn far -> near (painter's algorithm). ids: gates 1..NG, trees -i,
-- boxes 1000+b, AI pilots 2000+a. ordP holds the draw order (indices into the ord* arrays).
local ordZ, ordI, ordP, nOrd = {}, {}, {}, 0
local collectObjects
do
  local ordN = {}                                      -- object number (1..) of each ord entry
  -- With structures in view, depth order is not enough (a long wall's center can be far
  -- while its near end hides things). Pairs that overlap on screen and involve a structure
  -- get an exact rule from a separating plane: if the two bounds are apart along x, y or z
  -- and the camera is on one side of the gap, the object on that side is in front. Then a
  -- topological sort (Kahn) draws everything far to near while keeping those rules.
  local OB = { x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {}, b = {} }  -- b: structure?
  local SB = { x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {} }        -- bounds, by object
  local sx0, sx1, sy0, sy1 = {}, {}, {}, {}            -- screen rectangle of each object
  local EA, EB, cnt, indeg, DO = {}, {}, {}, {}, {}
  local CL, HD, NE, NX = {}, {}, {}, {}               -- rule candidates, rule lists, not drawn

  -- Rules only for pairs with a structure in them that overlap on screen. A plane between
  -- their boxes (along x, z or y) with the camera on one side puts the other object behind:
  -- rule 1 draws i before j, -1 after, 0 none. Every axis they are apart along must agree. The
  -- camera in the gap along one puts them on both sides of it there (no line of sight goes
  -- through both), and two planes that put different ones behind keep each from hiding the
  -- other: no rule then. Such a rule would only say which of two far apart things comes first,
  -- and with others (a far tower, a gate, the floors of a building) it can close a cycle.
  -- Touching faces count as separated (2 cm tolerance: radio Lua uses 32-bit floats).
  -- Boxes that intersect (a tree's box touching a wall): the farther one first.
  -- depth order (far to near) of the n objects into DO: an insertion sort fed with last frame's
  -- order (objects keep their places from frame to frame, so it takes about one pass)
  local LPOS, LST, BUF, stp, lastN = {}, {}, {}, 0, 0
  local function depthOrder(n)
    for p = 1, lastN do BUF[p] = 0 end
    for o = 1, n do
      local k = ordN[o]
      if LST[k] == stp then BUF[LPOS[k]] = o end
    end
    local m = 0
    for p = 1, lastN do
      local o = BUF[p]
      if o > 0 then
        m = m + 1
        DO[m] = o
      end
    end
    for o = 1, n do
      if LST[ordN[o]] ~= stp then
        m = m + 1
        DO[m] = o
      end
    end
    for k = 2, n do
      local o = DO[k]
      local z, j = ordZ[o], k - 1
      while j > 0 and ordZ[DO[j]] < z do
        DO[j + 1] = DO[j]
        j = j - 1
      end
      DO[j + 1] = o
    end
  end
  -- this frame's depth order, where the next frame's depthOrder starts from
  local function keepOrder(n)
    stp = stp + 1
    for k = 1, n do
      local key = ordN[DO[k]]
      LPOS[key], LST[key] = k, stp
    end
    lastN = n
  end

  local function sortWithStructures(n)
    local ne = 0
    local isB, X0, X1, Y0, Y1, Z0, Z1 = OB.b, SB.x0, SB.x1, SB.y0, SB.y1, SB.z0, SB.z1
    local cx, cy, cz = kpx, kpy, kpz
    -- candidates: the other objects, then the structures last to first, so that structure
    -- number b of nb pairs with CL[1 .. no + nb - b]: every other object and the structures
    -- after it (each pair of structures once)
    local no, nb = 0, 0
    for i = 1, n do
      if not isB[i] then
        no = no + 1
        CL[no] = i
      end
    end
    for i = n, 1, -1 do
      if isB[i] then
        nb = nb + 1
        CL[no + nb] = i
      end
    end
    for b = 1, nb do
      local i = CL[no + nb + 1 - b]
      local p0, p1, q0, q1 = sx0[i], sx1[i], sy0[i], sy1[i]
      local m = ordN[i]
      local a0, a1, c0, c1, e0, e1 = X0[m], X1[m], Z0[m], Z1[m], Y0[m], Y1[m]
      for k = 1, no + nb - b do
        local j = CL[k]
        if p0 < sx1[j] and sx0[j] < p1 and q0 < sy1[j] and sy0[j] < q1 then
          local mj = ordN[j]
          -- x, then z, then y: each axis they are apart along gives its rule, and they must agree
          -- (9: not apart along any yet; a 0 needs no more axes)
          local v, w, b0, b1 = 9, 9, X0[mj], X1[mj]
          if a1 <= b0 + 0.02 then v = cx >= b0 and 1 or cx <= a1 and -1 or 0
          elseif b1 <= a0 + 0.02 then v = cx >= a0 and -1 or cx <= b1 and 1 or 0 end
          if v ~= 0 then
            b0, b1 = Z0[mj], Z1[mj]
            if c1 <= b0 + 0.02 then w = cz >= b0 and 1 or cz <= c1 and -1 or 0
            elseif b1 <= c0 + 0.02 then w = cz >= c0 and -1 or cz <= b1 and 1 or 0 end
            if w ~= 9 then
              if v == 9 then v = w elseif w ~= v then v = 0 end
            end
            if v ~= 0 then
              b0, b1, w = Y0[mj], Y1[mj], 9
              if e1 <= b0 + 0.02 then w = cy >= b0 and 1 or cy <= e1 and -1 or 0
              elseif b1 <= e0 + 0.02 then w = cy >= e0 and -1 or cy <= b1 and 1 or 0 end
              if w ~= 9 then
                if v == 9 then v = w elseif w ~= v then v = 0 end
              end
              if v == 9 then v = ordZ[i] > ordZ[j] and 1 or -1 end   -- (apart along none)
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
    depthOrder(n)
    -- the depth order when no rule says otherwise (Kahn would give the same)
    for k = 1, n do cnt[DO[k]] = k end
    local ok = true
    for e = 1, ne do
      if cnt[EA[e]] > cnt[EB[e]] then
        ok = false
        break
      end
    end
    if ok then
      for k = 1, n do ordP[k] = DO[k] end
    else
      -- successors as lists linked through the rules, in-degrees
      for o = 1, n do HD[o], indeg[o] = 0, 0 end
      for e = 1, ne do
        local a, b = EA[e], EB[e]
        NE[e], HD[a] = HD[a], e
        indeg[b] = indeg[b] + 1
      end
      -- Kahn: always the farthest object whose rules allow it. The objects not drawn yet are
      -- linked in depth order (NX), so the search for the next one skips those already drawn.
      for k = 1, n do NX[k] = k + 1 end
      local head = 1
      for k = 1, n do
        local prev, p = 0, head
        while p <= n and indeg[DO[p]] > 0 do prev, p = p, NX[p] end
        -- p > n: a cycle (rare), broken at the farthest object left
        if p > n then prev, p = 0, head end
        if prev == 0 then head = NX[p] else NX[prev] = NX[p] end
        local best = DO[p]
        ordP[k] = best
        local e = HD[best]
        while e > 0 do
          local v = EB[e]
          indeg[v] = indeg[v] - 1
          e = NE[e]
        end
      end
    end
    keepOrder(n)
  end

  -- the track's objects for collectObjects, made once per track: center, radius, id and 3D
  -- bounds by object number (gates, the trees that are drawn, structures; the AI pilots come
  -- after them, their bounds refreshed when in view)
  local OCX, OCY, OCZ, ORAD, OID = {}, {}, {}, {}, {}
  local NS, made = 0, -1
  local function makeObjects()
    local n = 0
    for i = 1, NG do
      n = n + 1
      local k = gk[i]
      OCX[n], OCY[n], OCZ[n], OID[n] = gx[i], gy[i], gz[i], i
      ORAD[n] = GSH[k] == 3 and 9 or (k == 2 or k == 3) and 7 or 4
      -- legs and stands go down to the ground: a raised gate's sphere reaches it (a custom track's
      -- dive gate from a roof, 20 m up)
      if (k == 2 or k == 3 or k == 4) and gy[i] + 3 > ORAD[n] then ORAD[n] = gy[i] + 3 end
      SB.x0[n], SB.x1[n], SB.y0[n], SB.y1[n], SB.z0[n], SB.z1[n] = GB.x0[i], GB.x1[i], GB.y0[i], GB.y1[i], GB.z0[i], GB.z1[i]
    end
    for i = 1, NP do
      if qk[i] == 1 then
        n = n + 1
        local r = qh[i] * 0.25
        OCX[n], OCY[n], OCZ[n], ORAD[n], OID[n] = qx[i], qh[i] * 0.4, qz[i], qh[i], -i
        SB.x0[n], SB.x1[n], SB.y0[n], SB.y1[n], SB.z0[n], SB.z1[n] = qx[i] - r, qx[i] + r, 0, qh[i], qz[i] - r, qz[i] + r
      end
    end
    for b = 1, BX.n do
      n = n + 1
      local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
      OCX[n], OCY[n], OCZ[n], OID[n] = (x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5, 1000 + b
      ORAD[n] = (x1 - x0 + y1 - y0 + z1 - z0) * 0.5
      SB.x0[n], SB.x1[n], SB.y0[n], SB.y1[n], SB.z0[n], SB.z1[n] = x0, x1, y0, y1, z0, z1
    end
    NS, made = n, nBuilt
  end

  collectObjects = function(maxZ)
    nOrd = 0
    if made ~= nBuilt then makeObjects() end
    local ns = NS
    local boxes = false
    local g = gmode ~= 1                   -- (Practice: the ghost, as AI pilot 4)
    for n = 1, ns + (g and (GH.on and 1 or 0) or AI.n) do
      local X, Y, Z, rad
      local a = g and 4 or n - ns
      if n <= ns then
        X, Y, Z, rad = OCX[n] - kpx, OCY[n] - kpy, OCZ[n] - kpz, ORAD[n]
      else
        X, Y, Z, rad = AI.x[a] - kpx, AI.y[a] - kpy, AI.z[a] - kpz, 1
      end
      local z = X * kfx + Y * kfy + Z * kfz
      if z > -rad and z < maxZ then
        local x = X * krx + Y * kry + Z * krz
        if (x < 0 and -x or x) < z * tanH + rad or z < 4 then
          local o = nOrd + 1
          nOrd = o
          local id = n <= ns and OID[n] or 2000 + a
          ordZ[o], ordI[o], ordN[o] = z, id, n
          -- screen rectangle (in pixels from the center) for the draw-order rules, made
          -- conservative; the whole screen when the object reaches the camera.
          local y = X * kux + Y * kuy + Z * kuz
          local isBox = id >= 1000 and id < 2000
          OB.b[o] = isBox
          if isBox then
            -- a box: its extent across, up and along the view, then the nearest and farthest
            -- depth for the outer edges (a wall seen edge-on is a narrow strip, not a circle)
            boxes = true
            local hx, hy, hz = (SB.x1[n] - SB.x0[n]) * 0.5, (SB.y1[n] - SB.y0[n]) * 0.5, (SB.z1[n] - SB.z0[n]) * 0.5
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
            else
              sx0[o], sx1[o], sy0[o], sy1[o] = -1e6, 1e6, -1e6, 1e6
            end
          else
            -- other objects: around their bounding sphere, at its nearest depth and stretched
            -- towards the edges (perspective grows off-axis objects by 1/cos^2 of their angle)
            if z > rad * 2 then
              local s = F / z
              local r = rad * F / (z - rad) * (1 + (x * x + y * y) / (z * z))
              x, y = x * s, y * s
              sx0[o], sx1[o], sy0[o], sy1[o] = x - r, x + r, y - r, y + r
            else
              sx0[o], sx1[o], sy0[o], sy1[o] = -1e6, 1e6, -1e6, 1e6
            end
            if n > ns then
              local r = 0.3
              SB.x0[n], SB.x1[n], SB.y0[n], SB.y1[n], SB.z0[n], SB.z1[n] = AI.x[a] - r, AI.x[a] + r, AI.y[a] - r, AI.y[a] + r, AI.z[a] - r, AI.z[a] + r
            end
          end
        end
      end
    end
    if boxes then
      sortWithStructures(nOrd)
      return
    end
    -- no structures in view: plain depth order
    depthOrder(nOrd)
    for k = 1, nOrd do ordP[k] = DO[k] end
    keepOrder(nOrd)
  end
  if STICKTIME_TEST then
    STICKTIME_TEST.bounds = OB
    STICKTIME_TEST.fillBounds = function()          -- OB's bounds by ord entry, for the tests
      for o = 1, nOrd do
        local m = ordN[o]
        OB.x0[o], OB.x1[o], OB.y0[o], OB.y1[o], OB.z0[o], OB.z1[o] = SB.x0[m], SB.x1[m], SB.y0[m], SB.y1[m], SB.z0[m], SB.z1[m]
      end
    end
  end
end

local C = {}            -- colors (color radios) / grey levels (B&W)
local render3D, initGfx

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
    -- the minimap's structures: C.dim as it was blended over the minimap's panel, over the sky
    -- (landscape) or over the instrument panel (portrait)
    C.mapBox = PORTRAIT and RGB(99, 105, 117) or RGB(114, 133, 159)
    C.ai = { RGB(255, 72, 72), RGB(64, 150, 255), RGB(200, 96, 255), RGB(230, 240, 255) }   -- 4: the ghost
    C.med = { RGB(224, 140, 70), RGB(208, 216, 228), RGB(255, 200, 40) }   -- bronze, silver, gold
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
    -- clip only against the view edges the polygon crosses
    local x0, x1, y0, y1 = fxs[1], fxs[1], fys[1], fys[1]
    for i = 2, n do
      local x, y = fxs[i], fys[i]
      if x < x0 then x0 = x elseif x > x1 then x1 = x end
      if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    local px, py, qx, qy = fxs, fys, gxs, gys
    if x0 < VX - 1 then
      n = clip2(n, px, py, qx, qy, true, VX - 1, -1)
      px, py, qx, qy = qx, qy, px, py
    end
    if x1 > VX + VW then
      n = clip2(n, px, py, qx, qy, true, VX + VW, 1)
      px, py, qx, qy = qx, qy, px, py
    end
    if y0 < VY - 1 then
      n = clip2(n, px, py, qx, qy, false, VY - 1, -1)
      px, py, qx, qy = qx, qy, px, py
    end
    if y1 > VY + VH then
      n = clip2(n, px, py, qx, qy, false, VY + VH, 1)
      px, py = qx, qy
    end
    if n < 3 then return end
    -- a strip from the top corner down both sides: the firmware walks every row of each
    -- triangle, and a fan from one corner would walk up to n - 2 times the polygon's height
    local t, ty = 1, py[1]
    for i = 2, n do
      if py[i] < ty then t, ty = i, py[i] end
    end
    local l, r = t == 1 and n or t - 1, t == n and 1 or t + 1
    fillTri(px[t], ty, px[l], py[l], px[r], py[r], col)
    for _ = 4, n do
      local a, b = l == 1 and n or l - 1, r == n and 1 or r + 1
      if py[a] < py[b] then
        fillTri(px[l], py[l], px[r], py[r], px[a], py[a], col)
        l = a
      else
        fillTri(px[l], py[l], px[r], py[r], px[b], py[b], col)
        r = b
      end
    end
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

  -- one side of the horizon (where c + (x-CX)*a - (y-CY)*b < 0) within the view: one rectangle
  -- + one thin wedge triangle (filled triangles cost one call per scanline on the radio). With
  -- e, only the wedge and e pixels of the rectangle next to it: the side along the horizon
  local function fillSide(a, b, c, g, e)
    local x0, y0, x1, y1 = VX, VY, VX + VW, VY + VH
    local A, B = a < 0 and -a or a, b < 0 and -b or b
    if A <= B then
      if B < 1e-5 then
        if c < 0 and not e then fillRect(x0, y0, VW, VH, g) end
        return
      end
      local yL, yR = CY + (c + (x0 - CX) * a) / b, CY + (c + (x1 - CX) * a) / b
      local lo, hi = yL, yR
      if lo > hi then lo, hi = hi, lo end
      if b > 0 then
        if lo < y1 then
          if hi <= y0 then
            if not e then fillRect(x0, y0, VW, VH, g) end
          else
            if hi < y1 then
              local t = hi > y0 and hi or y0
              local h = y1 - t + 1
              fillRect(x0, t, VW, e and e < h and e or h, g)
            end
            if yL < yR then fillTri(x0, yL, x1, yR, x0, yR, g) else fillTri(x0, yL, x1, yR, x1, yL, g) end
          end
        end
      elseif hi > y0 then
        if lo >= y1 then
          if not e then fillRect(x0, y0, VW, VH, g) end
        else
          if lo > y0 then
            local h = (lo < y1 and lo or y1) - y0 + 1
            local s = e and e < h and h - e or 0
            fillRect(x0, y0 + s, VW, h - s, g)
          end
          if yL > yR then fillTri(x0, yL, x1, yR, x0, yR, g) else fillTri(x0, yL, x1, yR, x1, yL, g) end
        end
      end
    else
      local xT, xB = CX + ((y0 - CY) * b - c) / a, CX + ((y1 - CY) * b - c) / a
      local lo, hi = xT, xB
      if lo > hi then lo, hi = hi, lo end
      if a > 0 then
        if hi > x0 then
          if lo >= x1 then
            if not e then fillRect(x0, y0, VW, VH, g) end
          else
            if lo > x0 then
              local w = (lo < x1 and lo or x1) - x0 + 1
              local s = e and e < w and w - e or 0
              fillRect(x0 + s, y0, w - s, VH, g)
            end
            if xT < xB then fillTri(xT, y0, xB, y1, xT, y1, g) else fillTri(xT, y0, xB, y1, xB, y0, g) end
          end
        end
      elseif lo < x1 then
        if hi <= x0 then
          if not e then fillRect(x0, y0, VW, VH, g) end
        else
          if hi < x1 then
            local t = hi > x0 and hi or x0
            local w = x1 - t + 1
            fillRect(t, y0, e and e < w and e or w, VH, g)
          end
          if xT > xB then fillTri(xT, y0, xB, y1, xT, y1, g) else fillTri(xT, y0, xB, y1, xB, y0, g) end
        end
      end
    end
  end

  -- sky, ground and the mountains between them, every pixel painted about once: lcd.clear()
  -- paints the larger of sky and ground (and comes first in the frame, so firmware that keeps
  -- the last frame need not copy it), then only the other side is filled. The ground goes
  -- over the mountains' bases and the sky's edge (a pixel past the horizon): with the sky
  -- larger in the usual order, with the ground larger again along the horizon
  local function drawGround()
    local a, b, c = kry, kuy, F * kfy      -- ground where c + (x-CX)*a - (y-CY)*b < 0
    local x0, y0, x1, y1 = VX, VY, VX + VW, VY + VH
    local A, B = a < 0 and -a or a, b < 0 and -b or b
    -- share of the view that is ground, from where the horizon crosses its middle
    local f
    if B < 1e-5 and A < 1e-5 then f = c < 0 and 1 or 0
    elseif A <= B then
      f = (CY + (c + ((x0 + x1) * 0.5 - CX) * a) / b - y0) / VH     -- b > 0: ground below
      if b > 0 then f = 1 - f end
    else
      f = (CX + (((y0 + y1) * 0.5 - CY) * b - c) / a - x0) / VW
      if a < 0 then f = 1 - f end
    end
    if f > 0.5 then
      lcd.clear(cGround)
      fillSide(-a, -b, -c, cSky)
      drawMountains()
      fillSide(a, b, c, cGround, 2)
    else
      lcd.clear(cSky)
      drawMountains()
      fillSide(a, b, c, cGround)
    end
    local hx0, hy0, hx1, hy1
    if A <= B then
      if B < 1e-5 then return end
      hx0, hy0, hx1, hy1 = x0, CY + (c + (x0 - CX) * a) / b, x1, CY + (c + (x1 - CX) * a) / b
    else
      hx0, hy0, hx1, hy1 = CX + ((y0 - CY) * b - c) / a, y0, CX + ((y1 - CY) * b - c) / a, y1
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
        -- quad a-b-d-c, split along the diagonal between the corners next to the top one
        if (ay < dy and ay or dy) < (by < cy and by or cy) then
          fillTri(ax, ay, bx, by, cx, cy, fill)
          fillTri(bx, by, dx, dy, cx, cy, fill)
        else
          fillTri(ax, ay, bx, by, dx, dy, fill)
          fillTri(ax, ay, dx, dy, cx, cy, fill)
        end
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
      elseif (b1 < b3 and b1 or b3) < (b2 < b4 and b2 or b4) then
        -- split along the diagonal between the two corners next to the top one: the two
        -- triangles then share the fewest rows (the firmware walks each one's every row)
        fillTri(a1, b1, a2, b2, a4, b4, col)
        fillTri(a2, b2, a3, b3, a4, b4, col)
      else
        fillTri(a1, b1, a2, b2, a3, b3, col)
        fillTri(a1, b1, a3, b3, a4, b4, col)
      end
      -- outlines only where they show: each line call costs as much as a short line
      if x1 - x0 + y1 - y0 > 16 then
        if x1 <= XL and y1 <= YL then              -- no end past the right or bottom edge
          drawLine(a1, b1, a2, b2, SOLID, ecol)
          drawLine(a2, b2, a3, b3, SOLID, ecol)
          drawLine(a3, b3, a4, b4, SOLID, ecol)
          drawLine(a4, b4, a1, b1, SOLID, ecol)
        else
          ln(a1, b1, a2, b2, ecol)
          ln(a2, b2, a3, b3, ecol)
          ln(a3, b3, a4, b4, ecol)
          ln(a4, b4, a1, b1, ecol)
        end
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


-- ---------------------------------------------------------- game flow
local function startRace(m)
  R.flush()
  gmode = m
  lap, nextGate, lastGate, lapStart = 0, 1, 0, nil
  R.n, R.total, R.newLap, R.newRace, R.newBest, R.crashes, R.msg, R.cd = 0, 0, false, false, false, 0, nil, -1
  R.pk, R.pos, R.sc, R.ch, R.chn, R.rn, R.rt, R.ax, R.bx, R.smp, R.why = 0, 1, 0, 0, 0, 0, 30, nil, nil, gt, nil
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  BAT.new()
  AI.start()
  tricks(-1)
  if m == 2 and S.ghost == 1 then
    if GH.t ~= S.track then ghost.load() end
    RC.t0, GH.on = nil, false
  else
    GH, RC = { n = 0, iv = 10, lap = 0, c = {}, t = 0 }, { n = 0, iv = 10, c = {}, q = "" }   -- (memory)
  end
  if m == 3 then state, R.ready = READY, gt else state, tState = COUNT, gt end
end

local function selectTrack(t)
  S.track = t
  buildTrack(t)
  MED.calc()
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
      state, R.ready, R.why = READY, gt, nil
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
  if gmode == 2 and S.ghost == 1 and state ~= MENU then
    if GH.t ~= S.track then ghost.load() end           -- (Ghost turned on mid-run: the saved one first)
    ghost.step()
  else GH.on = false end
  if gmode == 4 and (state == FLY or state == CRASHED or state == READY) then
    R.rt = R.rt - dt
    if R.rt <= 0 then
      R.rt = 0
      local t = S.track
      if R.rn > BEST.g[t] then BEST.g[t], R.newBest = R.rn, true end
      R.dirty = true
      R.flush()
      state, tState, focus = DONE, gt, 1
      beep(900, 300)
    end
  end
end

-- menus
local MAIN_ITEMS = { "Race", "Practice", "Freestyle", "Gate Rush", "Track", "Settings", "Exit" }
local PAUSE_ITEMS = { "Resume", "Respawn", "Restart", "Settings", "Main menu" }

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
    local j = optIndex(o)
    repeat                                     -- Power: only what suits the quad
      j = j + d
      if j < 1 then j = #vals elseif j > #vals then j = 1 end
    until key ~= "twr" or vals[j] == 0 or vals[j] >= P.tlo and vals[j] <= P.thi
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
    return "Lap " .. (BEST.l[t] > 0 and timeStr(BEST.l[t]) or "--"), "  Race " .. (BEST.r[t] > 0 and timeStr(BEST.r[t]) or "--"),
           MED.of(BEST.l[t])
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

  -- a good place to enter gate i from, so its marker shows where to come in from before you aim (a
  -- guide on a track you're learning; yellow: go round): on its way-in side within 70 deg of its
  -- axis, whichever way you head, or from a steeper angle on that side heading straight into its
  -- opening (+1 m). A dive gate: anywhere above it (a shallow swoop drops in too). Gate Rush counts
  -- a gate either way through, so either side will do. A flag is a turn: still before it and on the
  -- side its pole leaves free, or heading to pass on that side (a slalom comes in from the other
  -- side: gx, gz the middle of its pass zone, GHW from the pole). wide: once green, yellow again
  -- only past 75 deg, 1.5 m or level with a dive gate (no flicker)
  local function linedUp(i, wide)
    local nx, ny, nz, k = gnx[i], gny[i], gnz[i], gk[i]
    local wx, wy, wz = AX[i] - px, AY[i] - py, AZ[i] - pz
    local d, c = wx * nx + wy * ny + wz * nz, wide and 0.26 or 0.34
    local hl = sqrt(fx * fx + fz * fz) + 0.001
    local fn, fr = (fx * nx + fz * nz) / hl, (fx * grx[i] + fz * grz[i]) / hl
    if k == 6 or k == 7 then
      if d <= 0 then return false end
      local s = k == 6 and 1 or -1
      local side = ((px - gx[i]) * grx[i] + (pz - gz[i]) * grz[i]) * s + GHW[k]      -- metres out from the pole
      local m = wide and 1 or 0
      return side > -m or (fn > 0.17 and side + fr * s * d / fn > -0.5 - m)
    end
    if gmode == 4 and d < 0 then nx, ny, nz, d, fn = -nx, -ny, -nz, -d, -fn end
    if ny ~= 0 then return d > (wide and 0.1 or 0.4) end                     -- a dive gate: from above
    if d <= 0 then return false end
    if d > c * sqrt(wx * wx + wy * wy + wz * wz) then return true end
    if fn <= 0.17 then return false end
    local side = -(wx * grx[i] + wz * grz[i]) + fr * d / fn                  -- where straight on meets its plane
    return (side < 0 and -side or side) < GHW[k] + (wide and 1.5 or 1)
  end
  -- green from 70 deg, yellow again past 75 (no flicker at the edge); a fresh test once the gate
  -- has been off the screen
  local mkGate, mkOn = 0, false
  local function markerOn(i)
    mkOn = linedUp(i, mkGate == i and mkOn)
    mkGate = i
    return mkOn
  end
  if STICKTIME_TEST then STICKTIME_TEST.lined, STICKTIME_TEST.marker = linedUp, markerOn end

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
        fillTri(bx, by, bx - m, by - m * 1.4, bx + m, by - m * 1.4, markerOn(i) and C.good or C.accent2)   -- green: lined up
        return
      end
    end
    mkOn = false
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
    -- structures: solid, in the colour they had blended over the panel (a blended fill is one
    -- slow call each on the radio)
    for b = 1, BX.n do
      fillRect(ox + BX.x0[b] * s, oz - BX.z1[b] * s, (BX.x1[b] - BX.x0[b]) * s + 1, (BX.z1[b] - BX.z0[b]) * s + 1, C.mapBox)
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
    elseif GH.on then fillRect(ox + AI.x[4] * s - 1, oz - AI.z[4] * s - 1, 3, 3, C.ai[4]) end
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

  -- wind: where it blows, as seen from the quad (up is the way its nose points)
  local function windBox(x, y, s)
    fillRect(x, y, s, s, C.panel, 6)
    local l = sqrt(fx * fx + fz * fz) + 0.0001
    local ex, ey = (TR.wx * fz - TR.wz * fx) / l, -(TR.wx * fx + TR.wz * fz) / l
    local cx, cy, a, b, w = x + s / 2, y + s / 2, s * 0.38, s * 0.17, s * 0.05 + 0.5
    local tx, ty = cx + ex * a, cy + ey * a                  -- tip
    local hx, hy = tx - ex * b * 1.6, ty - ey * b * 1.6      -- back of the head
    local bx, by = cx - ex * a, cy - ey * a                  -- tail
    fillTri(bx - ey * w, by + ex * w, bx + ey * w, by - ex * w, hx + ey * w, hy - ex * w, C.white)
    fillTri(bx - ey * w, by + ex * w, hx + ey * w, hy - ex * w, hx - ey * w, hy + ex * w, C.white)
    fillTri(tx, ty, hx - ey * b, hy + ex * b, hx + ey * b, hy - ex * b, C.white)
  end

  local function drawSticks(x, y, s, gap)
    -- getStickMode() (EdgeTX 3.0 and newer) gives the mode itself, 1 to 4; without it: mode 2
    local m = getStickMode and getStickMode() or 2
    local t = sT * 2 - 1
    local lx, ly, rx_, ry_ = sR, t, sA, sE                        -- mode 2
    if m == 1 then lx, ly, rx_, ry_ = sR, sE, sA, t                 -- mode 1
    elseif m == 3 then lx, ly, rx_, ry_ = sA, sE, sR, t             -- mode 3
    elseif m == 4 then lx, ly, rx_, ry_ = sA, t, sR, sE end         -- mode 4
    stickBox(x, y, s, lx, ly)
    stickBox(x + s + gap, y, s, rx_, ry_)
  end

  -- the battery (setting) in flight, as on B&W: a battery that empties and the cell voltage; white,
  -- yellow below 3.5 V a cell, red and blinking below 3.3 V (the pause and finish screens have the
  -- rest). Bottom-left at x, y
  local function drawBattery(x, y)
    local w = BAT.w
    if w > 1 and gt % 50 >= 30 then return end
    local c = w == 0 and C.white or w == 1 and C.accent2 or C.bad
    local bw, bh = floor(16 * SC + 4), floor(6 * SC + 3)
    y = y - hS
    local by = y + floor((hS - bh) / 2)
    fillRect(x, by, bw, bh, C.panel, 6)
    lcd.drawRectangle(x, by, bw, bh, c)
    fillRect(x + bw, by + floor(bh / 4), 2, bh - 2 * floor(bh / 4), c)
    fillRect(x + 2, by + 2, floor((bw - 4) * BAT.s + 0.5), bh - 4, c)
    txt(x + bw + 6, y, fmt("%.2fV", BAT.v), SMLSIZE + c)
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
    if PORTRAIT then
      if S.wind > 0 then
        local s = floor(VH * 0.11)
        windBox(W - m - s, VY + VH - m - s, s)
      end
      if S.batt > 0 and state < PAUSED then drawBattery(m, VY + VH - m) end
      return
    end
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
    elseif gmode == 2 then
      local g, k = MED.goal()
      txt(rxp, m + hS, g, SMLSIZE + RIGHT + C.med[k])
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
    -- the battery right of the altitude (not under the pause and finish boxes, which have it)
    if S.batt > 0 and state < PAUSED then
      drawBattery(m + bw + 10 + (lcd.sizeText and lcd.sizeText("000m", SMLSIZE) or floor(30 * SC)), VY + VH - m)
    end
    if P.angle then txt(m + bw + 4, VY + VH - m - hS * 2, "ANGLE", SMLSIZE + C.cyan) end
    txt(W - m, VY + VH - m - hL, floor(speed * 3.6) .. " km/h", MIDSIZE + RIGHT + C.white)
    if S.wind > 0 then
      local s = floor(VH * 0.11)
      windBox(W - m - s, VY + VH - m - hL - s - 2, s)
    end
    if S.sticks == 1 then
      local s = floor(VH * 0.16)
      drawSticks(CX - s - 2, VY + VH - m - s, s, 4)
    end
    if TOUCH then pauseButton(W / 2 - floor(11 * SC + 3), m, floor(22 * SC + 6)) end
    -- (a row higher with the battery on: with the firmware's timings the line is wide enough to reach it)
    if S.fps == 1 then
      local y = VY + VH - m - hS - (S.sticks == 1 and floor(VH * 0.16) + 2 or S.batt > 0 and hS + 2 or 0)
      txt(W / 2, y, R.fps .. " fps" .. R.fpsX, SMLSIZE + CENTER + C.dim)
    end
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
    elseif gmode == 2 then
      local g, k = MED.goal()
      drawText(m, y + hM + hX + hS, g, SMLSIZE + C.med[k])
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
    local info, race, m = bestInfo()
    -- "Lap 23.45 GOLD  Race 1:10.20", the medal in its color
    local function infoLine(ix, iy)
      if race and lcd.sizeText then
        if m > 0 then info = info .. " " end
        txt(ix, iy, info, SMLSIZE + C.white)
        ix = ix + lcd.sizeText(info, SMLSIZE)
        if m > 0 then
          txt(ix, iy, MED.n[m], SMLSIZE + C.med[m])
          ix = ix + lcd.sizeText(MED.n[m], SMLSIZE)
        end
        txt(ix, iy, race, SMLSIZE + C.white)
      else
        txt(ix, iy, info .. (race and (m > 0 and " " .. MED.n[m] or "") .. race or ""), SMLSIZE + C.white)
      end
    end
    if PORTRAIT then
      -- 3D view stays clear on top, the menu fills the instrument panel
      infoLine(x + MG, VH - MG - hS)
      fillRect(0, VH, W, H - VH, C.panelBG)
      drawLine(0, VH, W, VH, SOLID, C.accent)
      drawList(nil, #MAIN_ITEMS, mainLabel, mainValue, x, VH + MG * 2, w, H - VH - MG * 3)
      return
    end
    local ly = H - MG - hS
    infoLine(x + MG, ly)
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
    if not rush then extra = extra + hM end      -- the medal
    if S.batt > 0 then extra = extra + hM end    -- the battery
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
      local m = MED.of(b)
      row("Medal", m > 0 and MED.n[m] or "--", m > 0 and C.med[m] or C.dim)
      cy = cy + 4
      for i = 1, n do
        drawText(x + MG * 2, cy, "Lap " .. i, SMLSIZE + C.dim)
        drawText(x + w - MG * 2, cy, timeStr(R.laps[i]), SMLSIZE + RIGHT + (R.laps[i] == b and C.good or C.white))
        cy = cy + hS
      end
    end
    if S.batt > 0 then
      local t, mah = BAT.text()
      row("Battery", t .. "  " .. mah, C.white)
    end
    cy = cy + MG
    hitN = 0
    local bw = (w - MG * 6) / 2
    local bh = hM + 8
    local f = focus == 2
    fillRect(x + MG * 2, cy, bw, bh, f and C.panelBG or C.accent)
    drawText(x + MG * 2 + bw / 2, cy + 4, "Again", CENTER + (f and C.white or C.black))
    hit(x + MG * 2, cy, bw, bh, 1)
    fillRect(x + MG * 4 + bw, cy, bw, bh, f and C.accent or C.panelBG)
    drawText(x + MG * 4 + bw * 1.5, cy + 4, "Menu", CENTER + (f and C.black or C.white))
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
      bigCenter(R.why or "CRASH", C.white, nil)
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
      y = y + lh + MG
      if S.batt > 0 and y + hS <= hh then          -- the pack: flight time, mAh used, voltage
        local t, mah = BAT.text()
        txt(x + MG, y, "Battery  " .. t .. "  " .. mah .. "  " .. fmt("%.1fV", BAT.v * BAT.n), SMLSIZE + C.white)
      end
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
    R.flush()
    state, focus, scroll, editing = MENU, 1, 0, false
    AI.n = 0
    placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  end

  local function stepTrack(d)
    local t = S.track
    repeat                                          -- (custom slots without a file are skipped)
      t = t + d
      if t < 1 then t = NT elseif t > NT then t = 1 end
    until TRACKS[t]
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
    elseif i == 2 then
      -- back at the last gate (Freestyle: where it flew a second ago), the clock running on
      if pausedFrom == COUNT then state = COUNT else
        respawn()
        BAT.new()                                  -- with a fresh pack
        R.ch, R.chn = 0, 0                         -- (a Freestyle combo ends)
        tricks(-1)
        state, R.ready = READY, gt
      end
    elseif i == 3 then startRace(gmode)
    elseif i == 4 then prevState, state, focus, scroll, editing = PAUSED, SETUP, 1, 0, false
    elseif i == 5 then toMenu()
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
          state, focus, scroll = PAUSED, 4, 0
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
      -- Again or Menu: the wheel or the page keys pick one, ENTER (or a tap) takes it, EXIT is Menu
      listNav(event, 2)
      if event == EV.PGN or event == EV.PGP then focus = 3 - focus end
      if tapI then focus = tapI end
      if tapI or event == EV.ENTER then
        if focus == 2 then toMenu() else startRace(gmode) end
      elseif event == EV.EXIT then toMenu() end
    else
      -- flying: EXIT or the on-screen pause button pauses
      if event == EV.EXIT or (EV.TAP and event == EV.TAP and touch and pauseHit(touch.x, touch.y)) then
        pausedFrom, prevState, state, focus, scroll = state, state, PAUSED, 1, 0
        R.flush()
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
  -- the test hooks (the headless tests, the browser emulator); not in StickTime BW as shipped
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
    TEST.qp = function(k, v) local o = P[k] if v then P[k] = v end return o end   -- a class number
    TEST.lapclock = function(t)
      -- first lap running for t ticks, and no "GO!" banner (for screenshots)
      lapStart, tStart, R.msgT = gt - t, gt - t, gt - 1000
      if lap < 1 then lap = 1 end
    end
    TEST.next = function(i) nextGate, lastGate = i, (i - 2) % NG + 1 end
    TEST.line = function(i, s) return AI.pos(i, s) end          -- the racing line, leg i (0..1), and its gates
    TEST.ng = function() return NG end
    TEST.race = function() return lastGate, lapStart, R.n, R.laps, R.total, R.crashes, tStart end
    TEST.info = function()
      local n = NT
      while not TRACKS[n] do n = n - 1 end          -- the highest track that exists
      return n, P.twr, gmode, R.pos, AI.n, R.sc, R.rn, R.rt, R.chn, BX.n, TRACKS[S.track][1] end
    TEST.thrust = function() return P.twr, P.i0, P.tn, P.dz, P.tk end
    TEST.audio = function() return sT, S.quad, state, aTf, aVu, aE2, aW, sA, sE, sR, aS, aF, R.crashes, R.hv or 0 end
    TEST.ai = function(a) return AI.x[a], AI.y[a], AI.z[a], AI.k[a], AI.d[a], AI.v[a], AI.seg[a] end
    TEST.best = function(t) return BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t] end
    TEST.medals = function() return MED[1], MED[2], MED[3], MED.of end
    TEST.stun = function() return R.st end
    TEST.ghost = function() return GH.n, GH.iv, GH.lap, GH.on, AI.x[4], AI.y[4], AI.z[4], RC.n, RC.iv, ghost.max, ghost.file end
    TEST.bat = function(k, v) if v then BAT[k] = v end return BAT[k], R.why end   -- a battery value; the crash's why
    TEST.box = function(b) return BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b] end
    TEST.S = S
    TEST.order = function()
      if TEST.fillBounds then TEST.fillBounds() end
      return nOrd, ordP, ordI, TEST.bounds, kpx, kpy, kpz
    end
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
  -- the StickTime firmware (firmware/) reports how long run() and putting the frame on the
  -- screen took: shown next to the fps, averaged over the same second
  local ru, su = TOOL_RUN_US, TOOL_SHOW_US
  if ru and su then R.runS, R.showS = R.runS + ru, R.showS + su end
  if now - R.fpsT >= 100 then
    if ru and su then
      local k = 0.001 / R.fpsN
      R.fpsX = fmt("  game %d ms  lcd %d ms", floor(R.runS * k + 0.5), floor(R.showS * k + 0.5))
      R.runS, R.showS = 0, 0
    end
    R.fps, R.fpsN, R.fpsT = R.fpsN, 0, now
  end
  return 0
end

return { init = init, run = run }
